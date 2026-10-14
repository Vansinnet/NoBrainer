local mod = get_mod("NoBrainer")
local path = "NoBrainer/scripts/mods/NoBrainer/"
local settings, definitions, pacing = {}, {}, {}
local ctx = { mod = mod, settings = settings }
local local_state, active, observed_at
local sampling_service, sampling_time, sampling_ephemeral
local fast_exit_sent
-- A solver may close and reopen its terminal (DESIGN.md, Reopen controller).
local REOPEN_GAP, REOPEN_TIMEOUT = 0.15, 1
local reopen, reopen_off, session_t, resumed_t
local entering_frame, entering -- input frame last checked, and whether it enters a minigame

function ctx.time()
    local time = Managers.time
    return time and time:has_timer("gameplay") and time:time("gameplay") or nil
end

function ctx.is_local_player(player)
    local players = Managers.player
    return player ~= nil and players ~= nil and player == players:local_player_safe(1)
end

function ctx.pacing(id)
    return pacing[id]
end

-- While input frames arrive late, the server keeps running an older input frame (authoritative_player_input_
-- handler.lua:124-136,153-157: after a miss it can keep the last frame received before the miss even while it
-- receives and acknowledges later, already-late frames). A direction run that way moves Search or Drill again
-- after the 0.25 s repeat delay, past a position the client already saw confirmed, and a late press can run
-- after it. The server's state for this player reports, per simulated frame, whether that frame's own input
-- had arrived (`had_received_input`, player_unit_data_extension.lua:984-991). Once the server ran its own,
-- timely input for a frame after `frame`, it can never again run input from `frame` or earlier, and every
-- minigame RPC from the frames before it was sent before that state. Local authority has no late input.
-- Returns nil only while no server state at all has been read on this handler (an unexpected engine change).
function ctx.server_ran_after(mg, frame)
    if mg._is_server or not frame then return true end
    if not ctx.state_seen then return nil end
    local timely = ctx.timely_frame
    return timely ~= nil and timely > frame
end

-- No submission while the server could still run a direction frame. Without any server state on this handler
-- (an unexpected engine change), wait one second after the last direction instead.
function ctx.movement_settled(mg, t)
    local frame = ctx.moved_frame
    if not frame or mg._is_server then return true end
    if ctx.state_seen then return ctx.timely_frame ~= nil and ctx.timely_frame > frame end
    return t ~= nil and ctx.moved_t ~= nil and t >= ctx.moved_t + 1
end

local MOVEMENT = { move = true, move_left = true, move_right = true, move_forward = true, move_backward = true }

