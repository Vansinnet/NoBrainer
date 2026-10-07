-- NoBrainer adaptation of BetterBrainer's tests/fixture.lua: the same historical fixture text
-- (tools/tests/better_brainer_spec.lua, never its legacy suite) loads NoBrainer.lua instead.
-- Search, Drill and Symbols run as BetterBrainer-shaped modules through NoBrainer_core.lua; the legacy
-- Frequency, Smart Seed Reroll and input route also load. Servo skull, Scan and Balance hook engine
-- classes this fixture does not load and are skipped.
local M = { source = "darktide-source/" }
do -- Patch for the spec banners; darktide-source/ is a git clone of the game source.
    local ok, pipe = pcall(io.popen, "git -C darktide-source log -1 --format=%s")
    local line = ok and pipe and pipe:read("*l")
    if ok and pipe then pipe:close() end
    FIXTURE_SOURCE_VERSION = line and line:match("Version ([%d%.]+)") or "unknown"
end
local ROOT = "mods/active/NoBrainer/scripts/mods/NoBrainer/"

function M.read(path)
    local file = assert(io.open(path, "rb"))
    local text = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return text
end

function M.replace(text, before, after)
    local first, last = text:find(before, 1, true)
    assert(first, "adapter block missing: " .. before)
    assert(not text:find(before, last + 1, true), "adapter block is not unique: " .. before)
    return text:sub(1, first - 1) .. after .. text:sub(last + 1)
end

