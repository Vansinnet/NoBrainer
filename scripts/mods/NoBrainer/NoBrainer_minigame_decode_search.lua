local Settings = require("scripts/settings/minigame/minigame_settings")
local ViewSettings = require("scripts/ui/views/scanner_display_view/scanner_display_view_decode_search_settings")
local UIWidget = require("scripts/managers/ui/ui_widget")
local MOVE = { move = true, move_left = true, move_right = true, move_forward = true, move_backward = true }
local PRIMARY = { action_one_hold = true, interact_hold = true, jump_held = true }
local HOLD = 0.08 -- about four frames from the native resume (observed: press + 0.6/0.25 s + two frames)

local function movement(action, x, y)
    if action == "move_left" then return math.max(-x, 0) end
    if action == "move_right" then return math.max(x, 0) end
    if action == "move_forward" then return math.max(y, 0) end
    if action == "move_backward" then return math.max(-y, 0) end
    return Vector3(x, y, 0)
end

return function(ctx)
    local module = {}
    local game, stage, observed, target_x, target_y
    local cursor_x, cursor_y
    local pending = {}
    local pulse = {}
    local resync_until, cautious, ack_timeout = nil, false, 0.8
    local base_timeout, backoff, next_ping = 0.8, 1, 0
    local move_limit = 2
    local ready_at, settled_at, submitted_until = 0, nil, 0
    local move_frame, move_x, move_y, move_release, last_move_frame, sent_frame, press_ready
    local cache_game, cache_stage, cache_symbols, cache_target, cache_x, cache_y
    local widgets
    local press_t, hold_from, hold_until, hold_x, hold_y, hold_press, hold_stage, next_x, next_y
    local holding = true -- cleared after a held step the server ignored or that did not land as expected
    local stale_x, stale_y, stale_t -- a reopened client shows the old cursor until the server's recentre arrives
    local unverified -- the recentre never showed: no press until the server confirms a move or a resync
    local ack_wait -- when a press was otherwise ready but waited for the server to run later input
    local press_frame -- input frame of this stage's last press
    -- Client minigame -> whether the recentre arrived since our own last start (false: not yet).
    local recentred = setmetatable({}, { __mode = "k" })
    local center_x, center_y = math.floor(Settings.decode_search_board_width / 2),
        math.floor(Settings.decode_search_board_height / 2)
    local width, height = Settings.decode_search_board_width, Settings.decode_search_board_height
    local cw, ch = Settings.decode_search_cursor_width, Settings.decode_search_cursor_height

    local function target(mg)
        local s, symbols, wanted = mg:current_stage(), mg:symbols(), mg:current_decode_target()
        if not s or not wanted or #wanted ~= cw * ch or #symbols ~= width * height then
            return nil
        end
        if cache_game == mg and cache_stage == s and cache_symbols == symbols and cache_target == wanted then
            return cache_x, cache_y
        end
        local cursor = mg:cursor_position()
        local best_steps, best_distance = math.huge, math.huge
        cache_x, cache_y = nil, nil
        for y = 1, height - ch + 1 do
            for x = 1, width - cw + 1 do
                -- The engine returns a shared temporary array; compare it immediately.
                local found = mg:get_symbols_for_target(x, y)
                local matches = true
                for i = 1, cw * ch do
                    if found[i] ~= wanted[i] then
                        matches = false
                        break
                    end
                end
                if matches then
                    local dx, dy = cursor and math.abs(x - cursor.x) or 0, cursor and math.abs(y - cursor.y) or 0
                    local steps, distance = math.max(dx, dy), dx + dy
                    if steps < best_steps or steps == best_steps and distance < best_distance then
                        cache_x, cache_y, best_steps, best_distance = x, y, steps, distance
                    end
                end
            end
        end
        cache_game, cache_stage, cache_symbols, cache_target = mg, s, symbols, wanted
        return cache_x, cache_y
    end

    function module.reset(reason)
        game, stage, observed, target_x, target_y = nil, nil, nil, nil, nil
        cursor_x, cursor_y = nil, nil
        table.clear(pending)
        table.clear(pulse)
        resync_until, cautious, ack_timeout = nil, false, 0.8
        base_timeout, backoff, next_ping = 0.8, 1, 0
        move_limit = 2
        ready_at, settled_at, submitted_until = 0, nil, 0
        move_frame, move_x, move_y, last_move_frame, sent_frame, press_ready = nil, 0, 0, nil, nil, false
        move_release = true
        cache_game, cache_stage, cache_symbols, cache_target, cache_x, cache_y = nil, nil, nil, nil, nil, nil
        widgets = nil
        press_t, hold_from, hold_stage = nil, nil, nil
        stale_x, stale_y, stale_t, unverified = nil, nil, nil, false
        ack_wait, press_frame = nil, nil
        -- A new mission re-arms the pre-send after a miss (one timeout and resync at most per mission).
        if reason == "gameplay_exit" then holding = true end
    end

    function module.observe(mg, t)
        t = t or ctx.time()
        if not t or not mg or mg ~= ctx.active_minigame or not mg.current_decode_target
            or not ctx.settings.enable_expedition_auto_solve or mg:is_completed() then
            if game then module.reset("inactive") end
            return
        end
        if game ~= mg then
            module.reset("identity")
            game, ready_at = mg, t + (ctx.pacing("expedition_solve_speed") == 0 and 0 or 0.20)
            local cursor = mg:cursor_position()
            -- Every native start recentres (setup_game, minigame_decode_search.lua:80-85). Until that receipt the
            -- client shows an earlier session's cursor (ours or another player's). Unknown counts as not yet.
            if not mg._is_server and recentred[mg] ~= true and cursor
                and (cursor.x ~= center_x or cursor.y ~= center_y) then
                stale_x, stale_y, stale_t = cursor.x, cursor.y, t
            end
            ctx.mod:debug("Search session: t %.3f, stage %s, cursor %s", t, tostring(mg:current_stage()),
                cursor and cursor.x .. "," .. cursor.y or "none")
        end
        if observed == t then return end
        observed = t
        if not mg._is_server and t >= next_ping then
            local connection = Managers.connection
            local host = connection and connection:host()
            local rtt = host and Network.ping(host)
            if type(rtt) ~= "number" or rtt ~= rtt or rtt < 0 or rtt == math.huge then rtt = 0 end
            -- Reduce prediction immediately; expand only after outstanding moves drain.
            if rtt >= 0.25 then move_limit = 1
            elseif #pending == 0 then move_limit = 2 end
            base_timeout = math.min(3.2, math.max(0.8, rtt * 2 + 0.2))
            ack_timeout, next_ping = math.min(3.2, base_timeout * backoff), t + 1
        end
        local s = mg:current_stage()
        if stage ~= s then
            if stage then ready_at = t + ctx.pacing("expedition_solve_speed") * 1.632 end
            hold_from = nil
            -- Our press advanced the stage: hold the next first step across the native transition end.
            -- A local server already acts on its first gameplay frame; only receipt latency is saved.
            if holding and not mg._is_server and stage and s == stage + 1 and press_t and cursor_x and #pending == 0
                and not resync_until and ctx.pacing("expedition_solve_speed") == 0 then
                local tx, ty = target(mg)
                if tx and (tx ~= cursor_x or ty ~= cursor_y) then
                    hold_from, hold_press = math.max(press_t + Settings.decode_transition_time, t), press_t
                    hold_until, hold_stage = hold_from + HOLD, s
                    -- The held step, then (as the normal pipeline would) one more after a neutral frame.
                    local x, y = cursor_x, cursor_y
                    for i = 1, math.min(cautious and 1 or move_limit, 2) do
                        local dx, dy = tx - x, ty - y
                        if dx == 0 and dy == 0 then break end
                        local mx = dx == 0 and 0 or dx > 0 and 1 or -1
                        local my = dy == 0 and 0 or dy > 0 and -1 or 1
                        if i == 1 then hold_x, hold_y, next_x = mx, my, nil else next_x, next_y = mx, my end
                        pending[i] = {
                            x = x + mx, y = y - my, start_y = y, diagonal = mx ~= 0 and my ~= 0,
                            until_t = hold_until + ack_timeout + 0.1, held = true,
                        }
                        x, y = x + mx, y - my
                    end
                    ctx.mod:debug("Search hold: stage %d, press %.3f, hold %.3f-%.3f, steps %d",
                        s, press_t, hold_from, hold_until, #pending)
                end
            end
            press_t, press_frame = nil, nil
            stage, settled_at, submitted_until = s, nil, 0
        end
        target_x, target_y = nil, nil
        if mg:state() ~= Settings.game_states.gameplay then
            settled_at = nil
            return
        end
        local cursor = mg:cursor_position()
        if not cursor then return end
        if stale_x then
            -- Neither move nor press from the old cursor. Only the recentre ends the wait; a late result of the
            -- earlier session's last move arrives before it (one ordered channel) and only replaces the old cursor.
            if cursor.x == center_x and cursor.y == center_y then
                ctx.mod:debug("Search reopen: t %.3f, recentre seen", t)
                stale_x, stale_y, stale_t = nil, nil, nil
            elseif t < stale_t + ack_timeout then
                stale_x, stale_y = cursor.x, cursor.y
                return
            else
                -- Recentre missing or very late: move from what the client shows, but press only after the server
                -- has confirmed a move (a probe when already on the target) or a resynchronization has settled.
                ctx.mod:debug("Search reopen: t %.3f, no recentre seen; press only after a confirmed move", t)
                stale_x, stale_y, stale_t, unverified = nil, nil, nil, true
            end
        end
        target_x, target_y = target(mg)
        local changed = cursor_x ~= cursor.x or cursor_y ~= cursor.y
        if changed then
            ctx.mod:debug("Search cursor: t %.3f, %s,%s -> %d,%d, pending %d", t, tostring(cursor_x), tostring(cursor_y),
                cursor.x, cursor.y, #pending)
        end
        local mismatch = false
        if resync_until then
            if changed then resync_until = t + ack_timeout end
            -- The new baseline is final once the server has run later input than any direction we sent.
            if t >= resync_until and ctx.movement_settled(mg, t) then resync_until, unverified = nil, false end
        elseif changed and cursor_x then
            local matched = false
            for i = #pending, 1, -1 do
                local command = pending[i]
                local complete = cursor.x == command.x and cursor.y == command.y
                -- A diagonal emits X first. Retire predecessors, not this partial move.
                local partial = command.diagonal and cursor.x == command.x and cursor.y == command.start_y
                if complete or partial then
                    if complete and command.held then
                        ctx.mod:debug("Search hold result: seen press%+.3f", t - hold_press)
                    end
                    for _ = 1, complete and i or i - 1 do table.remove(pending, 1) end
                    if complete then
                        cautious, backoff, ack_timeout, unverified = false, 1, base_timeout, false
                        ready_at = math.max(ready_at, t + ctx.pacing("expedition_solve_speed") * 1.054)
                    end
                    matched = true
                    break
                end
            end
            mismatch = not matched
        end
        if not resync_until and (mismatch or pending[1] and t >= pending[1].until_t) then
            -- A timeout is not an ACK. Drain late traffic before trusting a new baseline,
            -- and use one command until a full confirmation restores the RTT-limited window.
            if pending[1] and pending[1].held then
                holding = false
                ctx.mod:debug("Search hold: %s, holding switched off", mismatch and "unexpected cursor" or "no result")
            end
            table.clear(pending)
            hold_from, next_x = nil, nil -- no held or pre-sent step outside the pending list
            cautious, backoff = true, math.min(4, backoff * 2)
            ack_timeout = math.min(3.2, base_timeout * backoff)
            resync_until, settled_at, move_release = t + ack_timeout, nil, true
            ctx.mod:debug("Search resync: t %.3f, %s, quiet %.2fs", t, mismatch and "unexpected cursor" or "timeout", ack_timeout)
        end
        if changed then settled_at = nil end
        cursor_x, cursor_y = cursor.x, cursor.y
        if not resync_until and #pending == 0 and cursor_x == target_x and cursor_y == target_y then
            settled_at = settled_at or t
        else
            settled_at = nil
        end
    end

    function module.input(action, original, t, source)
        -- The extension reads the serialized sample; never replace it with a newer decision.
        if source ~= "input_service" then return original end
        t = t or ctx.time()
        if not t or not game or game ~= ctx.active_minigame or not ctx.settings.enable_expedition_auto_solve
            or game:is_completed() or game:state() ~= Settings.game_states.gameplay
            and not (hold_stage == stage and MOVE[action]) then return original end
        if not PRIMARY[action] and not MOVE[action] then return original end
        local sample = ctx.input_frame
        if not sample then return original end
        if move_frame ~= sample then
            move_frame, move_x, move_y = sample, 0, 0
            if hold_from then
                -- Held over the expected resume; inside one repeat delay the server takes it at most once.
                if t >= hold_from and t < hold_until then
                    move_x, move_y = hold_x, hold_y
                    settled_at, move_release, last_move_frame = nil, true, sample
                elseif t >= hold_until then
                    if move_release then
                        move_release = false -- neutral resets the native repeat delay
                    else
                        if next_x then
                            move_x, move_y = next_x, next_y
                            settled_at, move_release, last_move_frame = nil, true, sample
                        end
                        hold_from = nil
                    end
                end
            elseif move_release then
                -- Always serialize neutral, never the user's movement, between commands.
                move_release = false
            elseif target_x and cursor_x and not resync_until and t >= ready_at and t >= submitted_until
                and #pending < (cautious and 1 or move_limit) and not (pending[1] and pending[1].held) then
                local tail = pending[#pending]
                local x, y = tail and tail.x or cursor_x, tail and tail.y or cursor_y
                local goal_x = target_x
                -- Unverified cursor already on the target: step off and back so the server confirms where it is.
                if unverified and not tail and x == target_x and y == target_y then
                    goal_x = target_x > 1 and target_x - 1 or target_x + 1
                end
                local dx, dy = goal_x - x, target_y - y
                if dx ~= 0 or dy ~= 0 then
                    move_x = dx == 0 and 0 or dx > 0 and 1 or -1
                    move_y = dy == 0 and 0 or dy > 0 and -1 or 1
                    pending[#pending + 1] = {
                        x = x + move_x, y = y - move_y, start_y = y,
                        diagonal = move_x ~= 0 and move_y ~= 0, until_t = t + ack_timeout,
                    }
                    ctx.mod:debug("Search move: t %.3f, from %d,%d to %d,%d, pending %d",
                        t, x, y, x + move_x, y - move_y, #pending)
                    ready_at = math.max(ready_at, t + ctx.pacing("expedition_solve_speed") * 1.054)
                    settled_at, move_release, last_move_frame = nil, true, sample
                end
            end
            local ready = not resync_until and not unverified and #pending == 0 and settled_at ~= nil
                and last_move_frame ~= sample and t >= ready_at and t >= submitted_until
                and t - settled_at >= ctx.pacing("expedition_solve_speed") * 0.646
            -- Never press while the server could still run a direction past the confirmed cursor, and press again
            -- only once the server has run later input than the earlier press without advancing the stage.
            press_ready = ready and ctx.movement_settled(game, t)
                and (not press_frame or ctx.server_ran_after(game, press_frame) ~= false)
            if not ready then ack_wait = nil elseif not press_ready then ack_wait = ack_wait or t end
        end
        if PRIMARY[action] then
            local held = ctx.pulse(pulse, press_ready)
            if held and sent_frame ~= sample then
                if press_frame then ctx.mod:debug("Search press: again, the press at frame %d did not run", press_frame) end
                sent_frame, submitted_until, press_t, press_frame = sample, t + 1.2, t, sample
                if ack_wait then
                    ctx.mod:debug("Search press: waited %.3fs for the server to run later input", t - ack_wait)
                    ack_wait = nil
                end
            end
            return held
        end
        return movement(action, move_x, move_y)
    end

    function module.settings_changed(id)
        if id == "enable_expedition_auto_solve" or id == "expedition_solve_speed" then module.reset("settings") end
    end

    ctx.mod:hook_safe("MinigameDecodeSearch", "start", function(self, player)
        if self._is_server == false and ctx.is_local_player(player) then recentred[self] = false end
    end)
    ctx.mod:hook_safe("MinigameDecodeSearch", "set_cursor_position", function(self, x, y)
        if self._is_server == false and recentred[self] == false and x == center_x and y == center_y then
            recentred[self] = true
        end
    end)

    ctx.mod:hook_require("scripts/ui/views/scanner_display_view/minigame_decode_search_view", function(View)
        ctx.mod:hook_safe(View, "draw_widgets", function(self, dt, t, input_service, ui_renderer)
            if not ctx.settings.enable_matching or not ui_renderer then return end
            local ext = self._minigame_extension
            local mg = ext and ext:minigame(Settings.types.decode_search)
            if not mg or mg ~= ctx.active_minigame or mg:is_completed() or mg:state() ~= Settings.game_states.gameplay then return end
            local tx, ty = target(mg)
            if not tx then return end
            if not widgets then
                widgets = {}
                for i = 1, cw * ch do
                    widgets[i] = UIWidget.init("nb_search_" .. i, UIWidget.create_definition({{
                        pass_type = "texture", style_id = "highlight",
                        value = "content/ui/materials/backgrounds/scanner/scanner_decode_symbol_highlight",
                        style = { hdr = true, color = { 110, 255, 165, 0 } },
                    }}, "center_pivot", nil, ViewSettings.symbol_widget_size))
                end
            end
            local size, spacing = ViewSettings.symbol_widget_size, ViewSettings.symbol_spacing
            for y = 0, ch - 1 do
                for x = 0, cw - 1 do
                    local widget = widgets[y * cw + x + 1]
                    widget.offset[1] = ViewSettings.symbol_starting_offset_x + (size[1] + spacing) * (tx + x - 1)
                    widget.offset[2] = ViewSettings.symbol_starting_offset_y + (size[2] + spacing) * (ty + y - 1)
                    widget.offset[3] = 6
                    UIWidget.draw(widget, ui_renderer)
                end
            end
        end)
    end)

    return module
end
