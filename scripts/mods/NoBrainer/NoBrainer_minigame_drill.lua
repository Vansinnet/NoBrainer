local Settings = require("scripts/settings/minigame/minigame_settings")
local UIWidget = require("scripts/managers/ui/ui_widget")
local MOVE = { move = true, move_left = true, move_right = true, move_forward = true, move_backward = true }
local PRIMARY = { action_one_hold = true, interact_hold = true, jump_held = true }
local CONE, POWER = math.pi / 3, Settings.drill_move_distance_power -- minigame_drill.lua:296-298
local STEP, MARGIN = math.rad(0.25), math.rad(0.5)
local HOLD = 2.5 -- the result tolerance cancel_requested gives any move
local ACK = Settings.drill_move_delay * 0.5 -- earlier registrations are at least one repeat delay older
local angles, points = {}, {}

local function movement(action, x, y)
    if action == "move_left" then return math.max(-x, 0) end
    if action == "move_right" then return math.max(x, 0) end
    if action == "move_forward" then return math.max(y, 0) end
    if action == "move_backward" then return math.max(-y, 0) end
    return Vector3(x, y, 0)
end

return function(ctx)
    local module = {}
    local game, stage, observed, cursor_x, cursor_y, target_x, target_y, target_index
    local pending_since, pending_frame, settled_at, move_t, move_x, move_y
    local recovery_requested = false
    local move_release, sent_frame
    local pulse = {}
    local ready_at, submitted_until = 0, 0
    local cache_game, cache_stage, cache_index, cache_target
    local openings = setmetatable({}, { __mode = "k" })
    local network, float_input, predicted = Network, nil, nil
    local press_t, burst_from, burst_until, burst_x, burst_y, burst_index, last_selected
    local burst_give_up, burst_press
    -- Planned aim stays enabled only while every predicted native selection is confirmed.
    local model = network ~= nil and network.pack_unpack ~= nil and network.type_index ~= nil
    local trusted = model
    local holding = true -- cleared after a held move the server ignored
    local ack_wait -- when a submission was otherwise ready but waited for the server to run later input
    local press_frame -- input frame of this stage's last submission

    local function opening(mg)
        local receipt = openings[mg]
        if not receipt then
            receipt = {}
            openings[mg] = receipt
        end
        return receipt
    end

    local function fresh(mg)
        local receipt = openings[mg]
        return mg._is_server == true or receipt and receipt.started and receipt.stage and receipt.cursor and receipt.search
    end

    local function target(mg)
        local s = mg:current_stage()
        local index = s and mg:correct_targets()[s]
        local targets = s and mg:targets()[s]
        local position = index and targets and targets[index]
        if cache_game ~= mg or cache_stage ~= s or cache_index ~= index or cache_target ~= position then
            cache_game, cache_stage, cache_index, cache_target = mg, s, index, position
        end
        return s, cache_index, cache_target
    end

    local function pack(value)
        float_input = float_input or network.type_index("float_input")
        return network.pack_unpack(float_input, value)
    end

    -- The joystick as the server reads it: four packed scalars (human_input_handler.lua:282).
    local function vector(theta)
        local x, y = math.cos(theta), -math.sin(theta)
        local scale = math.max(math.abs(x), math.abs(y))
        x, y = x / scale, y / scale
        return pack(math.max(x, 0)) - pack(math.max(-x, 0)), pack(math.max(y, 0)) - pack(math.max(-y, 0))
    end

    -- Native selection (minigame_drill.lua:280-303) plus the winner's angular safety margin.
    local function choose(targets, cx, cy, selected, x, y)
        local aim, best, lowest = math.atan2(-y, x), nil, math.huge
        for i = 1, #targets do
            if i ~= selected then
                local target = targets[i]
                local angle = math.abs(math.atan2(target.y - cy, target.x - cx) - aim)
                if angle > math.pi then angle = 2 * math.pi - angle end
                angles[i] = angle
                points[i] = math.sqrt((cx - target.x) * (cx - target.x) + (cy - target.y) * (cy - target.y)) + angle * POWER
                if points[i] < lowest and angle < CONE then best, lowest = i, points[i] end
            end
        end
        local margin = math.huge
        if not best then
            -- No node qualifies: the margin is the nearest node's distance outside the cone.
            for i = 1, #targets do
                if i ~= selected then margin = math.min(margin, angles[i] - CONE) end
            end
            return nil, margin
        end
        margin = CONE - angles[best]
        for i = 1, #targets do
            if i ~= selected and i ~= best then
                margin = math.min(margin, math.max(angles[i] - CONE, (points[i] - lowest) / (2 * POWER)))
            end
        end
        return best, margin
    end

    -- Direct aim when the server selects it with margin, else the nearest offset that does.
    -- A held move must also select nothing from the goal, so a repeat or replayed input is inert.
    local function aim(mg, s, selected, goal, hold)
        local targets = mg:targets()[s]
        local from = selected and targets[selected]
        local cx, cy = from and from.x or 0, from and from.y or 0
        local gx, gy = targets[goal].x, targets[goal].y
        local base = math.atan2(gy - cy, gx - cx)
        for i = 0, 478 do -- offsets 0, -1, +1, -2, +2 ... +239 steps (just under the cone)
            local x, y = vector(base + (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * STEP)
            local winner, margin = choose(targets, cx, cy, selected, x, y)
            if winner == goal and margin >= MARGIN then
                if not hold then return x, y, goal end
                local after, inert = choose(targets, gx, gy, goal, x, y)
                if not after and inert >= MARGIN then return x, y, goal end
            end
        end
        if hold then return nil end
        local x, y = vector(base)
        local winner, margin = choose(targets, cx, cy, selected, x, y)
        return x, y, margin >= MARGIN and winner or nil
    end

    function module.reset(reason)
        if reason ~= "identity" then
            if reason == "session_end" or reason == "session_changed" or reason == "ownership_changed" or reason == "inactive" then
                if game then openings[game] = nil end
            else
                table.clear(openings)
            end
        end
        game, stage, observed, cursor_x, cursor_y = nil, nil, nil, nil, nil
        target_x, target_y, target_index, predicted = nil, nil, nil, nil
        press_t, burst_from, last_selected = nil, nil, nil
        pending_since, pending_frame, settled_at, move_t, move_x, move_y = nil, nil, nil, nil, nil, nil
        recovery_requested = false
        ready_at, submitted_until = 0, 0
        move_release, sent_frame = true, nil
        table.clear(pulse)
        cache_game, cache_stage, cache_index, cache_target = nil, nil, nil, nil
        ack_wait, press_frame = nil, nil
        -- A new mission re-arms prediction and holding after a one-off anomaly.
        if reason == "gameplay_exit" then trusted, holding = model, true end
    end

    function module.observe(mg, t)
        t = t or ctx.time()
        if not t or not mg or mg ~= ctx.active_minigame or not mg.correct_targets
            or not ctx.settings.enable_drill_auto or mg:is_completed() then
            if game then module.reset("inactive") end
            return
        end
        if game ~= mg then
            module.reset("identity")
            game, ready_at = mg, t + ctx.pacing("drill_solve_speed") * 0.35
            last_selected = mg:selected_index() -- a retained selection is not a surprise
        end
        if observed == t then return end
        observed = t
        local s, index, position = target(mg)
        if stage ~= s then
            if stage then ready_at = t + ctx.pacing("drill_solve_speed") * 1.50 end
            burst_from = nil
            -- Our press advanced the stage: hold the next first move across the native transition end.
            if trusted and holding and stage and s == stage + 1 and index and press_t and not mg:selected_index()
                and ctx.pacing("drill_solve_speed") == 0 then
                burst_x, burst_y, burst_index = aim(mg, s, nil, index, true)
                if burst_x then
                    local resume = press_t + Settings.drill_transition_time
                    -- A receipt after the expected resume: the server is most likely in gameplay already, so hold
                    -- only briefly (the later the receipt, the shorter) instead of until the result arrives. Few
                    -- held frames keep a replay of late input from registering the hold twice.
                    burst_from, burst_press = math.max(resume, t), press_t
                    burst_give_up = burst_from + HOLD
                    burst_until = t > resume and burst_from + math.max(0.04, resume + 0.1 - t) or burst_give_up
                    ctx.mod:debug("Drill hold: stage %d, press %.3f, hold %.3f-%.3f, node %d",
                        s, press_t, burst_from, burst_until, index)
                end
            end
            press_t, press_frame = nil, nil
            stage, settled_at, submitted_until = s, nil, 0
            cursor_x, cursor_y = nil, nil
        end
        target_x, target_y, target_index = nil, nil, nil
        if not fresh(mg) or module.cancel_requested() or mg:state() ~= Settings.game_states.gameplay then
            settled_at = nil
            return
        end
        local cursor = mg:cursor_position()
        if not cursor or not position then return end
        target_x, target_y, target_index = position.x, position.y, index
        local selected, searched = mg:selected_index(), mg._search_time
        searched = type(searched) == "number" and searched or nil
        -- A node selected that none of our moves explains (wrong model, replayed or user input).
        local unexplained = selected ~= nil and selected ~= last_selected
        last_selected = selected
        if burst_from and t >= burst_from then
            if searched and searched > burst_from - ACK then
                unexplained = false
                if selected ~= burst_index then trusted = false end
                -- Holding stops now; a further move must clear the native repeat delay of any held frame.
                if selected ~= index then ready_at = math.max(ready_at, t + Settings.drill_move_delay) end
                -- If holding continued a full repeat delay past the registration and the result was slow, a
                -- repeat's result may still be in flight: wait one more receipt delay (a press before
                -- searched + 0.75 is already search-gated).
                if math.min(t, burst_until) > searched + Settings.drill_move_delay and t - searched > 0.7 then
                    ready_at = math.max(ready_at, t + (t - searched))
                end
                ctx.mod:debug("Drill hold result: stage %d, registered press%+.3f, seen after %.3f, node %s (predicted %s)",
                    stage, searched - burst_press, t - searched, tostring(selected), tostring(burst_index))
                burst_from = nil
            elseif t >= burst_give_up then
                -- No result: stop holding, and time the next move after the last held frame.
                holding, burst_from = false, nil
                ready_at = math.max(ready_at, t + Settings.drill_move_delay)
                ctx.mod:debug("Drill hold: no result %.3fs after press, holding switched off", t - burst_press)
            end
        end
        local synced = selected == index and math.abs(cursor.x - target_x) <= 1 / 128
            and math.abs(cursor.y - target_y) <= 1 / 128
        if pending_since then
            -- Only this move's own selection acknowledges it; its search starts on the move's frame.
            -- A late result of an earlier move, or an origin target that keeps the cursor, cannot.
            -- The tolerance absorbs time encoding in the receipt.
            if searched and searched > pending_since - ACK then
                ctx.mod:debug("Drill move: sent %.3f, registered %+.3f, node %s (predicted %s)",
                    pending_since, searched - pending_since, tostring(selected), tostring(predicted))
                unexplained = false
                pending_since, pending_frame = nil, nil
                -- A replayed input can register later than its own frame; time the next move from that.
                ready_at = math.max(ready_at, searched + Settings.drill_move_delay)
                if predicted and selected ~= predicted then trusted = false end
                predicted = nil
                if synced then ready_at = math.max(ready_at, t + ctx.pacing("drill_solve_speed") * 1.50) end
            end
        end
        if unexplained and not pending_since and not burst_from then
            if trusted or holding then ctx.mod:debug("Drill: unexplained node %s, prediction switched off", tostring(selected)) end
            trusted, holding = false, false
        end
        cursor_x, cursor_y = cursor.x, cursor.y
        if synced and not pending_since and mg:is_searching() and mg:search_percentage(t) >= 1 and mg:is_on_target() then
            settled_at = settled_at or t
        else
            settled_at = nil
        end
    end

    function module.input(action, original, t, source)
        if source ~= "input_service" then return original end
        t = t or ctx.time()
        if not t or not game or game ~= ctx.active_minigame or not ctx.settings.enable_drill_auto
            or game:is_completed() or game:state() ~= Settings.game_states.gameplay
            and not (burst_from and MOVE[action]) then return original end
        if PRIMARY[action] then
            local ready = fresh(game) and not module.cancel_requested() and not pending_since
                and settled_at ~= nil and t >= ready_at and t >= submitted_until
                and t - settled_at >= ctx.pacing("drill_solve_speed") * 1.65
            -- Never submit while the server could still run a direction past the confirmed node, and submit again
            -- only once the server has run later input than the earlier submission without advancing the stage.
            local settled = ready and ctx.movement_settled(game, t)
                and (not press_frame or ctx.server_ran_after(game, press_frame) ~= false)
            if not ready then ack_wait = nil elseif not settled then ack_wait = ack_wait or t end
            local held = ctx.pulse(pulse, settled)
            if held and sent_frame ~= ctx.input_frame then
                if press_frame then ctx.mod:debug("Drill press: again, the press at frame %d did not run", press_frame) end
                sent_frame, submitted_until, press_t, press_frame = ctx.input_frame, t + 1.2, t, ctx.input_frame
                if ack_wait then
                    ctx.mod:debug("Drill press: waited %.3fs for the server to run later input", t - ack_wait)
                    ack_wait = nil
                end
            end
            return held
        elseif MOVE[action] then
            local sample = ctx.input_frame or t
            if move_t ~= sample then
                move_t, move_x, move_y = sample, 0, 0
                if burst_from then
                    -- Held across the transition end until its result arrives; from the goal it selects nothing.
                    if t >= burst_from and t < burst_until then move_x, move_y, move_release = burst_x, burst_y, true end
                elseif move_release then
                    move_release = false
                elseif fresh(game) and not module.cancel_requested() and target_x and cursor_x
                    and t > ready_at and t >= submitted_until and not pending_since
                    and game:selected_index() ~= target_index then
                    local selected, dx, dy = game:selected_index()
                    -- Plan only from a confirmed native position: a target or the reset origin.
                    if trusted and (selected or math.abs(cursor_x) + math.abs(cursor_y) < 1 / 64) then
                        dx, dy, predicted = aim(game, stage, selected, target_index)
                    else
                        dx, dy = target_x - cursor_x, cursor_y - target_y
                        local length = math.sqrt(dx * dx + dy * dy)
                        -- A target at the cursor lies at native angle atan2(0, 0) = 0.
                        if length > 0 then dx, dy = dx / length, dy / length else dx, dy = 1, 0 end
                    end
                    move_x, move_y = dx, dy
                    pending_since, pending_frame, move_release, settled_at = t, ctx.input_frame, true, nil
                    -- Drill does not reset its repeat timer on neutral input.
                    ready_at = math.max(ready_at, t + Settings.drill_move_delay)
                end
            end
            if move_x then return movement(action, move_x, move_y) end
        end
        return original
    end

    function module.settings_changed(id)
        if id == "enable_drill_auto" or id == "drill_solve_speed" then module.reset("settings") end
    end

    function module.cancel_requested()
        if not game or not ctx.settings.enable_drill_auto or not ctx.session_valid(game)
            or game:is_completed() then return false end
        local t = ctx.time()
        if pending_since and t and t - pending_since >= 2.5 then
            -- The server has run its own input for a later frame: the move's frame can never run again. It was lost,
            -- or ran without selecting; a selection's result would have arrived before that state. Elapsed time alone
            -- could not tell that. Retry with direct aim from the confirmed node; even a result still in flight is
            -- never this retry's acknowledgement (search start), so it cannot release a submission.
            if not game._is_server and pending_frame and ctx.server_ran_after(game, pending_frame) == true then
                ctx.mod:debug("Drill move: no result %.3fs after %.3f, the server ran later input; retrying",
                    t - pending_since, pending_since)
                pending_since, pending_frame, predicted, trusted = nil, nil, nil, false
            else
                -- Direction is not idempotent; elapsed time cannot acknowledge a move.
                recovery_requested = true
            end
        end
        return recovery_requested
    end

    ctx.mod:hook_safe("MinigameDrill", "start", function(self, player)
        if ctx.is_local_player(player) then
            if openings[self] and openings[self].foreign then openings[self] = nil end
            opening(self).started = true
        elseif player or not ctx.session_valid(self) then
            openings[self] = { foreign = true }
        end
    end)
    ctx.mod:hook_safe("MinigameDrill", "stop", function(self, is_automatic)
        if is_automatic ~= nil or not ctx.session_valid(self) then
            openings[self] = nil
            if self == game then module.reset("session_end") end
        end
    end)
    ctx.mod:hook_safe("MinigameDrill", "set_current_stage", function(self, next_stage)
        if self._is_server == false then opening(self).stage = true end
    end)
    ctx.mod:hook_safe("MinigameDrill", "set_cursor_position", function(self, x, y, selected_target)
        if self._is_server == false then opening(self).cursor = true end
    end)
    ctx.mod:hook_safe("MinigameDrill", "set_searching", function(self, t)
        if self._is_server == false then opening(self).search = true end
    end)

    ctx.mod:hook_require("scripts/ui/views/scanner_display_view/minigame_drill_view", function(View)
        ctx.mod:hook_safe(View, "draw_widgets", function(self, dt, t, input_service, ui_renderer)
            if not ctx.settings.enable_drill or not ui_renderer then return end
            local ext = self._minigame_extension
            local mg = ext and ext:minigame(Settings.types.drill)
            if not mg or mg ~= ctx.active_minigame or mg:is_completed() or mg:state() ~= Settings.game_states.gameplay then return end
            local s, index = target(mg)
            local row = s and self._target_widgets[s]
            local widget = index and row and row[index]
            if not widget then return end
            -- Reuse the engine widget without retaining a highlight in its mutable style.
            local color = widget.style.highlight.color
            local a, r, g, b = color[1], color[2], color[3], color[4]
            color[1], color[2], color[3], color[4] = 255, 255, 255, 255
            UIWidget.draw(widget, ui_renderer)
            color[1], color[2], color[3], color[4] = a, r, g, b
        end)
    end)

    return module
end