function M.pack(...) return { n = select("#", ...), ... } end
function M.eq(actual, expected, why)
    assert(actual == expected, (why or "equality") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
function M.near(actual, expected, why)
    assert(math.abs(actual - expected) < 1e-8,
        (why or "scalar mismatch") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
function M.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = M.copy(item) end
    return result
end

local historical = M.read("tools/tests/better_brainer_spec.lua")
local boundary = assert(historical:find("\nlocal tests, failed = 0, 0", 1, true), "historical fixture boundary")
local fixture_text = historical:sub(1, boundary - 1)
assert(fixture_text:match("return f\nend\n$"), "historical fixture ending changed")
fixture_text = M.replace(fixture_text, "env.math.atan2 = math.atan", "env.math.atan2 = math.atan2")
fixture_text = M.replace(fixture_text, "{ rewind_ms = function() return f.rewind or 0 end }",
    "{ rewind_seconds = function() return f.rewind or 0 end }")
fixture_text = M.replace(fixture_text, 'local ROOT = "mods/active/BetterBrainer/scripts/mods/BetterBrainer/"',
    'local ROOT = "' .. ROOT .. '"')
fixture_text = M.replace(fixture_text, 'eq(name, "BetterBrainer", "mod name")', 'eq(name, "NoBrainer", "mod name")')
-- NoBrainer's legacy input route keeps its PlayerUnitInputExtension.get hook (Balance command history).
fixture_text = M.replace(fixture_text,
    'assert(target ~= f.Extension and target ~= f.Human, "local extension override is forbidden")',
    'assert(target ~= f.Human, "local extension override is forbidden")')
fixture_text = M.replace(fixture_text, 'loadfile(ROOT .. "BetterBrainer_data.lua", "t", env)',
    'loadfile(ROOT .. "NoBrainer_data.lua", "t", env)')
fixture_text = M.replace(fixture_text, 'assert(loadfile(ROOT .. "BetterBrainer.lua", "t", env))()',
    'assert(loadfile(ROOT .. "NoBrainer.lua", "t", env))()')
-- Settings already migrated to the 1-5 speed schema (NoBrainer.lua would otherwise remap test speeds).
fixture_text = M.replace(fixture_text, "    defaults(data.options.widgets)\n",
    "    defaults(data.options.widgets)\n    f.values._speed_schema_v2 = true\n")
fixture_text = M.replace(fixture_text, "    function mod:is_enabled() return f.enabled end\n", [[
    function mod:is_enabled() return f.enabled end
    function mod:set(id, value) f.values[id] = value end
    function mod:warning(...) error("unexpected mod:warning " .. string.format(...)) end
    function mod:echo(text) error("unexpected mod:echo " .. tostring(text)) end
]])
do
    local first = assert(fixture_text:find("    function mod:io_dofile(path)\n", 1, true))
    local last = assert(fixture_text:find("    local function wrap_solo()\n", first, true))
    fixture_text = fixture_text:sub(1, first - 1) .. [[
    local SKIP = { NoBrainer_minigame_servo_skull = true, NoBrainer_minigame_scan = true,
        NoBrainer_minigame_balance = true }
    local KEYS = { NoBrainer_minigame_decode_symbols = "symbols", NoBrainer_minigame_decode_search = "search",
        NoBrainer_minigame_drill = "drill" }
    function mod:io_dofile(path)
        assert(path:match("^NoBrainer/scripts/mods/NoBrainer/"), "invalid DMF path: " .. path)
        f.paths[path] = (f.paths[path] or 0) + 1
        local name = path:match("([^/]+)$")
        if SKIP[name] then return true end
        local value = assert(loadfile(ROOT .. name .. ".lua", "t", env))()
        if type(value) ~= "function" then return value end
        local key = KEYS[name] or name
        return function(ctx)
            f.ctx = ctx
            local module = value(ctx)
            f.modules[key] = module
            if module.observe then
                local original = module.observe
                module.observe = function(...)
                    f.observations[key] = (f.observations[key] or 0) + 1
                    f.observed_times[key] = select(2, ...)
                    return original(...)
                end
            end
            if module.input then
                local original = module.input
                module.input = function(action, value, t, source)
                    f.input_calls[key] = (f.input_calls[key] or 0) + 1
                    f.input_times[key] = t
                    return original(action, value, t, source)
                end
            end
            return module
        end
    end
]] .. fixture_text:sub(last)
end

-- Snapshot once per process: every fixture sees identical runtime module text.
local runtime = {}
for _, name in ipairs({ "NoBrainer", "NoBrainer_data", "NoBrainer_core", "NoBrainer_input",
    "NoBrainer_minigame_decode_symbols", "NoBrainer_minigame_decode_search", "NoBrainer_minigame_drill",
    "NoBrainer_minigame_frequency", "NoBrainer_decode_symbols_reroll" }) do
    runtime[ROOT .. name .. ".lua"] = M.read(ROOT .. name .. ".lua")
end

function M.factory()
    local compat_table = M.copy(table)
    compat_table.pack, compat_table.unpack = M.pack, unpack
    local outer = setmetatable({ table = compat_table }, { __index = _G })
    outer.loadfile = function(path, mode, env)
        if path:sub(1, 16) == "darktide-source/" then path = M.source .. path:sub(17) end
        local text = runtime[path] or M.read(path)
        local chunk, err = loadstring(text, "@" .. path)
        if chunk then setfenv(chunk, env or outer) end
        return chunk, err
    end
    local chunk = assert(loadstring(fixture_text .. "\nreturn fixture\n", "@tools/tests/better_brainer_spec.lua"))
    setfenv(chunk, outer)
    local make = chunk()
    return function(...)
        local f = make(...)
        -- DMF debug logging is off by default; tests may replace this to capture lines.
        f.mod.debug = f.mod.debug or function() end
        -- Server state of the local unit (player_unit_data_extension.lua:984-991): for each server frame, whether
        -- that frame ran on its own, timely input. The fixture's server runs client frame n at tick n + 3; a stall
        -- that substitutes an older frame makes that frame untimely. The state is queued behind the frame's RPCs
        -- with the normal receipt delay and read through the real hook on `_read_server_unit_data_state`.
        local STATE = "scripts/extension_systems/unit_data/player_unit_data_extension"
        local Extension = { _read_server_unit_data_state = function() end }
        Extension.__index = Extension
        local session = {}
        f.env.GameSession = f.env.GameSession or {}
        f.env.GameSession.game_object_field = function(game_session, _, field) return game_session[field] end
        f.unit_state = setmetatable({ _player = f.player, _game_session = session, _server_data_state_game_object_id = 1 },
            Extension)
        local function hook_state()
            local callback = f.deferred[STATE]
            if callback then callback(Extension) end
        end
        hook_state()
        local reload, tick, consume, dispatch = f.reload, f.tick, f.consume, f.dispatch
        function f:reload(...)
            local results = M.pack(reload(self, ...))
            hook_state()
            return unpack(results, 1, results.n)
        end
        -- Deliver one server state now (tests that drive single frames).
        function f:report_frame(frame, had)
            session.frame_index, session.had_received_input = frame, had
            return self.unit_state:_read_server_unit_data_state(self.t)
        end
        function f:tick(frame, ...)
            self.server_frame = frame > 3 and frame - 3 or nil
            return tick(self, frame, ...)
        end
        function f:consume(state, frame, t)
            local results = M.pack(consume(self, state, frame, t))
            local server_frame = self.server_frame
            if state == self.server_state and self.client and server_frame and not self.drop_server_state then
                self.server_frame = nil
                self.queue[#self.queue + 1] = { at = (self.transport_t or self.t) + self.delay, to = "client",
                    name = "server_unit_data_state", args = M.pack(server_frame, frame == server_frame) }
            end
            return unpack(results, 1, results.n)
        end
        function f:dispatch(to, name, args)
            if name == "server_unit_data_state" then return self:report_frame(args[1], args[2]) end
            return dispatch(self, to, name, args)
        end
        return f
    end
end

function M.deliver(f, name)
    for i, item in ipairs(f.queue) do
        if item.name == name then
            table.remove(f.queue, i)
            f:dispatch(item.to, item.name, item.args)
            return item
        end
    end
    error("missing queued " .. name)
end

function M.rpc(f, suffix, ...)
    f:dispatch("client", "rpc_minigame_sync_" .. suffix, M.pack(1, true, ...))
end

function M.scan_fixture(factory)
    local f = factory({ enable_scan = false, enable_auto_scan = true })
    local env = f.env
    local function noop() end
    local base = env.class("ActionWeaponBase")
    base.start, base.finish = noop, noop
    local original_require, cache = env.require, {}
    local ACTION = "scripts/extension_systems/weapon/actions/"
    local EXT = "scripts/extension_systems/mission_objective_zone_scannable/mission_objective_zone_scannable_extension"
    local allowed = { [ACTION .. "action_scan"] = true, [ACTION .. "action_scan_confirm"] = true,
        ["scripts/utilities/scanning"] = true, [EXT] = true }
    env.require = function(path)
        if path == ACTION .. "action_weapon_base" then return base end
        if path == "scripts/utilities/alternate_fire" or path == "scripts/utilities/weapon/weapon_template" then return {} end
        if not allowed[path] then return original_require(path) end
        if not cache[path] then
            local chunk = assert(loadstring(M.read(M.source .. path .. ".lua"), "@" .. M.source .. path .. ".lua"))
            setfenv(chunk, env)
            cache[path] = chunk()
            if f.deferred[path] then f.deferred[path](cache[path]) end
        end
        return cache[path]
    end
    local template = M.read(M.source .. "scripts/settings/equipment/weapon_templates/devices/scanner_equip.lua")
    local settings_text = assert(template:match("local scan_settings = (%b{})\n\nweapon_template.actions"))
    local scan_settings = assert(loadstring("return " .. settings_text))()
    M.eq(scan_settings.confirm_time, 1, "historical scanner stub matches pinned source")
    env.ALIVE = setmetatable({}, { __index = function(_, unit) return env.Unit.alive(unit) end })
    env.Quaternion = { forward = function() return env.Vector3(0, 1, 0) end }
    env.Actor = { unit = function(actor) return actor end }
    env.PhysicsWorld = { raycast = function(_, _, _, distance, mode, _, filter)
        M.eq(distance, scan_settings.distance.near)
        if mode == "closest" then M.eq(filter, "filter_interactable_line_of_sight_check"); return nil end
        M.eq(mode, "all"); M.eq(filter, "filter_interactable_overlap")
        return f.aim and { { [2] = 1, [4] = f.aim } } or nil
    end }
    local zone = { scannable_units = function() return {} end, any_active_scanning_zone = function() return true end }
    env.Managers.state.extension = { system = function(_, name)
        M.eq(name, "mission_objective_zone_system"); return zone
    end, has_system = function() return false end }
    local extension_class = env.require(EXT)
    f.a, f.b = {}, {}
    for _, unit in ipairs({ f.a, f.b }) do
        f.extensions[unit] = { mission_objective_zone_scannable_system = setmetatable({
            _unit = unit, _is_active = true, _is_server = false,
        }, extension_class) }
    end
    f.components = { weapon_action = {}, scanning = { is_active = false, line_of_sight = false } }
    f.extensions[f.player.player_unit] = { unit_data_system = { read_component = function(_, name)
        return f.components[name]
    end } }
    local function action(class)
        return setmetatable({ _scanning_compomnent = f.components.scanning, _player = f.player, _is_server = false,
            _action_settings = { scan_settings = scan_settings }, _weapon_template = {},
            _weapon_tweak_templates_component = {}, _alternate_fire_component = { is_active = true },
            _first_person_component = { position = env.Vector3.zero(), rotation = {} },
            _fx_extension = { trigger_gear_wwise_event_with_source = noop },
        }, class)
    end
    f.scan_action = action(env.require(ACTION .. "action_scan"))
    f.confirm_action = action(env.require(ACTION .. "action_scan_confirm"))
    function f:resume(target)
        self.aim = target
        self.components.weapon_action.current_action_name = "action_scan"
        self.scan_action:start(self.scan_action._action_settings, self.t)
        self.scan_action:fixed_update(0.02, self.t, 0)
        M.eq(self.components.scanning.scannable_unit, target, "native acquisition")
    end
    function f:confirm()
        self.components.weapon_action.current_action_name = "action_scan_confirm"
        self.confirm_action:start(self.confirm_action._action_settings, self.t)
        self.confirm_action:fixed_update(0.02, self.t, 0)
        self.mod.update(0.02)
    end
    function f:abort()
        self.confirm_action:finish("action_complete", nil, self.t, 0.1)
        M.eq(self.components.scanning.is_active, false, "native finish clears component")
        M.eq(self.components.scanning.scannable_unit, nil)
    end
    return f
end

return M