-- Record the newest fixed input frame that serialized any direction (ours or the player's).
local function track_movement(action, value)
    if MOVEMENT[action] and not sampling_ephemeral and value then
        local moving
        if type(value) == "number" then moving = value ~= 0 else moving = value.x ~= 0 or value.y ~= 0 end
        if moving then ctx.moved_frame, ctx.moved_t = ctx.input_frame, sampling_time end
    end
    return value
end

function ctx.pulse(state, ready)
    local frame = ctx.input_frame
    if not frame then return false end
    if state.frame ~= frame then
        -- Every primary alias shares one edge; the next sampled frame must release.
        local first = state.frame == nil or frame < state.frame
        state.frame, state.held = frame, not first and not state.held and ready or false
    end
    return state.held
end

local function read_setting(id, definition)
    local value = mod:get(id)
    local default = definition.default_value
    if type(value) ~= type(default) then value = default end
    if definition.range then
        if value ~= value or value == math.huge or value == -math.huge then value = default end
        value = math.max(definition.range[1], math.min(definition.range[2], math.floor(value + 0.5)))
    end
    settings[id] = value
    if id == "expedition_solve_speed" or id == "drill_solve_speed" or id == "frequency_solve_speed" then
        pacing[id] = (5 - value) / 4
    end
end

local function read_definitions(widgets)
    for i = 1, #widgets do
        local widget = widgets[i]
        if widget.sub_widgets then
            read_definitions(widget.sub_widgets)
        elseif widget.default_value ~= nil then
            definitions[widget.setting_id] = widget
            read_setting(widget.setting_id, widget)
        end
    end
end

-- Settings saved by NoBrainer 3.1 and earlier used a 1-10 speed scale or "human"/"inhuman" strings; migrate once.
-- read_setting below clamps every later value to its range.
if mod:get("_speed_schema_v2") ~= true then
    for id, old_default in pairs({ expedition_solve_speed = 5, drill_solve_speed = 5, frequency_solve_speed = 2 }) do
        local raw, speed = mod:get(id), 1
        local legacy = type(raw) == "string" and string.lower(raw):match("^%s*(.-)%s*$")
        local old = tonumber(raw)
        if legacy == "inhuman" then
            speed = 5
        elseif old and old == old and old ~= math.huge and old ~= -math.huge then
            old = math.max(1, math.min(10, math.floor(old + 0.5)))
            if old > old_default then
                speed = math.min(5, 1 + math.floor((old - old_default) * 4 / (10 - old_default) + 0.5))
            end
        end
        mod:set(id, speed, false)
    end
    mod:set("_speed_schema_v2", true, false)
end

read_definitions(mod:io_dofile(path .. "NoBrainer_data").options.widgets)

local symbols = mod:io_dofile(path .. "symbols")(ctx)
local search = mod:io_dofile(path .. "search")(ctx)
local drill = mod:io_dofile(path .. "drill")(ctx)
local frequency = mod:io_dofile(path .. "frequency")(ctx)
local balance = mod:io_dofile(path .. "balance")(ctx)
local scan = mod:io_dofile(path .. "scan")(ctx)
local servo_skull = mod:io_dofile(path .. "servo_skull")(ctx)
local modules = { symbols, search, drill, frequency, balance, scan, servo_skull }
local solvers = {
    decode_symbols = symbols,
    decode_search = search,
    drill = drill,
    frequency = frequency,
    balance = balance,
}

local function end_session(reason)
    -- An unsolved session that ends right after a resume was most likely rolled back: the server refused the entry.
    local t, mg = ctx.time(), ctx.active_minigame
    if resumed_t and t and t - resumed_t < REOPEN_TIMEOUT and not (mg and mg:is_completed()) then
        reopen_off = true
        mod:debug("Reopen: session ended %.3fs after the resume, reopening switched off", t - resumed_t)
    end
    resumed_t = nil
    ctx.active_minigame = nil
    fast_exit_sent = nil
    local_state, observed_at = nil, nil
    if active then active.reset(reason) end
    active = nil
end

local function abort_reopen(reason)
    local pending = reopen
    reopen, reopen_off = nil, true
    mod:debug("Reopen: %s in phase %s, reopening switched off until the next mission", reason, pending.phase)
    if active == pending.module then
        -- Still in the old session: the solver carries on there.
        if pending.module.reopen_failed then pending.module.reopen_failed() end
    else
        pending.module.reset("session_end")
    end
end

local function reset(reason)
    ctx.active_minigame = nil
    fast_exit_sent = nil
    ctx.input_frame = nil
    ctx.input_handler, ctx.state_seen, ctx.timely_frame, ctx.moved_frame, ctx.moved_t = nil, nil, nil, nil, nil
    sampling_service, sampling_time, sampling_ephemeral = nil, nil, nil
    local_state, active, observed_at = nil, nil, nil
    reopen, reopen_off, session_t, resumed_t = nil, nil, nil, nil
    ctx.session_frame, ctx.session_frame_timely, ctx.consuming, entering_frame = nil, nil, nil, nil
    for i = 1, #modules do modules[i].reset(reason) end
end

local function select_session(state, frame)
    local mg = state._minigame
    local extension = mg and mg._minigame_extension
    local solver = extension and solvers[extension:minigame_type()]
    if not solver then
        if active then end_session("session_end") end
        return
    end
    if ctx.active_minigame ~= mg then
        if active then end_session("session_changed") end
        local t = ctx.time()
        -- The server initializes the minigame in this same frame; its state reports whether it ran the frame's input.
        ctx.session_frame, ctx.session_frame_timely = frame, nil
        if reopen and reopen.mg == mg and reopen.module == solver then
            -- The entry we asked for: resume the suspended solver instead of starting fresh.
            mod:debug("Reopen: resumed %.3fs after the request", t and t - reopen.t or -1)
            reopen = nil
            ctx.active_minigame, active, observed_at, local_state = mg, solver, nil, state
            session_t, resumed_t, fast_exit_sent = t, t, nil
            solver.resume(mg, t)
            return
        end
        if reopen then abort_reopen("another session started") end
        ctx.active_minigame, active, observed_at = mg, solver, nil
        session_t, fast_exit_sent = t, nil
    end
    local_state = state
end

-- The terminal can be reopened when it is a decoder (`decoding`, duration 0, interaction_templates.lua:36-43) and the
-- interactor already sees it. During the minigame it is only a focus target: interaction_allowed() is false while the
-- minigame is active (decoder_device_extension.lua:292-305, interactor_extension.lua:448-488,567-588).
function ctx.reopen_ready(mg)
    if reopen or reopen_off or not mg or mg ~= ctx.active_minigame or not local_state then return false end
    local terminal, unit = mg._minigame_unit, local_state._unit
    if not terminal or not Unit.alive(terminal) or not unit or not Unit.alive(unit) then return false end
    local interactee = ScriptUnit.has_extension(terminal, "interactee_system")
    if not interactee or interactee:interaction_type() ~= "decoding"
        or not ScriptUnit.has_extension(terminal, "decoder_device_system") then return false end
    local interactor = ScriptUnit.has_extension(unit, "interactor_system")
    if not interactor or not interactor._find_interaction_object or interactor:is_interacting() then return false end
    local chosen, _, focus = interactor:_find_interaction_object(unit)
    return chosen == terminal or focus == terminal
end

-- Cancel, then interact again once allowed. The server runs both frames in order and its setup_game precedes the
-- new entry frame's input (player_character_state_minigame.lua:138-148), so nothing waits for a receipt.
function ctx.request_reopen(mg)
    local t = ctx.time()
    if not t or not ctx.reopen_ready(mg) then return false end
    reopen = { mg = mg, terminal = mg._minigame_unit, module = active, phase = "cancel", t = t,
        allow_t = (session_t or t) + REOPEN_GAP }
    mod:debug("Reopen: requested at %.3f", t)
    return true
end

local function can_reinteract(pending, t)
    if t < pending.allow_t or not Unit.alive(pending.terminal) then return false end
    local players = Managers.player
    local player = players and players:local_player_safe(1)
    local unit = player and player.player_unit
    if not unit or not Unit.alive(unit) then return false end
    local csm = ScriptUnit.has_extension(unit, "character_state_machine_system")
    local state = csm and csm:current_state_name()
    if state ~= "walking" and state ~= "sprinting" then return false end
    local interactor = ScriptUnit.has_extension(unit, "interactor_system")
    if not interactor or interactor:is_interacting() then return false end
    -- The interactor picks its target in the same fixed frame that reads the press (interactor_extension.lua:160-244).
    return interactor:_find_interaction_object(unit) == pending.terminal
        and interactor:can_interact(pending.terminal, "decoding")
end

local NEUTRAL_MOVE = { move = true, move_left = true, move_right = true, move_forward = true, move_backward = true }

-- Ephemeral cancel and interact for a pending reopen; every other routed action stays neutral meanwhile.
local function reopen_input(action, original, t)
    local pending = reopen
    if pending.phase == "cancel" then
        -- The solver still owns the session until the cancel is sampled.
        if action ~= "action_two_pressed" or not sampling_ephemeral then return nil end
        pending.phase = "cancel_sent"
        return true
    end
    if action == "interact_pressed" then
        if not sampling_ephemeral then return original end
        if pending.phase == "interact_sent" and t >= pending.interact_t + 0.1 then pending.phase = "exited" end
        if pending.phase == "exited" and can_reinteract(pending, t) then
            pending.phase, pending.interact_t = "interact_sent", t
            mod:debug("Reopen: interact at %.3f", t)
            return true
        end
        return false
    end
    if action == "move" then return Vector3(0, 0, 0) end
    if NEUTRAL_MOVE[action] then return 0 end
    return false
end

-- Passing a minigame also requires current CSM identity on the normal explicit-owner path.
function ctx.session_valid(minigame)
    if not local_state then return false end
    local player = local_state._player
    local mg = ctx.active_minigame
    if not (ctx.is_local_player(player) and player.player_unit ~= nil and Unit.alive(player.player_unit)
        and local_state._minigame == mg and mg ~= nil
        and (minigame == nil or minigame == mg)) then return false end
    local owner = mg:player_session_id()
    if owner ~= nil then
        if owner ~= player:session_id() then return false end
        if minigame == nil then return true end
    elseif mg._is_server ~= false then
        return false
    end
    if local_state._unit ~= player.player_unit then return false end
    -- Nil-owner receipts and direct submissions require the actual current state, not retained prediction.
    local csm = ScriptUnit.has_extension(player.player_unit, "character_state_machine_system")
    return csm ~= nil and csm:current_state() == local_state
end

local function observe(t)
    if active and observed_at ~= t then
        observed_at = t
        active.observe(ctx.active_minigame, t)
    end
end

local function finish_consume(...)
    ctx.consuming = nil
    return ...
end

mod:hook_require("scripts/extension_systems/character_state_machine/character_states/player_character_state_minigame", function(State)
    mod:hook(State, "_update_input", function(func, self, t, fixed_frame, input_extension)
        local own = ctx.is_local_player(self._player)
        if own then
            select_session(self, fixed_frame)
            if ctx.session_valid() then observe(t) end
        end
        -- Solvers can tell the local player's consumed input from other callers of the minigame (Frequency's camera).
        ctx.consuming = own and self or nil
        -- Keep native input edges, dodging, animation, and weapon action ordering.
        return finish_consume(func(self, t, fixed_frame, input_extension))
    end)
    mod:hook_safe(State, "on_exit", function(self, unit, t, next_state)
        if self ~= local_state then return end
        if reopen and reopen.module == active and reopen.mg == ctx.active_minigame then
            -- Our own exit: keep the solver's state for the new session of the same minigame.
            reopen.phase = "exited"
            ctx.active_minigame, local_state, observed_at, fast_exit_sent, active = nil, nil, nil, nil, nil
            return
        end
        end_session("session_end")
    end)
end)

