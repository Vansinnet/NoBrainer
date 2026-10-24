-- Historical suite, no longer run. BetterBrainer and NoBrainer tests/fixture.lua load only its fixture half.
-- Offline integration, not a dedicated-server/runtime or native RNG/quantization test.
-- Whole source files supply input, state, minigame rules and RPC dispatch. Only
-- DMF registration, native primitives, peripheral services and transport are mocked.
local ROOT = "mods/active/BetterBrainer/scripts/mods/BetterBrainer/"
local ENGINE = "scripts/extension_systems/minigame/minigames/"
local STATE = "scripts/extension_systems/character_state_machine/character_states/player_character_state_minigame"
local INPUT = "scripts/extension_systems/input/"
local HANDLER = "scripts/managers/player/player_game_states/"
local function eq(a, b, why)
    assert(a == b, (why or "equality") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function near(a, b, why) assert(math.abs(a - b) < 1e-9, why or "scalar mismatch") end
local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
    return out
end
local function noop() end
local function yes() return true end
local function no() return false end
local function fixture(overrides, solo_first, action_chain)
    local f = { t = 10, enabled = true, visible = true, timer = true, reads = {}, paths = {},
        modules = {}, observations = {}, observed_times = {}, input_calls = {}, input_times = {},
        hooks = {}, deferred = {}, queue = {}, rpc_count = {}, frames = {} }
    local env = setmetatable({ math = copy(math), table = copy(table), CLASS = {} }, { __index = _G })
    f.env = env
    env.unpack = table.unpack
    env.math.clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
    env.math.atan2 = math.atan
    env.math.degrees_to_radians = math.rad
    -- Fixed portable test RNG. Board generation uses engine code, not native RNG parity.
    env.math.next_random = function(seed, lo, hi)
        if not hi then hi, lo = lo, 1 end
        seed = (seed * 48271) % 2147483647
        return seed, lo + seed % (hi - lo + 1)
    end
    env.table.clear = function(t) for k in pairs(t) do t[k] = nil end end
    env.table.clone, env.table.shallow_copy = copy, copy
    env.table.enum = function(...)
        local t = {}
        for _, v in ipairs({...}) do t[v] = v end
        return t
    end
    env.table.shuffle = function(t, seed)
        for i = #t, 2, -1 do
            local j
            seed, j = env.math.next_random(seed, i)
            t[i], t[j] = t[j], t[i]
        end
        return seed
    end
    env.settings = function(_, t) return t end
    env.Vector3 = setmetatable({
        zero = function() return { x = 0, y = 0, z = 0 } end,
        equal = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
        length = function(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end,
    }, { __call = function(_, x, y, z) return { x = x, y = y, z = z } end })
    env.Unit = { alive = function(u) return u ~= nil and not u.dead end, flow_event = noop, set_flow_variable = noop }
    env.NetworkConstants = { invalid_level_unit_id = -1, invalid_game_object_id = -1 }
    f.ping = 0.12
    env.Network = { ping = function() return f.ping end, type_index = function(name) return name end,
        pack_unpack = function(_, value) return value end }
    env.Script = { new_array = function() return {} end }
    env.Log = { debug = noop }
    env.DEDICATED_SERVER = true -- Camera-enabled Frequency cases explicitly exercise the other branch.
    env.CLASSES = {}
    env.require = function(path) eq(path, "scripts/foundation/utilities/error"); return {} end
    assert(loadfile("darktide-source/scripts/foundation/utilities/class.lua", "t", env))()
    local engine_class = env.class
    env.class = function(name, parent)
        local c = engine_class(name, parent)
        env.CLASS[name], env[name] = c, c
        return c
    end
    env.class("PlayerCharacterStateBase").on_exit = noop
    env.class("ExtensionSystemBase")
    f.player = { player_unit = {}, session_id = function() return "local" end,
        is_human_controlled = yes, channel_id = function() return 1 end }
    f.remote = { player_unit = {}, session_id = function() return "remote" end,
        is_human_controlled = yes, channel_id = function() return 2 end, remote = true }
    f.terminal = {}
    f.extensions = {}
    env.ScriptUnit = {
        has_extension = function(unit, name) return f.extensions[unit] and f.extensions[unit][name] end,
        extension = function(unit, name) return assert(f.extensions[unit] and f.extensions[unit][name], name) end,
    }
    env.Managers = {
        time = { has_timer = function() return f.timer end, time = function() return f.t end },
        player = { local_player_safe = function(_, index) eq(index, 1); return f.player end,
            player_from_session_id = function(_, id)
                if id == "local" then return f.player elseif id == "remote" then return f.remote end
            end },
        ui = { view_active = function(_, name) eq(name, "scanner_display_view"); return f.visible end,
            inputs_in_use = function() return f.locks end },
        save = { account_data = function() return { input_settings = {} } end },
        connection = { host = function() return "host" end, is_client = function() return f.client ~= nil end,
            is_host = function() return f.client == nil end, tick_rate = function() return 50 end },
        stats = { record_private = noop }, telemetry_events = { player_hacked_terminal = noop },
        state = { unit_spawner = { game_object_id_or_level_index = function() return true, 1 end,
            unit = function() return f.terminal end } },
    }
    local cache = {}
    local utility = "scripts/extension_systems/character_state_machine/character_states/utilities/"
    local stubs = {
        ["scripts/managers/input/input_filters"] = {}, ["scripts/managers/input/input_utils"] = {},
        ["scripts/managers/input/null_input_service"] = {},
        ["scripts/managers/ui/ui_widget"] = {},
        ["scripts/ui/views/scanner_display_view/scanner_display_view_decode_search_settings"] = {},
        ["scripts/settings/equipment/weapon_templates/devices/scanner_equip"] = {
            actions = { action_scan_confirm = { scan_settings = { confirm_time = 1 } } } },
        ["scripts/extension_systems/character_state_machine/character_states/player_character_state_base"] = env.PlayerCharacterStateBase,
        [utility .. "crouch"] = {}, [utility .. "disruptive_state_transition"] = {},
        [utility .. "dodge"] = { check = function() f.dodges = (f.dodges or 0) + 1; return false end },
        [utility .. "health_state_transitions"] = {}, [utility .. "sprint"] = {},
        ["scripts/settings/interaction/interaction_settings"] = { states = { waiting_to_interact = "waiting" } },
        ["scripts/utilities/attack/interrupt"] = {}, ["scripts/utilities/luggable"] = {},
        ["scripts/extension_systems/visual_loadout/utilities/player_unit_visual_loadout"] = {},
        [INPUT .. "bot_unit_input"] = {},
        ["scripts/extension_systems/minigame/minigame_extension"] = {},
        ["scripts/utilities/fixed_frame"] = { get_latest_fixed_time = function() return f.t end },
        ["scripts/utilities/lag_compensation"] = { rewind_ms = function() return f.rewind or 0 end },
        [HANDLER .. "utilities/adaptive_clock_handler_server"] = { new = function()
            return { frame_received = noop, frame_missed = noop }, 0
        end },
    }
    env.require = function(path)
        if stubs[path] then return stubs[path] end
        if cache[path] then return cache[path] end
        assert(path == STATE or path == "scripts/settings/minigame/minigame_settings"
            or path == "scripts/managers/input/input_service" or path == INPUT .. "human_unit_input"
            or path == INPUT .. "player_unit_input_extension" or path == "scripts/extension_systems/minigame/minigame_system"
            or path == HANDLER .. "human_input_handler" or path == HANDLER .. "input_handler_settings"
            or path == HANDLER .. "authoritative_player_input_handler"
            or path:match("^" .. ENGINE), "unbounded dependency: " .. path)
        cache[path] = assert(loadfile("darktide-source/" .. path .. ".lua", "t", env))()
        return cache[path]
    end
    f.settings = env.require("scripts/settings/minigame/minigame_settings")
    env.NetworkLookup = { minigame_game_states = f.settings.game_states }
    stubs["scripts/network_lookup/network_lookup"] = env.NetworkLookup
    f.Input = env.require("scripts/managers/input/input_service")
    f.State = env.require(STATE)
    f.Human = env.require(INPUT .. "human_unit_input")
    f.Extension = env.require(INPUT .. "player_unit_input_extension")
    f.Handler = env.require(HANDLER .. "human_input_handler")
    f.input_settings = env.require(HANDLER .. "input_handler_settings")
    f.System = env.require("scripts/extension_systems/minigame/minigame_system")
    -- Install the peripheral stub before native class() copies superclass members.
    env.require(ENGINE .. "minigame_base")._setup_sound = noop
    for _, kind in ipairs({ "decode_search", "drill", "frequency", "decode_symbols", "balance" }) do
        env.require(ENGINE .. "minigame_" .. kind)
    end
    f.native_scores = {}
    local native_score = env.MinigameFrequency.test_frequency
    env.MinigameFrequency.test_frequency = function(self, x, y)
        f.native_scores[#f.native_scores + 1] = { game = self, x = x, y = y,
            target = copy(self:target_frequency()), stage = self:current_stage() }
        return native_score(self, x, y)
    end
    if action_chain then
        local native_action = env.MinigameFrequency.action
        env.MinigameFrequency.action = function(self, ...)
            return native_action(self, ...), nil, "chained action", nil
        end
    end
    local mod = {}
    f.mod = mod
    env.get_mod = function(name) eq(name, "BetterBrainer", "mod name"); return mod end
    function mod:localize(id) return id end
    function mod:get(id) f.reads[id] = (f.reads[id] or 0) + 1; return f.values[id] end
    function mod:is_enabled() return f.enabled end
    function mod:io_dofile(path)
        assert(path:match("^BetterBrainer/scripts/mods/BetterBrainer/"), "invalid DMF path: " .. path)
        f.paths[path] = (f.paths[path] or 0) + 1
        local name = path:match("([^/]+)$")
        local value = assert(loadfile(ROOT .. name .. ".lua", "t", env))()
        if name == "BetterBrainer_data" then return value end
        return function(ctx)
            f.ctx = ctx
            local module = value(ctx)
            f.modules[name] = module
            if module.observe then
                local original = module.observe
                module.observe = function(...)
                    f.observations[name] = (f.observations[name] or 0) + 1
                    f.observed_times[name] = select(2, ...)
                    return original(...)
                end
            end
            if module.input then
                local original = module.input
                module.input = function(action, value, t, source)
                    f.input_calls[name] = (f.input_calls[name] or 0) + 1
                    f.input_times[name] = t
                    return original(action, value, t, source)
                end
            end
            return module
        end
    end
    local function wrap_solo()
        local original = env.MinigameFrequency.on_action_pressed
        env.MinigameFrequency.on_action_pressed = function(self, ...)
            local results = table.pack(original(self, ...))
            if not f.client or self ~= f.server then f.solo_callback(self, ...) end
            return table.unpack(results, 1, results.n)
        end
    end
    local function install(target, method, callback, safe)
        if type(target) == "string" then target = assert(env.CLASS[target], target) end
        assert(target ~= f.Extension and target ~= f.Human, "local extension override is forbidden")
        local originals = f.hooks[target]
        if not originals then originals = {}; f.hooks[target] = originals end
        local original = originals[method] or assert(target[method], method)
        originals[method] = original
        if safe then
            target[method] = function(self, ...)
                local results = table.pack(original(self, ...))
                if f.enabled then callback(self, ...) end
                return table.unpack(results, 1, results.n)
            end
        else
            target[method] = function(self, ...)
                if f.enabled then return callback(original, self, ...) end
                return original(self, ...)
            end
        end
        if f.solo_callback and target == env.MinigameFrequency and method == "on_action_pressed" then wrap_solo() end
    end
    function mod:hook(target, method, callback) install(target, method, callback, false) end
    function mod:hook_safe(target, method, callback) install(target, method, callback, true) end
    function mod:hook_require(path, callback)
        if cache[path] then callback(cache[path]) else f.deferred[path] = callback end
    end
    local data = assert(loadfile(ROOT .. "BetterBrainer_data.lua", "t", env))()
    f.data = data
    f.values, f.defaults = {}, {}
    local function defaults(widgets)
        for _, widget in ipairs(widgets) do
            if widget.sub_widgets then defaults(widget.sub_widgets)
            else f.defaults[widget.setting_id] = widget.default_value; f.values[widget.setting_id] = widget.default_value end
        end
    end
    defaults(data.options.widgets)
    for k, v in pairs(overrides or {}) do f.values[k] = v end
    function f:reload()
        if mod.on_unload then mod.on_unload(false) end
        assert(loadfile(ROOT .. "BetterBrainer.lua", "t", env))()
    end
    function f:load_soloplay_frequency()
        local solo, callback = {}, nil
        solo.hook, solo.hook_require = noop, noop
        function solo:hook_safe(target, method, handler)
            if target == env.MinigameFrequency and method == "on_action_pressed" then callback = handler end
        end
        local solo_env = setmetatable({ get_mod = function(name) eq(name, "SoloPlay"); return solo end,
            require = function(path)
                if path == "scripts/utilities/weapon/auspex"
                    or path == "scripts/extension_systems/visual_loadout/utilities/wieldable_slot_scripts" then return {} end
                return env.require(path)
            end }, { __index = env })
        assert(loadfile("referensmoddar/SoloPlay/scripts/mods/SoloPlay/workarounds/communications_hack_device.lua", "t", solo_env))()
        assert(callback, "actual SoloPlay Frequency safe hook")
        -- Preserve the native origin when SoloPlay registers first. DMF hooks.lua:195-205
        -- runs safe callbacks after the regular chain, in either registration order.
        f.hooks[env.MinigameFrequency] = f.hooks[env.MinigameFrequency] or {}
        local originals = f.hooks[env.MinigameFrequency]
        originals.on_action_pressed = originals.on_action_pressed or env.MinigameFrequency.on_action_pressed
        f.solo_callback = callback
        wrap_solo()
    end
    if solo_first then f:load_soloplay_frequency() end
    f:reload()
    function f:set(id, value) self.values[id] = value; mod.on_setting_changed(id) end
    f.raw = { move = env.Vector3.zero(), move_left = 0, move_right = 0, move_forward = 0, move_backward = 0 }
    f.actions = { "action_one_hold", "interact_hold", "jump_held", "action_two_pressed", "interact_pressed",
        "action_one_pressed", "action_one_released", "move_left", "move_right", "move_forward", "move_backward", "move", "unrelated" }
    local present = {}
    for _, action in ipairs(f.actions) do present[action] = true end
    for _, list in ipairs({ f.input_settings.actions, f.input_settings.ephemeral_actions }) do
        for _, action in ipairs(list) do
            if not present[action] then f.actions[#f.actions + 1] = action; present[action] = true end
        end
    end
    f.service = setmetatable({ type = "Ingame", _actions = {}, _aliases = {} }, f.Input)
    for _, action in ipairs(f.actions) do
        local numeric = action:match("^move_") ~= nil
        local kind = action == "move" and "axis" or numeric and "button" or "held"
        if f.raw[action] == nil then f.raw[action] = false end
        f.service._aliases[action] = { "key_" .. action }
        f.service._actions[action] = { type = kind, default_func = f.Input.ACTION_TYPES[kind].default_device_func,
            callbacks = { function() return f.raw[action] end }, key_alias = action }
    end
    f.locks = {}
    f.handler = f.Handler:new(f.player, true)
    local directions = { "move_left", "move_right", "move_forward", "move_backward" }
    local parse_input = f.Handler._parse_input
    f.handler._parse_input = function(handler, ...)
        -- Preserve native parse order. Probe only while the real fixed callback owns the service.
        if f.before_sample then f.before_sample(handler) end
        local get = f.service.get_with_filters
        local scalars, first_move = {}, nil
        f.service.get_with_filters = function(service, action, locks)
            local value = get(service, action, locks)
            for _, direction in ipairs(directions) do
                if action == direction then
                    scalars[action] = value
                    first_move = first_move or service:_get("move")
                end
            end
            return value
        end
        parse_input(handler, ...)
        f.service.get_with_filters = get
        local second_move = f.service:_get("move")
        for _, direction in ipairs(directions) do
            near(get(f.service, direction, f.locks), scalars[direction], "same-sample repeated " .. direction)
        end
        -- Locked scalar aliases need not lock the independent vector action.
        if not next(f.locks) then
            local x, y = scalars.move_right - scalars.move_left, scalars.move_forward - scalars.move_backward
            near(first_move.x, x, "first in-scope vector x")
            near(first_move.y, y, "first in-scope vector y")
            near(second_move.x, x, "second in-scope vector x")
            near(second_move.y, y, "second in-scope vector y")
        end
        if f.in_sample then f.in_sample(handler) end
    end
    function f:sample(frame, fixed_t, handler, skip_pre)
        handler = handler or self.handler
        if not skip_pre then handler:pre_update(0.02, self.t + 1000, self.service, {}) end
        handler:fixed_update(0.02, fixed_t or self.t, frame, self.service, 0, 0, 0)
        local sample = {}
        for _, action in ipairs(self.actions) do
            if handler._action_lookup[action] then sample[action] = handler:get(action, frame) end
        end
        sample.move = self.Human:new(handler._player, handler, frame):get("move")
        local x, y = sample.move_right - sample.move_left, sample.move_forward - sample.move_backward
        near(sample.move.x, x, "buffered HumanUnitInput x")
        near(sample.move.y, y, "buffered HumanUnitInput y")
        if handler == self.handler then self.frames[frame] = sample end
        return sample
    end
    function f:state(mg, player)
        local human = self.Human:new(player, self.handler, 0)
        local extension = setmetatable({ _player = player, _human_unit_input = human }, self.Extension)
        local state = setmetatable({ _player = player, _unit = player.player_unit, _minigame = mg, _previous_input = false,
            _previous_action_one_hold = false, _previous_interact_hold = false, _previous_jump_held = false,
            _input_extension = extension, _is_wielding_minigame_device = yes,
            _animation_extension = { anim_event_1p = function(_, event)
                self.animations = self.animations or {}; self.animations[#self.animations + 1] = event
            end }, _weapon_extension = { update_weapon_actions = function(_, frame)
                self.weapon_frame = frame
            end }, _minigame_character_state_component = {}, _locomotion_steering_component = {},
            _inventory_component = { wielded_slot = "slot_primary", slot_device = "not_equipped" } }, self.State)
        self.extensions[player.player_unit] = { character_state_machine_system = {
            current_state = function() return state end }, unit_data_system = {
            write_component = function() return {} end, read_component = noop } }
        return state
    end
    function f:consume(state, frame, t)
        state._input_extension:fixed_update(nil, 0.02, t or self.t, frame)
        return state:_update_input(t or self.t, frame, state._input_extension)
    end
    function f:dispatch(to, name, args)
        local system = to == "server" and self.server_system or self.client_system
        assert(system and self.System[name], "unexpected RPC: " .. name)
        self.System[name](system, 1, table.unpack(args, 1, args.n))
    end
    function f:send(to, name, ...)
        self.rpc_count[name] = (self.rpc_count[name] or 0) + 1
        if to == "client" and not self.client then return end
        if name == "rpc_minigame_sync_start" then return end -- owner predicts start, other peers excluded
        self.queue[#self.queue + 1] = { at = (self.transport_t or self.t) + self.delay
            + (name == "rpc_minigame_sync_set_stage" and self.stage_skew or 0),
            to = to, name = name, args = copy(table.pack(...)) }
    end
    function f:deliver(all)
        local i = 1
        while i <= #self.queue do
            local item = self.queue[i]
            if all or item.at <= (self.transport_t or self.t) then
                table.remove(self.queue, i)
                self:dispatch(item.to, item.name, item.args)
            else i = i + 1 end
        end
    end
    env.Managers.state.game_session = { fixed_time_step = 0.02,
        send_rpc_clients = function(_, name, ...) f:send("client", name, ...) end,
        send_rpc_clients_except = function(_, name, excluded, ...)
            if f.client and excluded == f.remote:channel_id() then return end
            f:send("client", name, ...)
        end,
        send_rpc_server = function(_, name, ...) f:send("server", name, ...) end }
    function f:open(kind, online, delay, stage_skew)
        self.kind, self.delay, self.stage_skew = kind, delay or 0.12, stage_skew or 0
        local class = cache[ENGINE .. "minigame_" .. kind]
        local function make(server)
            local mg = class:new(nil, server, 1729)
            mg._minigame_unit, mg._minigame_unit_id, mg._is_level_unit = self.terminal, 1, true
            mg._minigame_extension = { minigame_type = function() return kind end, minigame = function() return mg end, set_active = noop }
            return mg
        end
        self.server, self.client = make(true), online and make(false) or nil
        self.server_system = { _unit_to_extension_map = { [self.terminal] = self.server._minigame_extension } }
        self.client_system = self.client and { _unit_to_extension_map = { [self.terminal] = self.client._minigame_extension } }
        self.server:setup_game()
        self.server:start(online and self.remote or self.player)
        if self.client then self.client:start(self.player) end
        self:deliver(true)
        self.game = self.client or self.server
        self.local_state = self:state(self.game, self.player)
        self.server_state = self.client and self:state(self.server, self.remote) or nil
        self:sample(0)
        self:consume(self.local_state, 0)
        return self.game
    end
    function f:tick(frame, fixed_t, skip_pre)
        if not fixed_t then self.t = self.t + 0.02 end
        fixed_t = fixed_t or self.t
        self.transport_t = fixed_t
        self:deliver()
        self.server:update(0.02, fixed_t)
        local sample = self:sample(frame, fixed_t, nil, skip_pre)
        if self.kind == "decode_symbols" and sample.action_one_hold and not self.game:is_completed() then
            self.pulse_on_target = self.game:is_on_target(fixed_t)
        end
        self:consume(self.local_state, frame, fixed_t)
        if self.server_state then
            -- Remote authority consumes the identical serialized sample after 3 ticks.
            if frame > 3 then self:consume(self.server_state, frame - 3, fixed_t - 0.06) end
        end
        self.mod.update(0.02)
        return sample
    end
    return f
end

local tests, failed = 0, 0
local function test(name, body)
    tests = tests + 1
    local ok, err = xpcall(body, debug.traceback)
    if ok then print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end

local function delayed_symbols_at_stage_two(f)
    f:open("decode_symbols", true, 0.14)
    for stage, target in ipairs({ 4, 7, 2, 5 }) do
        f.server:set_target(stage, target)
        f.client:set_target(stage, target)
    end
    for frame = 1, 2000 do
        local sample = f:tick(frame)
        if f.server:current_stage() == 2 and f.client:current_stage() == 2
            and not sample.action_one_hold then return frame end
    end
    error("delayed Symbols client did not stabilize at stage 2")
end

local function complete_delayed_symbols(f, first_frame)
    for frame = first_frame, first_frame + 3000 do
        f:tick(frame)
        if f.server:is_completed() and f.client:is_completed() then
            eq(f.server._mistakes, 0, "server scoring mistakes")
            return
        end
    end
    error("delayed Symbols solve stalled at server/client stages "
        .. tostring(f.server:current_stage()) .. "/" .. tostring(f.client:current_stage()))
end

test("initialization: 15 leaf settings, six groups, canonical paths and retired features absent", function()
    local f = fixture({ expedition_solve_speed = 99, drill_solve_speed = 0 / 0,
        frequency_solve_speed = 2.6, enable_decode_auto = "invalid" })
    local count = 0
    for id in pairs(f.defaults) do count = count + 1; eq(f.reads[id], 1, id) end
    eq(count, 15)
    eq(#f.data.options.widgets - 1, 6, "feature groups")
    local retired = "ser" .. "vo"
    for _, suffix in ipairs({ "enable_" .. retired .. "_skull_auto_hack",
        retired .. "_skull_require_line_of_sight", retired .. "_skull_command_range",
        "enable_decode_smart_reroll" }) do
        eq(f.defaults[suffix], nil, "retired setting " .. suffix)
        eq(f.values[suffix], nil, "retired value " .. suffix)
    end
    eq(f.ctx.settings.expedition_solve_speed, 5)
    eq(f.ctx.settings.drill_solve_speed, 1)
    eq(f.ctx.settings.frequency_solve_speed, 3)
    eq(f.ctx.settings.enable_decode_auto, true)
    near(f.ctx.pacing("frequency_solve_speed"), 0.5)
    count = 0
    for _, n in pairs(f.paths) do count = count + 1; eq(n, 1) end
    eq(count, 7, "data plus six modules")
    eq(f.paths["BetterBrainer/scripts/mods/BetterBrainer/" .. retired], nil, "retired module path")
    eq(f.paths["BetterBrainer/scripts/mods/BetterBrainer/reroll"], nil, "retired reroll module path")
    f.mod.on_setting_changed("not_a_setting")
    eq(f.reads.not_a_setting, nil)
    f:set("frequency_solve_speed", -math.huge)
    eq(f.ctx.settings.frequency_solve_speed, 1)
end)

test("idle/unrelated routes: no observations, no settings reads, no per-read Lua tables", function()
    local f = fixture()
    local reads = copy(f.reads)
    local function exercise()
        for _ = 1, 20000 do
            f.service:_get("unrelated")
            f.service:_get("move_left")
            f.service.type = "Menu"
            f.service:_get("action_one_hold")
            f.service.type = "Ingame"
        end
    end
    exercise()
    collectgarbage("collect"); collectgarbage("stop")
    local before = collectgarbage("count")
    exercise()
    local growth = collectgarbage("count") - before
    collectgarbage("restart")
    assert(growth < 1, "unrelated routes allocated " .. growth .. " KiB with GC stopped")
    eq(next(f.observations), nil)
    for id, n in pairs(reads) do eq(f.reads[id], n, "cached " .. id) end
end)

test("native locked aliases gate automation before _get", function()
    local f = fixture({ expedition_solve_speed = 5 })
    f:open("decode_search", false)
    f.t = f.t + 1
    local get, locked_reads = f.service._get, 0
    f.service._get = function(service, action)
        if action == "move_left" or action == "action_one_hold" then locked_reads = locked_reads + 1 end
        return get(service, action)
    end
    f.locks.key_move_left = true
    f.locks.key_action_one_hold = true
    f.raw.action_one_hold = true
    local sample = f:sample(1)
    eq(sample.move_left, 0)
    eq(sample.action_one_hold, false)
    eq(locked_reads, 0, "native locks must bypass _get inside the handler")
    f.service._get = get
    f.locks = {}
    f.visible = false
    eq(f:sample(2).action_one_hold, true, "closed scanner passes human input")
end)

test("already-held human buttons cannot skip the initial false on any solver", function()
    for _, kind in ipairs({ "decode_search", "drill", "frequency", "decode_symbols" }) do
        local f = fixture()
        f.raw.action_one_hold, f.raw.interact_hold, f.raw.jump_held = true, true, true
        f:open(kind, false)
        eq(f.game._action_held, nil, kind .. " original base ignores initial held")
        f.t = f.t + 0.02
        local sample = f:sample(1)
        eq(sample.action_one_hold, false, kind .. " startup primary release")
        eq(sample.interact_hold, false, kind .. " startup interact release")
        eq(sample.jump_held, false, kind .. " startup jump release")
        f:consume(f.local_state, 1)
        eq(f.game._action_held, false, kind .. " original base armed by serialized false")
    end
end)

test("active solver is not observed by unrelated or menu routes", function()
    local f = fixture()
    f:open("decode_search", false)
    local observed = f.observations.search
    collectgarbage("collect"); collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 20000 do
        f.t = f.t + 0.02
        f.service:_get("unrelated")
        f.service.type = "Menu"
        f.service:_get("move_left")
        f.service.type = "Ingame"
    end
    local growth = collectgarbage("count") - before
    collectgarbage("restart")
    eq(f.observations.search, observed)
    assert(growth < 1, "active unrelated routes allocated " .. growth .. " KiB")
end)

test("buffered human input survives newer solver decisions; original state ordering and returns", function()
    local f = fixture({ enable_expedition_auto_solve = false })
    f:open("decode_search", false)
    f.raw.action_two_pressed = true
    f:sample(1)
    f.raw.action_two_pressed = false
    f.t = f.t + 1
    eq(f:consume(f.local_state, 1), true, "buffered cancel return")
    f.raw.jump_held = true
    f:sample(2)
    eq(f:consume(f.local_state, 2), false)
    eq(f.dodges, 1, "original dodge handling")
    eq(f.weapon_frame, 2, "original weapon action path")
    eq(f.local_state._input_extension.get, f.Extension.get)
    f:set("enable_expedition_auto_solve", true)
    f:sample(3)
    local held = f.frames[3].action_one_hold
    f.t = f.t + 0.3
    f:sample(4)
    eq(f.local_state._input_extension._human_unit_input._input_handler:get("action_one_hold", 3), held)
    f:consume(f.local_state, 3)
    eq(f.local_state._previous_action_one_hold, held, "original state consumes old sample, not latest service decision")
end)

test("remote sessions cannot select solver; ownership loss and dead/missing local unit clear it", function()
    local f = fixture()
    f:open("decode_search", true)
    local before = f.observations.search
    f:consume(f.server_state, 0)
    eq(f.observations.search, before)
    eq(f.ctx.active_minigame, f.client)
    f.client._player_session_id = "remote"
    f:sample(1)
    eq(f.ctx.active_minigame, nil)
    f:consume(f.server_state, 0)
    eq(f.ctx.active_minigame, nil)
    f.client._player_session_id = "local"
    f:consume(f.local_state, 0)
    f.player.player_unit.dead = true
    f.mod.update(0.02)
    eq(f.ctx.active_minigame, nil)
    f.player.player_unit = nil
    f.mod.update(0.02)
    f.timer = false
    eq(f.service:_get("action_one_hold"), false)
end)

test("direct Ingame reads and another player's Handler cannot consume a ready automated press", function()
    local f = fixture({ frequency_solve_speed = 5 })
    f:open("frequency", false)
    f.game._frequency = copy(f.game:target_frequency())
    f.t = f.t + 0.02
    f:sample(1)
    f:consume(f.local_state, 1)
    f.t = f.t + 1
    local calls, observations = f.input_calls.frequency, f.observations.frequency
    for _ = 1, 20 do
        eq(f.service:_get("action_one_hold"), false, "unscoped press passes through")
        eq(f.service:get_with_filters("interact_hold", {}), false, "unscoped filtered hold passes through")
        eq(f.service:_get("move_left"), 0, "unscoped scalar passes through")
    end
    local remote = f.Handler:new(f.remote, true)
    local sample = f:sample(2, f.t, remote)
    eq(sample.action_one_hold, false, "other player's fixed callback passes through")
    eq(sample.action_one_pressed, false, "other player's ephemeral callback passes through")
    eq(f.observations.frequency, observations, "unrelated reads do not observe")
    eq(f.input_calls.frequency, calls, "unrelated reads do not enter solver input")
    local other_service = setmetatable({ type = "Ingame", _actions = f.service._actions, _aliases = f.service._aliases }, f.Input)
    f.in_sample = function()
        local before = f.input_calls.frequency
        eq(other_service:_get("action_one_hold"), false, "another service is excluded even inside local fixed scope")
        eq(f.input_calls.frequency, before)
    end
    eq(f:sample(2).action_one_hold, true, "local handler still receives pending press")
    eq(f.input_times.frequency, f.t, "fixed solver time")
    eq(f.ctx.input_frame, 2)
    calls = f.input_calls.frequency
    eq(f.service:_get("action_one_hold"), false, "scope closes after fixed callback, even during pulse")
    eq(f.input_calls.frequency, calls)
end)

test("scan press is untouched by direct reads/remote Handler; pre_update converts main to gameplay time", function()
    local f = fixture()
    local target = {}
    local components = { weapon_action = { current_action_name = "action_scan" },
        scanning = { is_active = true, line_of_sight = true, scannable_unit = target } }
    f.extensions[f.player.player_unit] = { unit_data_system = { read_component = function(_, name) return components[name] end } }
    f.extensions[target] = { mission_objective_zone_scannable_system = { is_active = yes } }
    local remote = f.Handler:new(f.remote, true)
    for _ = 1, 20 do
        eq(f.service:_get("action_one_pressed"), false)
        eq(f.service:_get("action_one_hold"), false)
    end
    eq(f:sample(1, f.t, remote).action_one_pressed, false)
    eq(f.input_calls.scan, nil, "unrelated routes do not start scanning")
    f.handler:pre_update(0.02, 5000, f.service, {})
    eq(f.input_times.scan, f.t, "ephemeral scan uses gameplay, not main timestamp")
    local calls = f.input_calls.scan
    eq(f.service:_get("action_one_pressed"), false, "ephemeral scope closes")
    eq(f.input_calls.scan, calls)
    local sample = f:sample(1, f.t, nil, true)
    eq(sample.action_one_pressed, true, "pending scan press enters ephemeral buffer")
    eq(sample.action_one_hold, true, "scan hold shares gameplay clock with fixed sample")
    f.t = f.t + 0.02
    sample = f:sample(2)
    eq(sample.action_one_pressed, false, "scan emits a single press")
    eq(sample.action_one_hold, true, "scan continues holding")
end)

for _, kind in ipairs({ "decode_search", "drill", "decode_symbols" }) do
    for _, online in ipairs({ false, true }) do
        test(kind .. ": frozen render clock with fixed catch-up, " .. (online and "delayed client" or "local server"), function()
            local f = fixture({ expedition_solve_speed = 5, drill_solve_speed = 5,
                enable_scan = false, enable_auto_scan = false })
            f:open(kind, online, 0.5)
            if kind == "decode_symbols" then
                for stage, target in ipairs({ 4, 7, 2, 5 }) do
                    f.server:set_target(stage, target)
                    if f.client then f.client:set_target(stage, target) end
                end
            end
            local origin, frozen_frames = f.t, kind == "decode_symbols" and 120 or 40
            local moved, pressed, last_key, last_move_at, previous_move = 0, 0, nil, nil, false
            local previous_hold, press_at, frozen_progress = false, nil, false
            for frame = 1, 4000 do
                local fixed_t = origin + frame * 0.02
                local frozen = frame <= frozen_frames
                if not frozen then f.t = fixed_t end
                local sample = f:tick(frame, fixed_t, frozen and frame > 1)
                if frozen then eq(f.t, origin, "render/gameplay time remains frozen") end
                local module = kind == "decode_search" and "search" or kind == "decode_symbols" and "symbols" or kind
                eq(f.observed_times[module], fixed_t, "observer follows state/input fixed timestamp")
                eq(f.ctx.input_frame, frame, "new fixed frame despite frozen render time")
                if kind ~= "decode_symbols" then
                    local moving = sample.move.x ~= 0 or sample.move.y ~= 0
                    if moving then
                        assert(not previous_move, "intended joystick command must be followed by a neutral sample")
                        local cursor = f.game:cursor_position()
                        local key = tostring(f.game:current_stage()) .. ":" .. cursor.x .. ":" .. cursor.y
                        if online and kind == "drill" and key == last_key then
                            assert(fixed_t - last_move_at >= 0.8 - 1e-9, "duplicate intended movement before acknowledgement/timeout")
                        end
                        last_key, last_move_at, moved = key, fixed_t, moved + 1
                        if frozen then frozen_progress = true end
                    end
                    previous_move = moving
                elseif sample.action_one_hold and not previous_hold then
                    if not online then assert(f.pulse_on_target, "Symbols pulse must match fixed-time engine target window") end
                    if press_at then assert(fixed_t - press_at >= 0.04 - 1e-9, "fixed-time Symbols release interval") end
                    press_at, pressed = fixed_t, pressed + 1
                    if frozen then frozen_progress = true end
                elseif previous_hold and not sample.action_one_hold and not f.game:is_completed() then
                    near(fixed_t - press_at, 0.02, "Symbols releases on the next fixed sample")
                end
                previous_hold = sample.action_one_hold
                if f.server:is_completed() and (not f.client or f.client:is_completed()) then break end
            end
            assert(frozen_progress, "solver must act while render time is frozen for >0.25s")
            assert(f.server:is_completed() and (not f.client or f.client:is_completed()), "catch-up solve stalled")
            eq(f.server._mistakes, 0, "catch-up scoring mistakes")
            if kind == "decode_symbols" then eq(pressed, 4, "one timed pulse per Symbols stage")
            else assert(moved > 0, "movement exercised") end
        end)
    end
end

for _, kind in ipairs({ "decode_search", "drill", "frequency", "decode_symbols" }) do
    for _, online in ipairs({ false, true }) do
        test(kind .. ": full " .. (online and "client/delayed RPC" or "local server") .. " solve, startup false and coherent scalars", function()
            local f = fixture({ expedition_solve_speed = 5, drill_solve_speed = 5, frequency_solve_speed = 5,
                enable_scan = false, enable_auto_scan = false })
            f:open(kind, online, 0.14, kind == "frequency" and 0.10 or 0)
            local seen_false, presses, previous, press_at = false, 0, false, nil
            for frame = 1, 4000 do
                local sample = f:tick(frame)
                local held = sample.action_one_hold
                if not held then seen_false = true end
                if held and not previous then
                    assert(seen_false, "automated press before a serialized false")
                    presses = presses + 1
                    if kind == "decode_symbols" then
                        if press_at then assert(f.t - press_at >= 0.04 - 1e-9, "Symbols serialized release gap") end
                        press_at = f.t
                        if not online then assert(f.pulse_on_target, "symbol pulse outside engine target window") end
                        eq(sample.interact_hold, true, "symbol pulse aliases")
                    end
                end
                if kind == "decode_symbols" and previous and not held and not f.game:is_completed() then
                    near(f.t - press_at, 0.02, "Symbols must release on the next sampled frame")
                end
                previous = held
                if f.server:is_completed() and (not f.client or f.client:is_completed()) then break end
            end
            assert(f.server:is_completed(), "timeout: stage=" .. tostring(f.server:current_stage()) .. " presses=" .. presses)
            if online then assert(f.client:is_completed(), "completion acknowledgement missing") end
            eq(f.server._mistakes, 0, "server scoring mistakes")
            eq(presses, f.server._stage_amount, "one pulse per stage")
            if kind == "frequency" and online then
                eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency, f.server._stage_amount, "client scoring uses actual RPC")
            end
            for _, n in pairs(f.reads) do eq(n, 1, "no settings reads while solving") end
        end)
    end
end

for _, online in ipairs({ false, true }) do
  for _, first in ipairs({ false, true }) do
    test("frequency: SoloPlay scores each automated press only once, " .. (online and "client" or "local")
        .. (first and ", SoloPlay first" or ", BetterBrainer first"), function()
        local f = fixture({ frequency_solve_speed = 5 }, first)
        if not first then f:load_soloplay_frequency() end
        f:open("frequency", online)
        local score, scores, presses, previous = f.server.test_frequency, 0, 0, false
        f.server.test_frequency = function(self, ...)
            scores = scores + 1
            return score(self, ...)
        end
        for frame = 1, 4000 do
            local sample = f:tick(frame)
            if sample.action_one_hold and not previous then presses = presses + 1 end
            previous = sample.action_one_hold
            eq(f.server._mistakes, 0, "SoloPlay must not rescore the old frequency against the next target")
            if f.server:is_completed() and f.game:is_completed() then break end
        end
        assert(f.server:is_completed() and f.game:is_completed(), "SoloPlay solve stalled")
        eq(presses, f.server._stage_amount, "one press per stage")
        eq(scores, presses, "one scoring call per press")
        eq(#f.native_scores, presses, "safe hook must reach native scoring exactly once")
        for _, score in ipairs(f.native_scores) do
            eq(score.x, score.target.x, "SoloPlay native exact x")
            eq(score.y, score.target.y, "SoloPlay native exact y")
        end
    end)
  end
end

for _, mode in ipairs({ "local server", "delayed client", "SoloPlay offline" }) do
    test("frequency: native camera ordering, " .. mode, function()
        local online = mode == "delayed client"
        for _, speed in ipairs({ 1, 3, 5 }) do
            local f = fixture({ frequency_solve_speed = speed })
            if mode == "SoloPlay offline" then f:load_soloplay_frequency() end
            f:open("frequency", online, 0.14, 0.10)
            local camera = { yaw = 0, pitch = 0 }
            f.env.Quaternion = { yaw = function(q) return q.yaw end, pitch = function(q) return q.pitch end }
            f.env.Managers.player.local_player = function() return f.player end
            f.env.Managers.state.camera = { camera_rotation = function() return camera end }
            local origin, frame, previous, presses, off_target = f.t, 0, false, 0, 0
            for render = 1, 6000 do
                -- GameplayStateRun samples/consumes every fixed step, then updates the
                -- camera and minigame at render time (including renders with no fixed step).
                local dt = render % 7 == 0 and 1 / 30 or 1 / 120
                f.t = f.t + dt
                f.transport_t = f.t
                f:deliver()
                f.handler:pre_update(dt, f.t + 1000, f.service, {})
                local last_frame = math.floor((f.t - origin) / 0.02)
                while frame < last_frame do
                    frame = frame + 1
                    local fixed_t = origin + frame * 0.02
                    local sample = f:sample(frame, fixed_t, nil, true)
                    if sample.action_one_hold and not previous then
                        if not f.game:is_visually_on_target() then off_target = off_target + 1 end
                        presses = presses + 1
                    end
                    previous = sample.action_one_hold
                    f:consume(f.local_state, frame, fixed_t)
                    if f.server_state and frame > 3 then
                        f:consume(f.server_state, frame - 3, fixed_t - 0.06)
                    end
                end
                camera.yaw = 0.03 * math.sin((f.t - origin) * 2)
                camera.pitch = 0.02 * math.sin((f.t - origin) * 3)
                if online then
                    f.env.DEDICATED_SERVER = true
                    f.server:update(dt, f.t)
                end
                f.env.DEDICATED_SERVER = false
                f.game:update(dt, f.t)
                f.mod.update(dt)
                if f.server:is_completed() and f.game:is_completed() then break end
            end
            assert(f.server:is_completed() and f.game:is_completed(), "camera solve stalled at speed " .. speed)
            eq(f.server._mistakes, 0, "native camera scoring mistakes at speed " .. speed)
            eq(presses, f.server._stage_amount, "one press per stage with native camera")
            assert(off_target > 0, "exact submission must exercise an off-target visual frequency")
            eq(#f.native_scores, presses, "one native score per press")
            for _, score in ipairs(f.native_scores) do
                eq(score.x, score.target.x, "native scoring receives exact target x")
                eq(score.y, score.target.y, "native scoring receives exact target y")
            end
            if online then
                eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency, presses, "native client scoring RPCs")
            end
        end
    end)
end

test("settings disable/re-enable, DMF toggle, hot reload and gameplay exit rearm without stale pulses", function()
    local f = fixture({ frequency_solve_speed = 5 })
    f:open("frequency", false)
    f:set("enable_frequency_auto", false)
    f.raw.action_one_hold = true
    eq(f:sample(1).action_one_hold, true)
    f:set("enable_frequency_auto", true)
    eq(f:sample(2).action_one_hold, false, "settings rearm initial release")
    f.enabled = false; f.mod.on_disabled()
    eq(f.ctx.active_minigame, nil)
    eq(f:sample(3).action_one_hold, true, "DMF disables hook")
    f.mod.update(0.1)
    f.enabled = true; f.mod.on_enabled()
    f.t = f.t + 1
    f:consume(f.local_state, 0)
    eq(f:sample(4).action_one_hold, false, "enabled rearm")
    local old = f.ctx
    f:reload()
    eq(old.active_minigame, nil, "unload cleared old closure")
    eq(f.ctx.active_minigame, nil)
    f:consume(f.local_state, 0)
    eq(f:sample(5).action_one_hold, false, "reload rearm")
    local observed = f.observations.frequency
    f.t = f.t + 0.01
    f:sample(6)
    eq(f.observations.frequency, observed + 1, "no stacked hooks after reload")
    f.mod.on_game_state_changed("enter", "StateGameplay")
    eq(f.ctx.active_minigame, f.game)
    f.mod.on_game_state_changed("exit", "StateGameplay")
    eq(f.ctx.active_minigame, nil)
    eq(f:sample(7).action_one_hold, true, "reset passes human input")
end)

for _, change in ipairs({
    { id = "drill_solve_speed", value = 1, label = "unrelated solver setting" },
    { id = "enable_decode_highlight", value = false, label = "highlight setting" },
}) do
    test("Symbols delayed stage 2: " .. change.label .. " preserves and completes the active solve", function()
        local f = fixture()
        local frame = delayed_symbols_at_stage_two(f)
        local active, observations = f.ctx.active_minigame, f.observations.symbols
        f:set(change.id, change.value)
        eq(f.ctx.active_minigame, active, "setting change must preserve the selected minigame")
        f:tick(frame + 1)
        assert(f.observations.symbols > observations, "Symbols observation did not continue after setting change")
        complete_delayed_symbols(f, frame + 2)
    end)
end

test("Symbols delayed stage 2: auto-solve off/on rearms false and resumes without a mistake", function()
    local f = fixture()
    local frame = delayed_symbols_at_stage_two(f)
    local stage = f.client:current_stage()
    f:set("enable_decode_auto", false)
    eq(f:tick(frame + 1).action_one_hold, false, "disabled auto-solve leaves neutral input untouched")
    eq(f.client:current_stage(), stage, "disabled auto-solve must not advance the client stage")
    f:set("enable_decode_auto", true)
    f.raw.action_one_hold = true
    eq(f.ctx.active_minigame, f.client, "auto-solve toggle must preserve the selected minigame")
    eq(f:tick(frame + 2).action_one_hold, false, "re-enabled auto-solve must serialize an initial false")
    f.raw.action_one_hold = false
    eq(f.client:current_stage(), stage, "initial false must not advance the client stage")
    eq(f.server._mistakes, 0, "initial false must not score a server mistake")
    complete_delayed_symbols(f, frame + 3)
end)

for _, attachment in ipairs({ "hot reload", "enable" }) do
    test("Symbols delayed stage 2: " .. attachment .. " attaches to the already-open client", function()
        local f = fixture()
        local frame = delayed_symbols_at_stage_two(f)
        if attachment == "hot reload" then
            local old = f.ctx
            f:reload()
            eq(old.active_minigame, nil, "reload must clear the old closure")
        else
            f.enabled = false
            f.mod.on_disabled()
            f:tick(frame + 1)
            frame = frame + 1
            f.enabled = true
            f.mod.on_enabled()
        end
        eq(f.ctx.active_minigame, nil, "attachment starts without retained session state")
        eq(f:tick(frame + 1).action_one_hold, false, "attachment must begin with a serialized false")
        eq(f.ctx.active_minigame, f.client, "existing local state must attach the stage-2 client")
        complete_delayed_symbols(f, frame + 2)
    end)
end

test("actual state exit and Symbols reopen wait for a fresh client clock", function()
    local f = fixture()
    f:open("decode_symbols", true)
    for frame = 1, 8 do f:tick(frame) end
    local old_start = f.game._decode_start_time
    f.local_state:on_exit(f.player.player_unit, f.t, "walking")
    eq(f.ctx.active_minigame, nil)
    eq(f.local_state._minigame, nil, "original deinitialization")
    f.game:start(f.player)
    f.local_state = f:state(f.game, f.player)
    f:consume(f.local_state, 0)
    f.t = f.t + 0.5
    eq(f:sample(9).action_one_hold, false, "old clock blocked on reopen")
    f.game:set_start_time(old_start + 0.5)
    f:sample(10)
    f.t = f.t + 0.14
    f:sample(11)
    eq(f.ctx.active_minigame, f.game)
    local resumed = false
    for frame = 20, 420 do
        f.t = f.t + 0.02
        local sample = f:sample(frame)
        f:consume(f.local_state, frame)
        if sample.action_one_hold then
            assert(f.game:is_on_target(f.t), "reopened pulse uses the new clock")
            resumed = true
            break
        end
    end
    assert(resumed, "fresh clock must unblock the reopened solver")
end)

local function deliver_named(f, name)
    for i, item in ipairs(f.queue) do
        if item.name == name then
            table.remove(f.queue, i)
            f:dispatch(item.to, item.name, item.args)
            return item
        end
    end
    error("missing queued " .. name)
end

for _, first in ipairs({ "stage", "target" }) do
  for _, identical in ipairs({ false, true }) do
    test("frequency: waits for both RPC acknowledgements, " .. first .. " first, identical=" .. tostring(identical), function()
        local f = fixture({ frequency_solve_speed = 5 })
        f:open("frequency", true, 10)
        local frame, pressed = 0, false
        while not pressed and frame < 100 do
            frame = frame + 1
            f.t = f.t + 0.02
            local sample = f:sample(frame)
            pressed = sample.action_one_hold
            if pressed then eq(f.game:is_visually_on_target(), false, "off-target submission") end
            f:consume(f.local_state, frame)
        end
        assert(pressed, "ready Frequency did not submit")
        local submitted = deliver_named(f, "rpc_minigame_sync_frequency_test_frequency")
        local score = f.native_scores[1]
        eq(submitted.args[3], score.target.x, "wire target x")
        eq(submitted.args[4], score.target.y, "wire target y")
        eq(f.server:current_stage(), 2, "native server scoring advanced")
        eq(f.server._mistakes, 0)
        local stage_rpc = "rpc_minigame_sync_set_stage"
        local target_rpc = "rpc_minigame_sync_frequency_set_target_frequency"
        if identical then
            -- A valid repeated target packet must count as an ACK even without a value change.
            for _, item in ipairs(f.queue) do
                if item.name == target_rpc then item.args[3], item.args[4] = score.target.x, score.target.y end
            end
            f.server:set_target_frequency(score.target.x, score.target.y)
        end
        local function blocked()
            for _ = 1, 40 do
                frame, f.t = frame + 1, f.t + 0.02
                local sample = f:sample(frame)
                eq(sample.action_one_hold, false, "incomplete ACK cannot retry")
                eq(sample.action_two_pressed, false, "ACK grace period does not cancel")
                f:consume(f.local_state, frame)
            end
            eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency, 1, "no duplicate RPC")
        end
        blocked()
        deliver_named(f, first == "stage" and stage_rpc or target_rpc)
        blocked()
        deliver_named(f, first == "stage" and target_rpc or stage_rpc)
        frame, f.t = frame + 1, f.t + 0.02
        eq(f:sample(frame).action_one_hold, true, "both acknowledgements unlock next stage")
        f:consume(f.local_state, frame)
        deliver_named(f, "rpc_minigame_sync_frequency_test_frequency")
        eq(#f.native_scores, 2)
        eq(f.server._mistakes, 0)
        eq(f.server:current_stage(), 3)
    end)
  end
end

local function search_pipeline(ping, near_poll)
    local f = fixture({ expedition_solve_speed = 5 })
    if ping ~= nil then f.ping = ping end
    f:open("decode_search", true, 10)
    for _, mg in ipairs({ f.server, f.client }) do
        local symbols = {}
        for i = 1, 24 do symbols[i] = i end
        mg:set_symbols(symbols)
        mg._decode_targets[1] = copy(mg:get_symbols_for_target(5, 3))
        mg:set_cursor_position(1, 1)
    end
    f:set("expedition_solve_speed", 5)
    f.raw.move_right, f.raw.move_forward = 0.4, 0.6
    f.raw.move = f.env.Vector3(0.4, 0.6, 0)
    function f:step()
        self.frame = (self.frame or 0) + 1
        self.t = self.t + 0.02
        local sample = self:sample(self.frame)
        self:consume(self.local_state, self.frame)
        return sample
    end
    eq(f:step().move.x, 0, "startup explicitly neutral")
    if near_poll then f.t = f.t + 0.9 end
    local commands = type(ping) == "number" and ping >= 0.25 and ping < math.huge and 1 or 2
    for command = 1, commands do
        local sample = f:step()
        eq(sample.move.x, 1, "predicted diagonal x")
        eq(sample.move.y, -1, "predicted diagonal y")
        f:consume(f.server_state, f.frame)
        local neutral = f:step()
        eq(neutral.move.x, 0, "release must not leak original x")
        eq(neutral.move.y, 0, "release must not leak original y")
        f:consume(f.server_state, f.frame)
    end
    eq(f.server:cursor_position().x, 1 + commands, "native authority executes pending commands")
    eq(f.server:cursor_position().y, 1 + commands)
    return f
end

test("Search: native late neutral reuses latest movement, without cursor RPC reordering", function()
    local f = search_pipeline(0.12)
    local Authority = f.env.require(HANDLER .. "authoritative_player_input_handler")
    f.remote.peer_id = function() return "remote" end
    local handler = Authority:new(f.remote, true, 0.02)
    f.server_state._input_extension._human_unit_input._input_handler = handler
    local arrays = {}
    -- Frame 4 is the second diagonal; frame 5 is neutral but arrives too late.
    for i, cache in ipairs(f.handler._input_cache) do
        arrays[i] = { cache[f.handler:_buffer_index(4)] }
    end
    handler:rpc_player_input_array(2, 1, 4, 0, table.unpack(arrays))
    local before = copy(f.server:cursor_position())
    f.t = f.t + f.settings.decode_move_delay + 0.02
    handler:fixed_update(0.02, f.t, 5)
    eq(handler:had_received_input(5), false)
    eq(handler:get("move_right", 5), 1, "native fallback repeats latest received sample")
    f:consume(f.server_state, 5)
    eq(f.server:cursor_position().x, before.x + 1, "redundant movement from missing neutral")
    eq(f.server:cursor_position().y, 3, "native bottom border prevents Y overshoot")
    eq(f.server._mistakes, 0)
    eq(f.server:current_stage(), 1, "no submission or stage change")
    for i, cache in ipairs(f.handler._input_cache) do
        arrays[i] = { cache[f.handler:_buffer_index(5)] }
    end
    handler:rpc_player_input_array(2, 1, 5, 0, table.unpack(arrays))
    f:consume(f.server_state, 5)
    eq(f.server._last_move, 0, "late neutral finally resets repeat timer")
    while #f.queue > 0 do
        eq(f.queue[1].name, "rpc_minigame_sync_decode_search_set_cursor", "FIFO cursor receipts only")
        deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    end
    eq(f.client:cursor_position().x, 4)
end)

for _, ping in ipairs({ 0.249, 0.25, 0.394 }) do
    test("Search: RTT window and FIFO partial/full diagonal ACK at " .. ping, function()
        local f = search_pipeline(ping)
        eq(f:step().move.x, 0, "outstanding window is full")
        deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
        eq(f.client:cursor_position().y, 1, "X receipt precedes Y")
        eq(f:step().move.x, 0, "partial diagonal remains pending")
        eq(f.frames[f.frame].action_one_hold, false)
        deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
        eq(f:step().move.x, 1, "full ACK permits next move")
        eq(f:step().move.x, 0)
        eq(f:step().move.x, 0, "full ACK cannot exceed RTT window")
        eq(f.frames[f.frame].action_one_hold, false, "no speculative submission")
    end)
end

test("Search: high RTT receipt after 0.8s still frees a pipeline slot", function()
    local f = search_pipeline(0.9)
    f.t = f.t + 0.81
    eq(f:step().move.x, 0, "command remains pending")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 1, "delayed full ACK must not incur a false timeout drain")
end)

test("Search: low or unavailable ping retains the 0.8s timeout floor", function()
    for _, ping in ipairs({ 0, 0.12, 0.3, false, -1, 0 / 0, math.huge, "missing host", "missing manager" }) do
        local f = search_pipeline(ping)
        if ping == "missing host" then f.env.Managers.connection.host = function() return nil end
        elseif ping == "missing manager" then f.env.Managers.connection = nil end
        -- Exercise the lifecycle guard on the next ping poll as well as initialization.
        f.t = f.t + 0.81
        eq(f:step().move.x, 0, "floor timeout enters recovery")
        while #f.queue > 0 do deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor") end
        f:step()
        f.t = f.t + 1
        eq(f:step().move.x, 0, "first backoff remains 1.6s")
        f.t = f.t + 0.61
        eq(f:step().move.x, 1, "fallback recovery is not lengthened")
    end
end)

for _, ping in ipairs({ 0.12, 0.394 }) do
test("Search: confirmed recovery respects RTT window, not on partial ACK, " .. ping, function()
    local f = search_pipeline(ping)
    f:dispatch("client", "rpc_minigame_sync_decode_search_set_cursor", table.pack(1, true, 1, 3))
    f:step()
    -- Drain old native receipts, then choose a longer remaining diagonal path.
    while #f.queue > 0 do deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor") end
    for _, mg in ipairs({ f.server, f.client }) do
        mg:set_cursor_position(1, 1)
    end
    f:step()
    f.t = f.t + 3.21
    eq(f:step().move.x, 1, "first cautious command")
    f:consume(f.server_state, f.frame)
    eq(f:step().move.x, 0)
    f:consume(f.server_state, f.frame)
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 0, "partial diagonal must not restore pipelining")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 1, "full recovery confirmation permits next command")
    eq(f:step().move.x, 0)
    eq(f:step().move.x, ping < 0.25 and 1 or 0, "full confirmation cannot bypass high RTT cap")
    eq(f:step().move.x, 0)
    eq(f:step().move.x, 0, "still capped at two")
end)
end

test("Search: rising RTT retains two pending moves and caps future commands", function()
    local f = search_pipeline(0.12, true)
    f.ping, f.t = 0.394, f.t + 0.1
    eq(f:step().move.x, 0)
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 0, "first full ACK leaves the second command pending")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 0, "second partial ACK still pending")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 1, "both full ACKs free one slot without resync")
    eq(f:step().move.x, 0)
    eq(f:step().move.x, 0, "new high RTT cap is one")
