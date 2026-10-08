local STAGE_ACK_ALPHA = 0.3

return function(ctx)
    ---@class NoBrainerMod
    local mod = ctx.mod
    local module = {}
    local game, previous_start, board_start, board_target
    local candidate_start, candidate_target, candidate_since
    local waiting = false
    local pulse, pending_stages, pending_times = {}, {}, {}
    local sent_frame, predicted_stage, observed_stage, observed_mistakes
    local ahead = true
    local observed_at
    local views = setmetatable({}, { __mode = "k" })
    local stopped_clocks = setmetatable({}, { __mode = "k" })
    local clock_receipts = setmetatable({}, { __mode = "k" })
    local board_receipts = setmetatable({}, { __mode = "k" })
    local holds = { action_one_hold = true, interact_hold = true, interact_primary_hold = true, jump_held = true }

    local function clear_press()
        table.clear(pulse)
        table.clear(pending_stages)
        table.clear(pending_times)
        sent_frame, predicted_stage, observed_stage, observed_mistakes = nil, nil, nil, nil
        ahead = true
    end

    -- Submit-to-stage receipt delay (Smart Seed Reroll falls back to it while presses cannot run ahead).
    local function observe_stage_ack(sent)
        local t = ctx.time()
        local observed = t and sent and t - sent
        if not observed or observed <= 0 or observed >= 1.2 then return end
        local current = mod._ds_stage_ack_cost or observed
        mod._ds_last_stage_ack = observed
        mod._ds_stage_ack_cost = observed > current and observed or current + (observed - current) * STAGE_ACK_ALPHA
        mod._ds_stage_ack_samples = (mod._ds_stage_ack_samples or 0) + 1
    end

    local function stage_received(mg, stage)
        if game ~= mg or not ctx.settings.enable_decode_auto then return end
        local expected = pending_stages[1]
        if expected then
            if not mg._is_server then observe_stage_ack(pending_times[1]) end
            if stage ~= expected + 1 then ahead = false end
            table.remove(pending_stages, 1)
            table.remove(pending_times, 1)
        elseif observed_stage and stage ~= observed_stage then
            ahead = false
        end
        observed_stage = stage
        if not ahead or #pending_stages == 0 then predicted_stage = stage end
    end

    function module.reset(reason)
        if reason == "gameplay_exit" then
            mod._ds_stage_ack_cost, mod._ds_stage_ack_samples, mod._ds_last_stage_ack = nil, 0, nil
        end
        if reason == "session_end" and game then
            stopped_clocks[game] = board_start or game._decode_start_time
            clock_receipts[game] = nil
            board_receipts[game] = nil
        end
        game, previous_start, board_start, board_target = nil, nil, nil, nil
        candidate_start, candidate_target, candidate_since = nil, nil, nil
        waiting, observed_at = false, nil
        views = setmetatable({}, { __mode = "k" })
        clear_press()
        if reason ~= "session_end" then
            stopped_clocks = setmetatable({}, { __mode = "k" })
            clock_receipts = setmetatable({}, { __mode = "k" })
            board_receipts = setmetatable({}, { __mode = "k" })
        end
    end

    function module.start(mg, player)
        if not player then
            if ctx.session_valid(mg) then return end
            if game == mg then module.reset("ownership_changed") end
            if not mg._is_server then clock_receipts[mg] = false end
            board_receipts[mg] = nil
            return
        end
        if not ctx.is_local_player(player) then
            if game == mg then module.reset("ownership_changed") end
            if not mg._is_server then clock_receipts[mg] = false end
            board_receipts[mg] = nil
            return
        end
        -- Own setup RPCs can precede local unit initialization; foreign starts/real stops retire them.
        local receipt = clock_receipts[mg]
        previous_start = not mg._is_server and mg._decode_start_time
            or stopped_clocks[mg] or (game == mg and board_start or nil)
        if receipt and receipt.start == mg._decode_start_time and receipt.symbols == mg._symbols then
            previous_start = nil
        end
        clock_receipts[mg] = nil
        game = mg
        board_start, board_target = nil, nil
        candidate_start, candidate_target, candidate_since = nil, nil, nil
        waiting, observed_at = not mg._is_server, nil
        clear_press()
    end

    function module.stop(mg, stop_arg)
        if stop_arg == nil and mg._is_server == false and ctx.session_valid(mg) then
            -- Native stop disarms the edge, but continuing board receipts still own pending predictions.
            table.clear(pulse)
            return
        end
        clock_receipts[mg] = nil
        board_receipts[mg] = nil
        if game == mg then
            stopped_clocks[mg] = board_start or mg._decode_start_time
            game, observed_at = nil, nil
            clear_press()
        end
    end

    local function board_ready(mg, start)
        local receipt = board_receipts[mg]
        if not receipt or receipt.symbols ~= mg._symbols or receipt.start ~= start or not receipt.stage then
            return false
        end
        for i = 1, mg._stage_amount do
            if receipt.targets[i] == nil or receipt.targets[i] ~= mg._decode_targets[i] then return false end
        end
        return true
    end

    local function sync_ready(mg, t)
        local start, stage = mg._decode_start_time, mg._current_stage
        local target = mg._decode_targets and mg._decode_targets[1]
        if not start or not target then return false end
        if not waiting and board_start and (start ~= board_start or target ~= board_target) then
            waiting = not mg._is_server
            candidate_since = nil
            clear_press()
        end
        if waiting then
            if stage ~= 1 or start == previous_start then
                candidate_since = nil
                return false
            end
            -- A rerolled board that exactly matches the seed prediction is also complete and fresh.
            local predicted = mod._ds_reroll_predicted_sync_ready and mod._ds_reroll_predicted_sync_ready(mg, previous_start)
            if not predicted and not board_ready(mg, start) then
                if not candidate_since or candidate_start ~= start or candidate_target ~= target then
                    candidate_start, candidate_target, candidate_since = start, target, t
                    return false
                end
                if t - candidate_since < 0.12 then return false end
            end
            waiting = false
            clock_receipts[mg] = nil
            board_receipts[mg] = nil
        end
        board_start, board_target = start, target
        return true
    end

    function module.observe(mg, t)
        if not t or not mg then return end
        if game ~= mg then
            -- Rearm after enabling/settings changes in an already open session.
            game, previous_start = mg, stopped_clocks[mg]
            board_start, board_target = nil, nil
            candidate_since = nil
            -- A later synchronized stage proves this is an existing board, not a stale stage-1 restart.
            waiting = not mg._is_server and (not mg._current_stage or mg._current_stage == 1)
            clear_press()
        end
        observed_at = t
        if not ctx.settings.enable_decode_auto then clear_press(); return end
        if mg:is_completed() then clear_press(); return end
        sync_ready(mg, t)
        if observed_stage and mg._current_stage ~= observed_stage
            or observed_mistakes and mg._mistakes ~= observed_mistakes
            or pending_times[1] and (t < pending_times[1] or t - pending_times[1] >= 1.2) then
            -- Never discard timed-out commands: a delayed second press can still roll back the board.
            ahead = false
            predicted_stage = mg._current_stage
        end
        observed_stage, observed_mistakes = mg._current_stage, mg._mistakes
        predicted_stage = predicted_stage or observed_stage
    end

    function module.input(action, original, t, source)
        if not holds[action] or not ctx.settings.enable_decode_auto or not t
            or not game or ctx.active_minigame ~= game
            or observed_at ~= t or game:is_completed() then return original end
        -- Core observes at the fixed time used by HumanInputHandler serialization.
        if source ~= "input_service" then return original end
        -- Smart Seed Reroll owns the board while it evaluates, cancels and reopens.
        if mod._ds_reroll_blocks_solver and mod._ds_reroll_blocks_solver() then return false end
        local stage, start = predicted_stage, game._decode_start_time
        local target = game._decode_targets and game._decode_targets[stage]
        local items, sweep = game._decode_symbols_items_per_stage, game._decode_symbols_sweep_duration
        local ready = false
        if not waiting and #pending_stages < (ahead and 2 or 1)
            and target and start and items and items > 1 and sweep and sweep > 0
            and game._current_state == "gameplay" then
            local phase = (t - start) % (2 * sweep)
            local period, margin = sweep * 2, sweep / (items - 1)
            local center = (target - 1) * margin
            local radius = math.max(0, margin * 0.5 - 0.03)
            local forward = center + math.ceil((phase - radius - center - 1e-12) / period) * period
            local reverse_center = period - center
            local reverse = reverse_center
                + math.ceil((phase - radius - reverse_center - 1e-12) / period) * period
            ready = math.max(math.min(forward, reverse) - radius, phase) <= phase
        end
        local held = ctx.pulse(pulse, ready)
        if held and sent_frame ~= ctx.input_frame then
            sent_frame = ctx.input_frame
            pending_stages[#pending_stages + 1], pending_times[#pending_times + 1] = stage, t
            predicted_stage = stage + 1
        end
        return held
    end

    function module.synced(mg)
        return game == mg and not waiting
    end

    -- Earliest next press after a stage press, for Smart Seed Reroll's board valuation: a release frame and the
    -- next press frame while presses run ahead of receipts, else the observed receipt delay.
    function mod._ds_stage_ready_delay(server)
        local session = Managers.state and Managers.state.game_session
        local step = session and session.fixed_time_step
        local frames = 2 * (type(step) == "number" and step > 0 and step or 1 / 30)
        if server or ahead then return frames end
        return math.max(frames, mod._ds_stage_ack_cost or 0, mod._ds_network_rtt() or 0)
    end

    -- Receipt delay of a client press: at most two presses wait for their stage receipts.
    function mod._ds_stage_ack_delay(server)
        if server then return 0 end
        return math.max(mod._ds_stage_ack_cost or 0, mod._ds_network_rtt() or 0)
    end

    function module.cancel_requested()
        if not ctx.settings.enable_decode_auto or not game or ctx.active_minigame ~= game
            or game:is_completed() then return false end
        -- Only session teardown retires a lost command; this deadline does not choose a hit time.
        local oldest, t = pending_times[1], ctx.time()
        return oldest ~= nil and t ~= nil and t - oldest >= 2.5
    end

    -- Read-only solver state for the NoBrainerDebug companion (NoBrainer_core.lua mod._frame_snapshot).
    function module.snapshot(out, t)
        out.waiting, out.board_start, out.previous_start = waiting, board_start, previous_start
        out.candidate_age = candidate_since and t and t - candidate_since or nil
        out.pending, out.pending_stage = #pending_stages, pending_stages[1]
        out.pending_age = pending_times[1] and t and t - pending_times[1] or nil
        out.predicted_stage, out.observed_stage, out.ahead, out.sent_frame = predicted_stage, observed_stage, ahead, sent_frame
        out.reroll_blocks = mod._ds_reroll_blocks_solver ~= nil and mod._ds_reroll_blocks_solver() or false
    end

    function module.settings_changed(id)
        if id == "enable_decode_auto" then
            clear_press()
            observed_at = nil
        end
    end

    -- These notifications must precede/see beyond core state observation:
    -- start distinguishes retained clocks from early receipts; stop() acknowledges server teardown.
    mod:hook_safe("MinigameDecodeSymbols", "start", function(self, player, send_to_self_client)
        if ctx.is_local_player(player) then
            if mod._ds_reroll_start then mod._ds_reroll_start(self) end
        elseif (player or not ctx.session_valid(self)) and mod._ds_reroll_abort then
            mod._ds_reroll_abort(self)
        end
        module.start(self, player)
    end)
    mod:hook_safe("MinigameDecodeSymbols", "stop", function(self, is_automatic)
        if mod._ds_reroll_stop then mod._ds_reroll_stop(self, is_automatic) end
        module.stop(self, is_automatic)
    end)
    mod:hook_safe("MinigameDecodeSymbols", "complete", function(self)
        if mod._ds_reroll_complete then mod._ds_reroll_complete(self) end
    end)
    mod:hook_safe("MinigameDecodeSymbols", "set_current_stage", function(self, stage)
        if not self._is_server then
            local receipt = board_receipts[self]
            if receipt then receipt.stage = stage == 1 end
            stage_received(self, stage)
        end
    end)
    mod:hook_safe("MinigameDecodeSymbols", "on_action_pressed", function(self, t)
        if self._is_server then stage_received(self, self._current_stage) end
    end)
    mod:hook_safe("MinigameDecodeSymbols", "setup_game", function(self)
        board_receipts[self] = nil
        if game == self then clear_press() end
    end)
    mod:hook_safe("MinigameDecodeSymbols", "set_symbols", function(self, symbols)
        if clock_receipts[self] then clock_receipts[self] = nil end
        if not self._is_server then
            -- A cloned board starts a receipt set; retained target values are not receipts.
            board_receipts[self] = { symbols = self._symbols, targets = {} }
        end
        if game ~= self then return end
        previous_start = board_start or previous_start
        candidate_start, candidate_target, candidate_since = nil, nil, nil
        waiting = true
        clear_press()
    end)
    mod:hook_safe("MinigameDecodeSymbols", "set_target", function(self, stage, target)
        local receipt = board_receipts[self]
        if receipt then receipt.targets[stage] = target end
    end)
    mod:hook_safe("MinigameDecodeSymbols", "set_start_time", function(self, time)
        -- A nil-player start outside our continuing state belongs to another client (or an AI hack).
        if self._is_server or clock_receipts[self] == false then return end
        clock_receipts[self] = { start = time, symbols = self._symbols }
        local receipt = board_receipts[self]
        if receipt then receipt.start = time end
        if game == self and waiting then
            previous_start = nil
            candidate_since = nil
        end
    end)

    mod:hook_require("scripts/ui/views/scanner_display_view/minigame_decode_symbols_view", function(View)
        local settings = require("scripts/ui/views/scanner_display_view/scanner_display_view_decode_symbols_settings")
        local UIWidget = require("scripts/managers/ui/ui_widget")
        mod:hook_safe(View, "draw_widgets", function(self, dt, t, input_service, renderer)
            if not ctx.settings.enable_decode_highlight then return end
            local mg = ctx.active_minigame
            if not mg or not self._minigame_extension or self._minigame_extension:minigame() ~= mg
                or mg:is_completed() then return end
            local stage, targets = mg._current_stage, mg._decode_targets
            if not stage or not targets then return end
            local count = math.min(3, #targets - stage)
            if count <= 0 then views[self] = nil; return end
            local widgets = views[self]
            if not widgets then widgets = {}; views[self] = widgets end
            for i = 1, count do
                local widget = widgets[i]
                if not widget then
                    local definition = UIWidget.create_definition({ {
                        pass_type = "texture", style_id = "highlight",
                        value = "content/ui/materials/backgrounds/scanner/scanner_decode_symbol_highlight",
                        style = { hdr = true, color = { 100, 255, 255, 165 } },
                    } }, "center_pivot", nil, settings.decode_symbol_widget_size)
                    widget = UIWidget.init("nb_symbol_target_" .. i, definition)
                    widgets[i] = widget
                end
                local row, size = stage + i, settings.decode_symbol_widget_size
                widget.offset[1] = settings.decode_symbol_starting_offset_x
                    + (size[1] + settings.decode_symbol_spacing) * (targets[row] - 1)
                widget.offset[2] = settings.decode_symbol_starting_offset_y
                    + (size[2] + settings.decode_symbol_spacing) * (row - 1)
                widget.offset[3] = 5
                UIWidget.draw(widget, renderer)
            end
        end)
        mod:hook_safe(View, "destroy", function(self) views[self] = nil end)
    end)

    function mod._ds_network_rtt()
        local connection = Managers.connection
        local network = rawget(_G, "Network")
        if not connection or not connection.host or not network or not network.ping then return nil end
        local host_ok, host = pcall(connection.host, connection)
        if not host_ok or not host then return nil end
        local ping_ok, rtt = pcall(network.ping, host)
        return ping_ok and type(rtt) == "number" and rtt >= 0 and rtt or nil
    end

    return module
end