local function finish_sample(...)
    sampling_service, sampling_time, sampling_ephemeral = nil, nil, nil
    return ...
end

mod:hook_require("scripts/managers/player/player_game_states/human_input_handler", function(Handler)
    mod:hook(Handler, "pre_update", function(func, self, dt, t, input_service, ui_interaction_action)
        if not ctx.is_local_player(self._player) then
            return func(self, dt, t, input_service, ui_interaction_action)
        end
        -- Ephemeral buttons are collected in main time; solver clocks use gameplay time.
        sampling_service, sampling_time, sampling_ephemeral = input_service, ctx.time(), true
        return finish_sample(func(self, dt, t, input_service, ui_interaction_action))
    end)
    mod:hook(Handler, "fixed_update", function(func, self, dt, t, frame, input_service, yaw, pitch, roll)
        if not ctx.is_local_player(self._player) then
            return func(self, dt, t, frame, input_service, yaw, pitch, roll)
        end
        if ctx.input_handler ~= self then
            -- Frame numbers and the server's input bookkeeping belong to one handler (one game session).
            ctx.input_handler, ctx.state_seen, ctx.timely_frame, ctx.moved_frame, ctx.moved_t = self, nil, nil, nil, nil
        end
        ctx.input_frame = frame
        sampling_service, sampling_time, sampling_ephemeral = input_service, t, false
        return finish_sample(func(self, dt, t, frame, input_service, yaw, pitch, roll))
    end)
end)