end)

test("Search: falling RTT expands only on a poll with no pending moves", function()
    local f = search_pipeline(0.394, true)
    f.ping, f.t = 0.12, f.t + 0.1
    eq(f:step().move.x, 0, "low poll cannot expand while pending")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f:step().move.x, 0, "partial ACK cannot expand")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    -- Observe without sampling new commands while the last ACK drains.
    f.t = f.t + 0.02
    f:consume(f.local_state, f.frame)
    f.t = f.t + 1.01
    f:consume(f.local_state, f.frame)
    eq(f:step().move.x, 1)
    eq(f:step().move.x, 0)
    eq(f:step().move.x, 1, "empty-queue low RTT poll restores two")
    eq(f:step().move.x, 0)
    eq(f:step().move.x, 0)
end)

for _, speed in ipairs({ 1, 5 }) do
    test("Search: full 394ms RTT solve, zero mistakes and one press per stage, speed " .. speed, function()
        local f = fixture({ expedition_solve_speed = speed })
        f.ping = 0.394
        f:open("decode_search", true, 0.197)
        local presses, previous = 0, false
        for frame = 1, 4000 do
            local sample = f:tick(frame)
            if sample.action_one_hold and not previous then presses = presses + 1 end
            previous = sample.action_one_hold
            eq(f.server._mistakes, 0, "no wrong submission throughout solve")
            if f.server:is_completed() and f.client:is_completed() then break end
        end
        assert(f.server:is_completed() and f.client:is_completed(), "high RTT solve stalled")
        eq(presses, f.server._stage_amount)
    end)
end

test("Search: repeated faults cap each quiet recovery wait at 3.2s", function()
    local f = search_pipeline()
    for fault = 1, 6 do
        f:dispatch("client", "rpc_minigame_sync_decode_search_set_cursor",
            table.pack(1, true, 1, fault % 2 == 0 and 1 or 3))
        eq(f:step().move.x, 0, "mismatch enters recovery")
        f.t = f.t + 3.21
        eq(f:step().move.x, 1, "bounded recovery attempt " .. fault)
        eq(f:step().move.x, 0, "neutral after retry")
    end
end)

test("Search: high-ping same-instance exit/setup/reopen retains queued cursor RPCs and solves", function()
    local f = search_pipeline(0.12)
    f.ping = 0.9 -- Preserve the original two-command late-traffic scenario across a latency rise.
    local server, client, board, stage = f.server, f.client, f.server:symbols(), f.server:current_stage()
    for _, mg in ipairs({ server, client }) do
        for s = 2, mg._stage_amount do
            mg._decode_targets[s] = copy(mg:get_symbols_for_target(s % 2 == 0 and 1 or 5, 3))
        end
    end
    f.raw.move_right, f.raw.move_forward = 0, 0
    f.raw.move = f.env.Vector3.zero()
    f.local_state:on_exit(f.player.player_unit, f.t, "walking")
    eq(f.ctx.active_minigame, nil, "actual state exit resets solver")
    -- Nonautomatic authority stop excludes its owner; automatic/late broadcast is tested separately.
    f.server:stop(false)
    f.delay = 0.9
    f.server:setup_game()
    f.server:start(f.remote)
    f.client:start(f.player)
    f.local_state, f.server_state = f:state(client, f.player), f:state(server, f.remote)
    eq(f.server, server); eq(f.client, client); eq(f.server:symbols(), board)
    eq(f.server:current_stage(), stage, "restart retains stage")
    eq(f.server:cursor_position().x, 3, "native setup recenters X")
    eq(f.server:cursor_position().y, 2, "native setup recenters Y")
    assert(#f.queue >= 5, "old split cursor receipts and setup remain queued")
    -- Keep FIFO but bound this fixture's deliberately withheld old receipts to the new latency.
    for _, item in ipairs(f.queue) do item.at = f.t + 0.9 end
    f:consume(f.local_state, f.frame)
    local reopened_at, finished_at = f.t, nil
    for frame = f.frame + 1, f.frame + 2500 do
        f:tick(frame)
        if f.server:is_completed() and f.client:is_completed() then finished_at = f.t; break end
    end
    assert(finished_at, "same-instance reopen stalled")
    eq(f.server._mistakes, 0, "no stale submission after reopen")
    -- One move per receipt now deliberately trades throughput for less prediction.
    assert(finished_at - reopened_at < 24, "reopen must remain bounded with serial high RTT movement")
    print(string.format("Search same-instance reopen: %.2fs", finished_at - reopened_at))
end)

test("Search: queued late stop retains active client without fabricating ownership", function()
    local f = search_pipeline(0.9)
    f.local_state:on_exit(f.player.player_unit, f.t, "walking")
    f.server_state:on_exit(f.remote.player_unit, f.t, "walking")
    f.server:setup_game()
    f.server:start(f.remote)
    f.client:start(f.player)
    f.local_state = f:state(f.client, f.player)
    f:consume(f.local_state, f.frame)
    deliver_named(f, "rpc_minigame_sync_stop")
    eq(f.client:player_session_id(), nil, "native stop invalidates restarted ownership")
    f:step()
    f.mod.update(0.02)
    eq(f.ctx.active_minigame, f.client, "locally active Search survives nil owner")
    eq(f.client:player_session_id(), nil, "no fabricated owner")
end)

for _, receipt in ipairs({ "rpc_minigame_sync_stop", "rpc_minigame_sync_start" }) do
    test("Search: nil owner after " .. receipt .. ", manual server movement then full solve", function()
        local f = fixture({ expedition_solve_speed = 5, enable_expedition_auto_solve = false })
        f.ping = 0.394
        f:open("decode_search", true, 0.197)
        local state = f.local_state
        f:dispatch("client", receipt, table.pack(1, true))
        eq(f.client:player_session_id(), nil)
        local x = f.client:cursor_position().x
        f.raw.move_right = 1
        f.raw.move = f.env.Vector3(1, 0, 0)
        for frame = 1, 4 do f:tick(frame) end
        f.raw.move_right = 0
        f.raw.move = f.env.Vector3.zero()
        for frame = 5, 20 do f:tick(frame) end
        assert(f.client:cursor_position().x ~= x, "native server accepts serialized manual movement")
        eq(f.local_state, state)
        f:set("enable_expedition_auto_solve", true)
        for frame = 21, 4020 do
            f:tick(frame)
            eq(f.client:player_session_id(), nil, "automation must not assign owner or restart")
            eq(f.server:player_session_id(), "remote", "authority owner unchanged")
            if f.server:is_completed() and f.client:is_completed() then break end
        end
        assert(f.server:is_completed() and f.client:is_completed(), "nil-owner Search solve stalled")
        eq(f.server._mistakes, 0)
    end)
end

for _, kind in ipairs({ "decode_search", "drill", "frequency", "decode_symbols", "balance" }) do
    for _, receipt in ipairs({ "rpc_minigame_sync_start", "rpc_minigame_sync_stop" }) do
        test(kind .. ": native ownerless receipt continues input: " .. receipt, function()
            local f = fixture({ expedition_solve_speed = 5, drill_solve_speed = 5, frequency_solve_speed = 5 })
            f:open(kind, true, 0.14)
            f:dispatch("client", receipt, table.pack(1, true))
            eq(f.client:player_session_id(), nil)
            if kind == "balance" then
                -- Exercise steering/authority, not LuaJIT's float-bound random disruption.
                f.server._disrupt_timer = 100
                f.server:set_position(0.7, 0)
                f:dispatch("client", "rpc_minigame_sync_balance_set_position", table.pack(1, true, 0.7, 0))
                f.t = f.t + 0.02
                f:dispatch("client", "rpc_minigame_sync_balance_set_position", table.pack(1, true, 0.7, 0))
                local sample = f:tick(1)
                assert(sample.move_left > 0, "real Balance solver must steer inward")
                local speed = f.server._speed.x
                f:consume(f.server_state, 1)
                assert(f.server._speed.x < speed, "native Balance authority consumes steering")
            else
                for frame = 1, 4000 do
                    f:tick(frame)
                    if f.server:is_completed() and f.client:is_completed() then break end
                end
                assert(f.server:is_completed() and f.client:is_completed(), "ownerless solve stalled")
                eq(f.server._mistakes, 0)
            end
            eq(f.client:player_session_id(), nil, "no fabricated client owner")
            eq(f.server:player_session_id(), "remote")
        end)
    end
    for _, owner in ipairs({ "nil", "local", "remote" }) do
        test(kind .. ": strict submission identity, owner=" .. owner, function()
            local f = fixture()
            f:open(kind, true)
            f.client._player_session_id = owner ~= "nil" and owner or nil
            eq(f.ctx.session_valid(f.client), owner ~= "remote")
            eq(f.ctx.session_valid(f.server), false, "different minigame")
            local csm = f.extensions[f.player.player_unit].character_state_machine_system
            csm.current_state = function() return {} end
            eq(f.ctx.session_valid(f.client), false, "server correction replaced actual state")
            f:consume(f.local_state, 0)
            eq(f.ctx.session_valid(f.client), false, "stale input callback cannot authorize submission")
        end)
    end
end

for _, receipt in ipairs({ "rpc_minigame_sync_start", "rpc_minigame_sync_stop",
    "rpc_minigame_sync_decode_symbols_set_start_time" }) do
    test("Symbols: in-flight " .. receipt .. " retains board gating and completes", function()
        local f = fixture()
        f:open("decode_symbols", true, 0.14)
        local first_frame
        for frame = 1, 1000 do
            if f:tick(frame).action_one_hold then first_frame = frame; break end
        end
        assert(first_frame, "first pending prediction")
        local clock = f.client._decode_start_time
        f:dispatch("client", receipt, table.pack(1, true, clock / 0.02))
        eq(f.client._decode_start_time, clock)
        complete_delayed_symbols(f, first_frame + 1)
        eq(f.client:player_session_id(), receipt == "rpc_minigame_sync_decode_symbols_set_start_time" and "local" or nil)
    end)
    test("Symbols: pending predictions survive continuing " .. receipt, function()
        local f = fixture()
        f:open("decode_symbols", true, 10)
        local frame
        for i = 1, 1000 do
            if f:tick(i).action_one_hold then frame = i; break end
        end
        assert(frame, "first prediction")
        local clock = f.client._decode_start_time
        f:dispatch("client", receipt, table.pack(1, true, clock / 0.02))
        eq(f.client._decode_start_time, clock, "native receipt retains board clock")
        if receipt == "rpc_minigame_sync_stop" then
            eq(f.client._action_held, nil)
            eq(f:tick(frame + 1).action_one_hold, false, "stop requires a fresh serialized release")
        end
        f.t = f.t + 2.51
        assert(f.modules.symbols.cancel_requested(), "oldest pending prediction must retain its deadline")
        f.local_state:on_exit(f.player.player_unit, f.t, "walking")
        eq(f.modules.symbols.cancel_requested(), false, "real stop(Player) clears pending work")
        eq(f.ctx.active_minigame, nil)
    end)
end

for _, online in ipairs({ false, true }) do
    for _, boundary in ipairs({ "owner", "state", "unit" }) do
        test("Frequency: mid-action " .. boundary .. " change blocks exact answer, client=" .. tostring(online), function()
            local f = fixture({ frequency_solve_speed = 5 }, false, true)
            f:open("frequency", online)
            f:tick(1)
            f.t = f.t + 1
            eq(f:sample(2).action_one_hold, true)
            local original = f.game.on_action_pressed
            f.game.on_action_pressed = function(self, t)
                original(self, t)
                if boundary == "owner" then self._player_session_id = "foreign"
                elseif boundary == "unit" then f.player.player_unit = {}
                else f.extensions[f.player.player_unit].character_state_machine_system.current_state = function() return {} end end
            end
            local count = f.rpc_count.rpc_minigame_sync_frequency_test_frequency or 0
            local results = table.pack(f.game:action(true, f.t))
            eq(results.n, 4); eq(results[1], true); eq(results[3], "chained action")
            eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency or 0, count, "no injected RPC after identity loss")
            eq(#f.native_scores, 0, "no injected local score after identity loss")
        end)
    end
end

test("Frequency: SoloPlay scoring rechecks identity after consumed press", function()
    local f = fixture({ frequency_solve_speed = 5 })
    f:load_soloplay_frequency()
    f:open("frequency", false)
    f:tick(1)
    f.t = f.t + 1
    eq(f:sample(2).action_one_hold, true)
    local callback = f.solo_callback
    f.solo_callback = function(self, ...)
        f.extensions[f.player.player_unit].character_state_machine_system.current_state = function() return {} end
        return callback(self, ...)
    end
    eq(f.game:action(true, f.t), true)
    eq(#f.native_scores, 0, "neither SoloPlay redirect nor finish_action may inject a score")
end)

test("nil ownership stays strict on local authority", function()
    for _, kind in ipairs({ "decode_search", "drill", "frequency", "decode_symbols", "balance" }) do
        local f = fixture()
        f:open(kind, false)
        f.game._player_session_id = nil
        f:consume(f.local_state, 0)
        f:sample(1)
        eq(f.ctx.active_minigame, nil, kind .. " nil owner rejected")
    end
end)

for _, boundary in ipairs({ "foreign owner", "stale state", "missing csm", "changed unit", "dead unit",
    "changed player", "changed minigame", "exit", "disable", "gameplay exit", "hidden", "locks", "auto off" }) do
    test("Search nil-owner boundary: " .. boundary, function()
        local f = fixture({ expedition_solve_speed = 5 })
        f:open("decode_search", true)
        f:dispatch("client", "rpc_minigame_sync_start", table.pack(1, true))
        local extensions = f.extensions[f.player.player_unit]
        if boundary == "foreign owner" then f.client._player_session_id = "remote"
        elseif boundary == "stale state" then extensions.character_state_machine_system.current_state = function() return {} end
        elseif boundary == "missing csm" then extensions.character_state_machine_system = nil
        elseif boundary == "changed unit" then f.player.player_unit = {}
        elseif boundary == "dead unit" then f.player.player_unit.dead = true
        elseif boundary == "changed player" then f.env.Managers.player.local_player_safe = function() return f.remote end
        elseif boundary == "changed minigame" then f.local_state._minigame = nil
        elseif boundary == "exit" then f.local_state:on_exit(f.player.player_unit, f.t, "walking")
        elseif boundary == "disable" then f.enabled = false; f.mod.on_disabled()
        elseif boundary == "gameplay exit" then f.mod.on_game_state_changed("exit", "StateGameplay")
        elseif boundary == "hidden" then f.visible = false
        elseif boundary == "locks" then
            for _, action in ipairs(f.actions) do f.locks["key_" .. action] = true end
        elseif boundary == "auto off" then f:set("enable_expedition_auto_solve", false) end
        for frame = 1, 20 do
            f.t = f.t + 0.02
            f.mod.update(0.02)
            local sample = f:sample(frame)
            eq(sample.move.x, 0); eq(sample.move.y, 0)
            eq(sample.action_one_hold, false); eq(sample.action_two_pressed, false)
        end
        eq(f.client:player_session_id(), boundary == "foreign owner" and "remote" or nil)
    end)
end

test("Search: two-command cap, partial diagonal ACK does not retire its command", function()
    local f = search_pipeline()
    for _ = 1, 5 do eq(f:step().move.x, 0, "two outstanding commands block a third") end
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f.client:cursor_position().x, 2)
    eq(f.client:cursor_position().y, 1, "native X-only diagonal acknowledgement")
    eq(f:step().move.x, 0, "partial ACK leaves both commands outstanding")
    deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor")
    local third = f:step()
    eq(third.move.x, 1, "full ACK frees exactly one slot")
    eq(third.move.y, 0, "third move starts from predicted tail, not partial cursor")
    eq(f:step().move.x, 0)
    eq(f:step().move.x, 0, "third command fills window again")
    f:set("enable_expedition_auto_solve", false)
    local manual = f:step()
    near(manual.move.x, 0.4, "disabled passes original movement")
    near(manual.move.y, 0.6)
end)

for _, fault in ipairs({ "mismatch", "timeout" }) do
    test("Search: " .. fault .. " drains late traffic and recovers with one pending command", function()
        local f = search_pipeline()
        if fault == "mismatch" then
            f:dispatch("client", "rpc_minigame_sync_decode_search_set_cursor", table.pack(1, true, 1, 3))
        else
            f.t = f.t + 0.81
        end
        eq(f:step().move.x, 0, "fault enters neutral recovery")
        f.t = f.t + 1
        eq(f:step().move.x, 0, "must not resume before drain interval")
        while #f.queue > 0 do deliver_named(f, "rpc_minigame_sync_decode_search_set_cursor") end
        eq(f:step().move.x, 0, "late cursor traffic restarts drain interval")
        f.t = f.t + 1
        eq(f:step().move.x, 0)
        f.t = f.t + 0.7
        eq(f:step().move.x, 1, "recovery resumes from acknowledged cursor")
        eq(f:step().move.x, 0, "mandatory neutral")
        for _ = 1, 10 do eq(f:step().move.x, 0, "cautious mode permits only one pending command") end
    end)
end

for _, failure in ipairs({ "timeout", "same-stage failure" }) do
    test("Symbols: max two predicted edges; " .. failure .. " preserves the second pending command", function()
        local f = fixture()
        f:open("decode_symbols", true, 10)
        for stage, target in ipairs({ 2, 3, 4, 5 }) do
            f.client:set_target(stage, target)
            f.server:set_target(stage, target)
        end
        local frame, edges, previous = 0, {}, false
        local function step()
            frame, f.t = frame + 1, f.t + 0.02
            local sample = f:sample(frame)
            f:consume(f.local_state, frame)
            if sample.action_one_hold and not previous then edges[#edges + 1] = { frame = frame, t = f.t } end
            assert(not (sample.action_one_hold and previous), "single-frame Symbols pulse")
            previous = sample.action_one_hold
            return sample
        end
        for _ = 1, 55 do step() end
        eq(#edges, 2, "two predicted stages without any acknowledgement")
        eq(f.client:current_stage(), 1, "prediction never mutates engine stage")
        if failure == "timeout" then
            for _ = 1, 30 do step() end
            eq(#edges, 2, "timeout is not acknowledgement")
            assert(f.t - edges[1].t >= 1.2, "exercise prediction timeout before cancel deadline")
            f.server:on_action_pressed(edges[1].t)
            eq(f.server:current_stage(), 2, "first pending press scores at native target time")
        else
            f.server:on_action_pressed(f.server:start_time())
            eq(f.server:current_stage(), 1)
            eq(f.server._mistakes, 1, "native same-stage failure")
        end
        deliver_named(f, "rpc_minigame_sync_set_stage")
        for _ = 1, 20 do
            eq(step().action_two_pressed, false, "second pending command remains inside cancellation deadline")
        end
        eq(#edges, 2, "first ACK cannot discard second outstanding command")
        f.server:on_action_pressed(failure == "timeout" and edges[2].t or f.server:start_time())
        deliver_named(f, "rpc_minigame_sync_set_stage")
        for _ = 1, 220 do
            step()
            if #edges > 2 then break end
        end
        eq(#edges, 3, "draining both pending commands allows recovery")
        for _ = 1, 60 do step() end
        eq(#edges, 3, "failure/timeout recovery disables speculative second edge")
    end)
end

for _, kind in ipairs({ "decode_search", "drill", "frequency", "decode_symbols" }) do
  for _, first_read in ipairs({ "move", "jump_held" }) do
    test(kind .. ": short shared pulse, " .. first_read .. " read first, locked primary alias", function()
        local f = fixture({ expedition_solve_speed = 5, drill_solve_speed = 5, frequency_solve_speed = 5 })
        f:open(kind, false)
        f.locks.key_action_one_hold = true
        local first_values
        f.before_sample = function()
            f.service:get_with_filters(first_read, f.locks)
            first_values = {
                jump_held = f.service:get_with_filters("jump_held", f.locks),
                interact_hold = f.service:get_with_filters("interact_hold", f.locks),
            }
        end
        f.in_sample = function()
            eq(f.service:get_with_filters("action_one_released", f.locks), false, "solver leaves release action untouched")
            for _ = 1, 3 do
                for _, alias in ipairs({ "interact_hold", "jump_held" }) do
                    eq(f.service:get_with_filters(alias, f.locks), first_values[alias], "same-frame alias read is stable")
                end
            end
        end
        local frame, pulse_frame = 0, nil
        for i = 1, 1000 do
            frame = i
            local sample = f:tick(frame)
            eq(sample.action_one_hold, false, "native alias lock stays authoritative")
            eq(sample.interact_hold, sample.jump_held, "unlocked aliases share the edge")
            eq(sample.action_one_pressed, false, "fixed pulse does not synthesize ephemeral press")
            eq(sample.action_one_released, nil, "native handler does not serialize release action")
            if sample.interact_hold then pulse_frame = frame; break end
        end
        assert(pulse_frame, "unlocked aliases must still submit")
        eq(f.server:current_stage(), 2, "native OR of aliases scores one stage")
        eq(f.server._mistakes, 0)
        -- Neither render time nor an 80ms hold timer is needed to release the next sample.
        local sample = f:sample(frame + 1, f.t, nil, true)
        eq(sample.interact_hold, false, "next fixed frame releases at identical timestamp")
        eq(sample.jump_held, false)
        f:consume(f.local_state, frame + 1)
        eq(f.server:current_stage(), 2, "release does not score again")
    end)
  end
end

test("Symbols: new board RPC discards old predictions and waits for a fresh stable clock", function()
    local f = fixture()
    f:open("decode_symbols", true, 10)
    for stage, target in ipairs({ 2, 3, 4, 5 }) do f.client:set_target(stage, target) end
    local presses = 0
    for frame = 1, 55 do
        f.t = f.t + 0.02
        if f:sample(frame).action_one_hold then presses = presses + 1 end
        f:consume(f.local_state, frame)
    end
    eq(presses, 2, "old board has two outstanding predictions")
    local old_start = f.client:start_time()
    f:dispatch("client", "rpc_minigame_sync_decode_symbols_set_symbols", table.pack(1, true, copy(f.client:symbols())))
    for frame = 56, 80 do
        f.t = f.t + 0.02
        eq(f:sample(frame).action_one_hold, false, "same old clock cannot unlock replacement board")
    end
    f:dispatch("client", "rpc_minigame_sync_decode_symbols_set_start_time", table.pack(1, true, f.t / 0.02))
    assert(f.client:start_time() ~= old_start)
    eq(f:sample(81).action_one_hold, false, "fresh clock begins stable-board wait")
    local resumed = false
    for frame = 82, 300 do
        f.t = f.t + 0.02
        if f:sample(frame).action_one_hold then resumed = true; break end
    end
    assert(resumed, "fresh stable clock rearms without obsolete pending commands")
end)

for _, kind in ipairs({ "decode_search", "drill" }) do
  for _, online in ipairs({ false, true }) do
    test(kind .. ": fast exit after native final stage, " .. (online and "client ACK" or "local authority"), function()
        local f = fixture({ expedition_solve_speed = 5, drill_solve_speed = 5 })
        f:open(kind, online, 0.14)
        local frame = 0
        repeat
            frame = frame + 1
            local sample = f:tick(frame)
            eq(sample.action_two_pressed, false, "no cancel during unfinished solve")
            assert(frame < 3000, "solve stalled")
        until f.server:is_completed()
        if online then
            eq(f.client:is_completed(), false, "final authority stage still in transport")
            frame, f.t = frame + 1, f.t + 0.02
            eq(f:sample(frame).action_two_pressed, false, "local submission alone cannot exit")
            f:deliver(true)
        end
        eq(f.game:is_completed(), true)
        eq(f.game:should_exit(), false, "native outro still running")
        f.locks.key_action_two_pressed = true
        frame = frame + 1
        eq(f:sample(frame).action_two_pressed, false, "UI lock must not spend the cancel")
        f.locks = {}
        eq(f.service:_get("action_two_pressed"), false, "unscoped read cannot spend cancel")
        f.handler:pre_update(0.02, f.t + 1000, f.service, {})
        f.handler:pre_update(0.02, f.t + 1000, f.service, {})
        frame = frame + 1
        eq(f:sample(frame, nil, nil, true).action_two_pressed, true, "ephemeral cache retains single cancel")
        eq(f:consume(f.local_state, frame), true, "native state returns cancel")
        frame = frame + 1
        eq(f:sample(frame).action_two_pressed, false, "no duplicate fast exit")
        f.local_state:on_exit(f.player.player_unit, f.t, "walking")
        eq(f.ctx.active_minigame, nil, "native state exit cleans session")
    end)
  end
end

for _, supported in ipairs({ "decode_search", "drill" }) do
for _, gate in ipairs({ "disabled", "manual", "highlight", "hidden", "unsupported", "frequency", "decode_symbols" }) do
    test(supported .. " fast exit excluded: " .. gate, function()
        local f = fixture()
        local kind = (gate == "frequency" or gate == "decode_symbols") and gate or supported
        f:open(kind, true)
        if gate == "disabled" then f.enabled = false; f.mod.on_disabled()
        elseif gate == "manual" or gate == "highlight" then
            f:set(supported == "drill" and "enable_drill_auto" or "enable_expedition_auto_solve", false)
            f:set(supported == "drill" and "enable_drill" or "enable_matching", gate == "highlight")
        elseif gate == "hidden" then f.visible = false
        elseif gate == "unsupported" then
            f.game._minigame_extension.minigame_type = function() return "unsupported" end
            f:consume(f.local_state, 0)
        end
        f:dispatch("client", "rpc_minigame_sync_set_stage", table.pack(1, true, f.game._stage_amount + 1))
        eq(f.game:is_completed(), true)
        for frame = 1, 3 do
            f.t = f.t + 0.02
            eq(f:sample(frame).action_two_pressed, false, "no automatic cancel")
        end
        f.raw.action_two_pressed = true
        eq(f:sample(4).action_two_pressed, true, "manual cancel remains available")
    end)
end
end

test("native class inheritance copies methods; concrete Symbols setter drains the client queue", function()
    local f = fixture()
    local base, symbols = f.env.MinigameBase, f.env.MinigameDecodeSymbols
    assert(rawget(symbols, "set_current_stage"), "native class copies the inherited setter")
    local inherited = symbols.set_current_stage
    base.set_current_stage = function() error("late Base replacement must not intercept copied Symbols setter") end
    eq(symbols.set_current_stage, inherited)
    local frame = delayed_symbols_at_stage_two(f)
    complete_delayed_symbols(f, frame + 1)
    eq(f.client:current_stage(), f.client._stage_amount + 1, "all concrete-class stage ACKs consumed")
end)

for _, early in ipairs({ true, false }) do
  for _, same_clock in ipairs({ false, true }) do
    test("Symbols: native retained-board restart, RPC " .. (early and "before" or "after")
        .. " local init, same clock=" .. tostring(same_clock), function()
        local f = fixture()
        f.enabled = false
        f:open("decode_symbols", true, 0.197)
        f.client:set_current_stage(3)
        if same_clock then f.client:set_start_time(689.67307692307691) end
        local client, old_board = f.client, f.client:symbols()
        f.enabled = true
        f.mod.on_enabled()
        eq(f.ctx.active_minigame, nil, "no module game before receipts")
        f.server:stop(false)
        f.t, f.ping = 357.52565488226963, 0.394
        f.rewind = 689.67307692307691 - f.t
        local old_clock = f.client:start_time()
        f.server:setup_game()
        f.server:start(f.remote)
        eq(f.client:symbols(), old_board, "retained board before native RPCs")
        eq(f.client:current_stage(), 3, "retained stage before native RPCs")
        if early then f:deliver(true) end
        -- Execute the actual unit-initialization call site, not a solver start helper.
        f.extensions[f.terminal] = { minigame_system = f.client._minigame_extension }
        f.local_state._minigame = nil
        f.local_state._is_server = false
        f.local_state._minigame_character_state_component = {
            interface_is_level_unit = true, interface_level_unit_id = 1, interface_game_object_id = -1,
        }
        assert(f.local_state:_check_initialize_minigame_from_unit())
        if not early then f:deliver(true) end
        eq(f.client, client, "same native minigame instance")
        assert(f.client:symbols() ~= old_board, "native set_symbols clones replacement board")
        eq(f.client:current_stage(), 1)
        near(f.client:start_time(), 689.67307692307691)
        eq(f.client:start_time() == old_clock, same_clock)
        assert(f.client:start_time() > f.t, "future engine clock remains valid")
        f:consume(f.local_state, 0)
        eq(f:sample(1).action_one_hold, false, "first sample releases")
        complete_delayed_symbols(f, 2)
    end)
  end
end

for _, receipt in ipairs({ "explicit foreign", "native other start", "native stop", "local stop",
    "board replacement", "disable" }) do
    test("Symbols: early clock retired by " .. receipt .. " cannot authorize local start", function()
        local f = fixture()
        f.enabled = false
        f:open("decode_symbols", true, 10)
        f.enabled = true
        f.mod.on_enabled()
        f.server:stop(false)
        f.server:setup_game()
        f:deliver(true)
        if receipt == "explicit foreign" then f.client:start(f.remote)
        elseif receipt == "native other start" then
            f:dispatch("client", "rpc_minigame_sync_start", table.pack(1, true))
        end
        f:dispatch("client", "rpc_minigame_sync_decode_symbols_set_start_time", table.pack(1, true, (f.t + 300) / 0.02))
        if receipt == "native stop" then
            f:dispatch("client", "rpc_minigame_sync_stop", table.pack(1, true))
        elseif receipt == "local stop" then f.client:stop(f.player)
        elseif receipt == "board replacement" then
            f:dispatch("client", "rpc_minigame_sync_decode_symbols_set_symbols",
                table.pack(1, true, copy(f.client:symbols())))
        elseif receipt == "disable" then
            f.enabled = false
            f.mod.on_disabled()
            f.enabled = true
            f.mod.on_enabled()
        end
        f.client:start(f.player)
        f:consume(f.local_state, 0)
        for frame = 1, 220 do
            f.t = f.t + 0.02
            eq(f:sample(frame).action_one_hold, false, "no new own clock, never press")
            f:consume(f.local_state, frame)
        end
        -- Even an identical numeric clock is a new receipt after the own start.
        f:dispatch("client", "rpc_minigame_sync_decode_symbols_set_start_time",
            table.pack(1, true, f.client:start_time() / 0.02))
        local pressed = false
        for frame = 221, 500 do
            f.t = f.t + 0.02
            if f:sample(frame).action_one_hold then pressed = true; break end
            f:consume(f.local_state, frame)
        end
        assert(pressed, "fresh own receipt unlocks even a reused fixed frame")
    end)
end

test("Symbols: another player's retained clock is stale even without mod session history", function()
    local f = fixture()
    f.enabled = false
    f:open("decode_symbols", true, 10)
    f.client:start(f.remote)
    f.client:set_start_time(f.t - 1)
    local retained = f.client:start_time()
    f.enabled = true
    f.mod.on_enabled()
    eq(f.ctx.active_minigame, nil, "mod never recorded the remote board")
    f.client:start(f.player)
    f.local_state = f:state(f.client, f.player)
    f:consume(f.local_state, 0)
    for frame = 1, 220 do
        f.t = f.t + 0.02
        local sample = f:sample(frame)
        eq(sample.action_one_hold, false, "retained remote clock must never become valid after 0.12s")
        eq(sample.action_two_pressed, false, "no command was submitted, so no uncertainty cancel")
        f:consume(f.local_state, frame)
    end
    eq(f.client:start_time(), retained)
    f:dispatch("client", "rpc_minigame_sync_decode_symbols_set_start_time", table.pack(1, true, f.t / 0.02))
    local pressed = false
    for frame = 221, 500 do
        f.t = f.t + 0.02
        local sample = f:sample(frame)
        f:consume(f.local_state, frame)
        if sample.action_one_hold then pressed = true; break end
    end
    assert(pressed, "new server clock enables the retained board")
end)

local function pending_session(kind)
    local f = fixture({ frequency_solve_speed = 5 })
    f:open(kind, true, 10)
    if kind == "decode_symbols" then
        for stage, target in ipairs({ 2, 3, 4, 5 }) do
            f.client:set_target(stage, target)
            f.server:set_target(stage, target)
        end
    end
    f.frame, f.edges = 0, {}
    function f:step(dt)
        self.frame, self.t = self.frame + 1, self.t + (dt or 0.02)
        local sample = self:sample(self.frame)
        if sample.action_one_hold then self.edges[#self.edges + 1] = { frame = self.frame, t = self.t } end
        self.cancel_return = self:consume(self.local_state, self.frame)
        return sample
    end
    local count = kind == "frequency" and 1 or 2
    while #f.edges < count and f.frame < 100 do f:step() end
    eq(#f.edges, count, "initial outstanding commands")
    f:step()
    return f
end

test("Frequency: native stage-1 failure sends unchanged stage only, then solver recovers", function()
    local f = pending_session("frequency")
    local submitted = f.queue[1]
    eq(submitted.name, "rpc_minigame_sync_frequency_test_frequency")
    -- Simulate a stale submission by changing only the wire values; native server
    -- scoring determines the failure and generates the real unchanged-stage ACK.
    submitted.args[3], submitted.args[4] = 0, 0
    deliver_named(f, submitted.name)
    eq(f.server:current_stage(), 1)
    eq(f.server._mistakes, 1)
    eq(#f.queue, 1, "stage-1 failure has no target-frequency packet")
    deliver_named(f, "rpc_minigame_sync_set_stage")
    local recovered = false
    for _ = 1, 60 do
        local sample = f:step()
        eq(sample.action_two_pressed, false, "definitive failure ACK is not uncertainty")
        if sample.action_one_hold then recovered = true; break end
    end
    assert(recovered, "unchanged stage ACK must unblock stage-1 recovery")
    deliver_named(f, "rpc_minigame_sync_frequency_test_frequency")
    eq(f.server:current_stage(), 2)
    eq(f.server._mistakes, 1, "next exact submission scores successfully")
    eq(#f.native_scores, 2, "no duplicate failure or recovery score")
end)

test("Frequency: automated action preserves chained return arity and nils", function()
    local f = fixture({ frequency_solve_speed = 5 }, false, true)
    f:open("frequency", false)
    local action, saw_press = f.game.action, false
    f.game.action = function(self, ...)
        local values = table.pack(action(self, ...))
        eq(values.n, 4, "regular hook preserves chained return arity")
        eq(values[2], nil)
        eq(values[3], "chained action")
        eq(values[4], nil)
        if values[1] then saw_press = true end
        return table.unpack(values, 1, values.n)
    end
    for frame = 1, 60 do
        f:tick(frame)
        if saw_press then break end
    end
    assert(saw_press, "exercise automated rising-edge branch, not only passthrough")
    eq(#f.native_scores, 1)
end)

for _, kind in ipairs({ "frequency", "decode_symbols" }) do
  for _, ack in ipairs(kind == "frequency" and { "none", "stage", "target" } or { "none", "first" }) do
    test(kind .. ": oldest unacknowledged command cancels at 2.5s, ACK=" .. ack .. ", manual reopen only", function()
        local f = pending_session(kind)
        local count, oldest = #f.edges, f.edges[1].t
        if ack == "first" then
            f.server:on_action_pressed(f.edges[1].t)
            deliver_named(f, "rpc_minigame_sync_set_stage")
            oldest = f.edges[2].t
        elseif ack ~= "none" then
            deliver_named(f, "rpc_minigame_sync_frequency_test_frequency")
            deliver_named(f, ack == "stage" and "rpc_minigame_sync_set_stage"
                or "rpc_minigame_sync_frequency_set_target_frequency")
        end
        f.t = oldest + 1.21
        eq(f:step().action_two_pressed, false, "1.2s prediction timeout preserves pending commands")
        f.t = oldest + 2.47
        eq(f:step().action_two_pressed, false, "no cancellation before 2.5s")
        f.t = oldest + 2.51
        local sample = f:step()
        eq(sample.action_two_pressed, true, "oldest command reaches bounded native cancel")
        eq(f.cancel_return, true, "ordinary state input returns cancel")
        eq(#f.edges, count, "uncertainty must not generate another direct submission")
        if kind == "frequency" then
            eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency, 1, "no repeated direct payload while ACK is incomplete")
        end
        eq(f.game:is_completed(), false, "uncertainty is not completion")
        eq(f:step().action_two_pressed, false, "one cancel only")
        f.local_state:on_exit(f.player.player_unit, f.t, "walking")
        eq(f.ctx.active_minigame, nil)
        f.visible = false
        f.extensions[f.player.player_unit].interactor_system = { is_interacting = no,
            target_unit = function() return f.terminal end, can_interact = yes }
        f.extensions[f.terminal] = { decoder_device_system = { interaction_allowed = yes } }
        f:deliver(true)
        f.server:stop()
        f:deliver(true)
        for _ = 1, 30 do
            f.frame, f.t = f.frame + 1, f.t + 0.02
            f.mod.update(0.02)
            local idle = f:sample(f.frame)
            eq(idle.interact_pressed, false, "manual reopen only, even with a valid interaction target")
            eq(idle.action_two_pressed, false)
        end
        f.server:setup_game()
        f.client:start(f.player)
        f.server:start(f.remote)
        f:deliver(true)
        f.visible = true
        f.local_state = f:state(f.client, f.player)
        f:consume(f.local_state, f.frame)
        eq(f:step().action_one_hold, false, "manual reopen rearms with a release")
        local resumed = false
        for _ = 1, 220 do
            local next_sample = f:step()
            eq(next_sample.action_two_pressed, false, "fresh session clears cancellation")
            if next_sample.action_one_hold then resumed = true; break end
        end
        assert(resumed, "manual fresh reopen allows automation")
    end)
  end

    test(kind .. ": ACKs draining just before deadline suppress uncertainty cancel", function()
        local f = pending_session(kind)
        f.t = f.edges[1].t + 2.47
        if kind == "frequency" then
            deliver_named(f, "rpc_minigame_sync_frequency_test_frequency")
            deliver_named(f, "rpc_minigame_sync_set_stage")
            deliver_named(f, "rpc_minigame_sync_frequency_set_target_frequency")
        else
            for _, edge in ipairs(f.edges) do
                f.server:on_action_pressed(edge.t)
                deliver_named(f, "rpc_minigame_sync_set_stage")
            end
            eq(f.client:current_stage(), 3, "both stage commands drain through concrete setter")
        end
        for _ = 1, 10 do eq(f:step().action_two_pressed, false, "drained old commands cannot cancel") end
    end)

    for _, gate in ipairs({ "UI lock", "hidden", "ownership", "disabled", "manual" }) do
        test(kind .. ": uncertainty cancel respects " .. gate, function()
            local f = pending_session(kind)
            if gate == "UI lock" then f.locks.key_action_two_pressed = true
            elseif gate == "hidden" then f.visible = false
            elseif gate == "ownership" then f.client._player_session_id = "remote"
            elseif gate == "disabled" then f.enabled = false; f.mod.on_disabled()
            else f:set(kind == "frequency" and "enable_frequency_auto" or "enable_decode_auto", false) end
            f.t = f.edges[1].t + 2.51
            for _ = 1, 3 do eq(f:step().action_two_pressed, false, "gate blocks native cancel") end
            if gate == "UI lock" or gate == "hidden" then
                f.locks, f.visible = {}, true
                eq(f:step().action_two_pressed, true, "gate must not consume pending cancellation")
            end
        end)
    end
end

print(string.format("BetterBrainer offline integration: %d/%d passed", tests - failed, tests))
if failed > 0 then os.exit(1) end