local function read_state(session, id)
    return GameSession.game_object_field(session, id, "frame_index"),
        GameSession.game_object_field(session, id, "had_received_input")
end

mod:hook_require("scripts/extension_systems/unit_data/player_unit_data_extension", function(Extension)
    -- Client pre_update reads the newest server state of the local player's unit (one per server tick).
    mod:hook_safe(Extension, "_read_server_unit_data_state", function(self, t)
        local session, id = self._game_session, self._server_data_state_game_object_id
        if not session or not id or not ctx.input_handler or not ctx.is_local_player(self._player) then return end
        -- `had_received_input` comes from the player's input handler, which outlives a respawned unit.
        local ok, frame, had = pcall(read_state, session, id)
        if not ok or type(frame) ~= "number" or type(had) ~= "boolean" then return end
        ctx.state_seen = true
        if had and frame > (ctx.timely_frame or -math.huge) then ctx.timely_frame = frame end
        if frame == ctx.session_frame then ctx.session_frame_timely = had end
    end)
end)

-- The first minigame frame is sampled before the state machine initializes the minigame
-- (player_character_state_minigame.lua:138-148), so no solver owns it yet. A direction there would still reach the
-- new minigame (a Search step, a Drill selection, a Frequency change), and a late frame replays the one before it.
local function entering_minigame()
    local frame = ctx.input_frame
    if entering_frame == frame then return entering end
    entering_frame, entering = frame, false
    local players = Managers.player
    local player = players and players:local_player_safe(1)
    local unit = player and player.player_unit
    local csm = unit and Unit.alive(unit) and ScriptUnit.has_extension(unit, "character_state_machine_system")
    if csm and csm:current_state_name() == "minigame" then
        local state = csm:current_state()
        entering = state ~= nil and state:minigame() == nil
    end
    return entering
end

local relevant = {
    action_one_hold = true, interact_hold = true, jump_held = true,
    action_one_pressed = true, action_one_released = true,
    action_two_pressed = true, interact_pressed = true,
    move = true, move_left = true, move_right = true, move_forward = true, move_backward = true,
}
local scan_actions = { action_one_pressed = true, action_one_hold = true, action_one_released = true }

local function solve_input(action, original)
    if reopen and sampling_time then
        local value = reopen_input(action, original, sampling_time)
        if value ~= nil then return value end
    end
    if action == "interact_pressed" then return original end
    if not active and MOVEMENT[action] and not sampling_ephemeral and entering_minigame() then
        return action == "move" and Vector3(0, 0, 0) or 0
    end
    local scanning = settings.enable_auto_scan and scan_actions[action]
    if not active and not scanning then return original end
    local t = sampling_time
    if not t then return original end
    if active then
        if not ctx.session_valid() then
            end_session("ownership_changed")
        else
            local ui = Managers.ui
            if ui and ui:view_active("scanner_display_view") then
                if sampling_ephemeral then
                    if action == "action_two_pressed" and not fast_exit_sent
                        and (((active == search and settings.enable_expedition_auto_solve
                            or active == drill and settings.enable_drill_auto)
                            and ctx.active_minigame:is_completed())
                            or active.cancel_requested and active.cancel_requested()) then
                        -- Skip a confirmed outro, or leave an uncertain response without retrying it.
                        fast_exit_sent = true
                        return true
                    end
                    return original
                end
                observe(t)
                return active.input(action, original, t, "input_service")
            end
            return original
        end
    end
    if scanning then return scan.input(action, original, t, "input_service") end
    return original
end

mod:hook(CLASS.InputService, "_get", function(func, self, action)
    local original = func(self, action)
    if self ~= sampling_service or self.type ~= "Ingame" or not relevant[action] then return original end
    -- Every serialized direction counts, ours or the player's, in or out of a minigame session.
    return track_movement(action, solve_input(action, original))
end)

mod.update = function(dt)
    if not mod:is_enabled() then return end
    if local_state and not ctx.session_valid() then end_session("ownership_changed") end
    local t = ctx.time()
    if reopen and t and t > reopen.t + REOPEN_TIMEOUT then abort_reopen("no new session in time") end
    if not t then return end
    servo_skull.update(dt, t)
    if settings.enable_scan or settings.enable_auto_scan then scan.update(dt, t) end
end

mod.on_setting_changed = function(id)
    local definition = definitions[id]
    if not definition then return end
    read_setting(id, definition)
    observed_at = nil
    for i = 1, #modules do
        local callback = modules[i].settings_changed
        if callback then callback(id) end
    end
end

mod.on_enabled = function()
    for id, definition in pairs(definitions) do read_setting(id, definition) end
    reset("enabled")
end

mod.on_disabled = function()
    reset("disabled")
end

mod.on_game_state_changed = function(status, name)
    if status == "exit" and name == "StateGameplay" then reset("gameplay_exit") end
end

mod.on_unload = function(exit_game)
    reset("unload")
end
