local Settings = require("scripts/settings/minigame/minigame_settings")
local UIWidget = require("scripts/managers/ui/ui_widget")
local MOVE = { move = true, move_left = true, move_right = true, move_forward = true, move_backward = true }
local PRIMARY = { action_one_hold = true, interact_hold = true, jump_held = true }
local CHAIN = 256 -- seed draws searched for the server's position: earlier sessions on the same device advance it
local MATCH = 0.004 -- targets are whole hundredths (minigame_frequency.lua:67-77)
local REPORT_WAIT = 0.1 -- the first armed press waits this long for the server's report of the session's first frame

local function movement(action, x, y)
    if action == "move_left" then return math.max(-x, 0) end
    if action == "move_right" then return math.max(x, 0) end
    if action == "move_forward" then return math.max(y, 0) end
    if action == "move_backward" then return math.max(-y, 0) end
    return Vector3(x, y, 0)
end

-- One frequency draw (minigame_frequency.lua:67-77). Each next_random call advances the seed one step whatever the
-- bounds (types/darktide/core.lua).
local function draw(seed)
    local x, y
    seed, x = math.next_random(seed, Settings.frequency_width_min_scale * 100, Settings.frequency_width_max_scale * 100)
    seed, y = math.next_random(seed, Settings.frequency_height_min_scale * 100, Settings.frequency_height_max_scale * 100)
    return seed, x / 100, y / 100
end

-- _change_target_frequency (minigame_frequency.lua:94-103): redrawn while either axis is within the margin.
local function next_target(seed, fx, fy)
    local margin = Settings.frequency_success_margin
    for _ = 1, 64 do
        local x, y
        seed, x, y = draw(seed)
        if math.abs(fx - x) >= margin and math.abs(fy - y) >= margin then return seed, x, y end
    end
end

-- The server drew this session's frequency at setup and its first target at start, both from its current seed, which
-- lies on the chain from the received start seed (minigame_frequency.lua:40-56,79-103). The receipt pins where the
-- first target was drawn, not where setup began: a later start whose frequency skips the same redraws yields the same
-- target. Every position matching the first target must predict the same targets 2 and 3, given a frequency no input
-- has changed.
local function predict(start_seed, tx, ty)
    local seed, found = start_seed, nil
    for _ = 0, CHAIN do
        local s, fx, fy = draw(seed)
        local s1, x1, y1 = next_target(s, fx, fy)
        if s1 and math.abs(x1 - tx) < MATCH and math.abs(y1 - ty) < MATCH then
            local s2, x2, y2 = next_target(s1, fx, fy)
            local s3, x3, y3
            if s2 then s3, x3, y3 = next_target(s2, fx, fy) end
            if not s3 then return false end
            if found and (found[1] ~= x2 or found[2] ~= y2 or found[3] ~= x3 or found[4] ~= y3) then return false end
            found = { x2, y2, x3, y3 }
        end
        seed = math.next_random(seed, 1, 2)
    end
    return found or false
end

return function(ctx)
    local module = {}
    local game, stage, observed, target_x, target_y, direction_x, direction_y
    local ready_at = 0
    local pulse = {}
    local armed_frame, armed_t, armed_stage, armed_x, armed_y
    local consuming, consumed, scored, waiting, stage_received, target_received
    local waiting_since, stage_one_failed, recovery_requested
    local move_t, move_x, move_y
    local arrows
    local openings = setmetatable({}, { __mode = "k" })
    -- Pipeline (DESIGN.md, Frequency pipeline): all three tests at once from predicted targets.
    local start_seeds = setmetatable({}, { __mode = "k" }) -- client minigame -> start seed of its latest setup
    local predicting = true -- cleared after a wrong prediction, until the next mission
    local axis_moved -- this session consumed a direction, which changes the server's frequency
    local plan, plan_x, plan_y -- targets 2 and 3 predicted for the first target plan_x, plan_y (false: none)
    local armed_plan, pipeline, fresh_t

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
        return mg._is_server == true or receipt and receipt.started and receipt.stage and receipt.target
    end
    local margin = Settings.frequency_success_margin * 0.35
    local range_x = Settings.frequency_width_max_scale - Settings.frequency_width_min_scale
    local range_y = Settings.frequency_height_max_scale - Settings.frequency_height_min_scale

    function module.reset(reason)
        if reason ~= "identity" then
            if reason == "session_end" or reason == "session_changed" or reason == "ownership_changed" or reason == "inactive" then
                if game then openings[game] = nil end
            else
                table.clear(openings)
            end
        end
        game, stage, observed, target_x, target_y, direction_x, direction_y = nil, nil, nil, nil, nil, nil, nil
        ready_at, pulse = 0, {}
        armed_frame, armed_t, armed_stage, armed_x, armed_y = nil, nil, nil, nil, nil
        consuming, consumed, scored, waiting, stage_received, target_received = false, false, false, false, false, false
        waiting_since, stage_one_failed, recovery_requested = nil, false, false
        move_t, move_x, move_y = nil, nil, nil
        arrows = nil
        axis_moved, plan, plan_x, plan_y, armed_plan, pipeline, fresh_t = false, nil, nil, nil, nil, nil, nil
        if reason == "gameplay_exit" then predicting = true end
    end

    function module.observe(mg, t)
        t = t or ctx.time()
        if not t or not mg or mg ~= ctx.active_minigame or not mg.target_frequency
            or not ctx.settings.enable_frequency_auto or mg:is_completed() then
            if game then module.reset("inactive") end
            return
        end
        local pacing = ctx.pacing("frequency_solve_speed")
        if game ~= mg then
            module.reset("identity")
            game, ready_at = mg, t + pacing * 0.75
        end
        if observed == t then return end
        observed = t
        direction_x, direction_y = nil, nil
        if mg:state() ~= Settings.game_states.gameplay then
            return
        end
        local s, current, wanted = mg:current_stage(), mg:frequency(), mg:target_frequency()
        if not s or not current or not wanted or wanted.x < Settings.frequency_width_min_scale
            or wanted.y < Settings.frequency_height_min_scale then return end
        if stage ~= s or target_x ~= wanted.x or target_y ~= wanted.y then
            if stage then ready_at = math.max(ready_at, t + pacing) end
            stage, target_x, target_y = s, wanted.x, wanted.y
        end
        if module.cancel_requested() then return end
        if not fresh_t and fresh(mg) then fresh_t = t end
        if pacing == 0 and predicting and not mg._is_server and s == 1 and not waiting and fresh(mg)
            and (plan_x ~= wanted.x or plan_y ~= wanted.y) then
            plan_x, plan_y = wanted.x, wanted.y
            local seed = start_seeds[mg]
            plan = seed ~= nil and predict(seed, wanted.x, wanted.y)
            ctx.mod:debug("Frequency plan: %s", plan and string.format("%.2f,%.2f then %.2f,%.2f", plan[1], plan[2],
                plan[3], plan[4]) or "none")
        end
        -- Stage-one failure sends only stage 1; other responses also replace the target.
        if waiting and stage_received and (target_received or stage_one_failed) then
            waiting = false
            waiting_since = nil
            ready_at = math.max(ready_at, t + pacing)
            if pipeline then
                if pipeline.failed then
                    predicting = false
                    ctx.mod:debug("Frequency pipeline: a receipt differed from the prediction, pipelining switched off")
                end
                pipeline = nil
            end
        end
        local dx, dy = target_x - current.x, target_y - current.y
        local strength = 1 - pacing * 0.55
        direction_x = math.abs(dx) <= margin and 0 or math.clamp(dx / (range_x * 0.2), -1, 1) * strength
        direction_y = math.abs(dy) <= margin and 0 or math.clamp(dy / (range_y * 0.2), -1, 1) * strength
    end

    function module.input(action, original, t, source)
        if source ~= "input_service" then return original end
        t = t or ctx.time()
        if not t or not game or game ~= ctx.active_minigame or not ctx.settings.enable_frequency_auto
            or game:is_completed() then return original end
        -- Never steer at speed 5, not even before the gameplay receipt: the target is submitted directly, and the
        -- server's frequency must stay as generated for the pipeline.
        if MOVE[action] and ctx.pacing("frequency_solve_speed") == 0 then return movement(action, 0, 0) end
        if game:state() ~= Settings.game_states.gameplay then return original end
        if PRIMARY[action] then
            local pipelined = plan and stage == 1 and not axis_moved and predicting and ctx.state_seen
            local ready = fresh(game) and not original and stage ~= nil and not waiting
                and not recovery_requested and t >= ready_at
            -- A late first frame would have run the input from before the session (authoritative_player_input_handler
            -- .lua:153-157): wait briefly for the server's report of that frame before pipelining.
            if ready and pipelined and ctx.session_frame_timely == nil and fresh_t and t < fresh_t + REPORT_WAIT then
                ready = false
            end
            local held = ctx.pulse(pulse, ready)
            if held and armed_frame ~= ctx.input_frame then
                armed_frame, armed_t = ctx.input_frame, t
                armed_stage, armed_x, armed_y = stage, target_x, target_y
                armed_plan = pipelined and ctx.session_frame_timely == true and plan or nil
            end
            return held
        elseif MOVE[action] then
            local sample = ctx.input_frame or t
            if move_t ~= sample then
                move_t, move_x, move_y = sample, nil, nil
                if direction_x then
                    if not fresh(game) or t < ready_at or waiting then
                        move_x, move_y = 0, 0
                    else
                        move_x, move_y = direction_x, direction_y
                    end
                end
            end
            if move_x then return movement(action, move_x, move_y) end
        end
        return original
    end

    function module.settings_changed(id)
        if id == "enable_frequency_auto" or id == "frequency_solve_speed" then module.reset("settings") end
    end

    function module.cancel_requested()
        if not game or game ~= ctx.active_minigame or not ctx.settings.enable_frequency_auto
            or game:is_completed() or game:state() ~= Settings.game_states.gameplay then return false end
        local t = ctx.time()
        if waiting_since and not (stage_received and (target_received or stage_one_failed))
            and t and t - waiting_since >= 2.5 then
            -- No transaction ID: an incomplete response cannot safely be retried.
            recovery_requested = true
        end
        return recovery_requested == true
    end

    local function authorized(mg)
        if recovery_requested or mg ~= game or not fresh(mg) or not ctx.session_valid(mg) or not ctx.settings.enable_frequency_auto
            or mg:is_completed() or mg:state() ~= Settings.game_states.gameplay then return false end
        local wanted = mg:target_frequency()
        return mg:current_stage() == armed_stage and wanted
            and wanted.x == armed_x and wanted.y == armed_y
    end

    ctx.mod:hook_safe("MinigameFrequency", "start", function(self, player)
        if ctx.is_local_player(player) then
            if openings[self] and openings[self].foreign then openings[self] = nil end
            opening(self).started = true
        elseif player or not ctx.session_valid(self) then
            openings[self] = { foreign = true }
        end
    end)
    ctx.mod:hook_safe("MinigameFrequency", "stop", function(self, is_automatic)
        -- A continuing argumentless receipt must not discard an outstanding test.
        if is_automatic ~= nil or not ctx.session_valid(self) then
            openings[self] = nil
            if self == game then module.reset("session_end") end
        end
    end)
    ctx.mod:hook_safe("MinigameFrequency", "set_current_stage", function(self, next_stage)
        if self._is_server == false then opening(self).stage = true end
        if self == game and waiting then
            if pipeline then
                -- Every test answers with exactly one stage receipt (minigame_frequency.lua:283).
                pipeline.receipts = pipeline.receipts + 1
                if next_stage ~= armed_stage + pipeline.receipts then pipeline.failed = true end
                if pipeline.receipts == 3 then stage_received, target_received = true, true end
                return
            end
            stage_one_failed = armed_stage == 1 and next_stage == 1
            stage_received = next_stage ~= armed_stage or stage_one_failed
        end
    end)
    ctx.mod:hook_safe("MinigameFrequency", "set_target_frequency", function(self, x, y)
        if self._is_server == false then opening(self).target = true end
        if self == game and waiting then
            if pipeline then
                pipeline.targets_seen = pipeline.targets_seen + 1
                local i = 2 * pipeline.targets_seen
                local tx, ty = pipeline.targets[i - 1], pipeline.targets[i]
                if not tx or math.abs(tx - x) >= MATCH or math.abs(ty - y) >= MATCH then pipeline.failed = true end
                return
            end
            target_received = true
        end
    end)
    -- The start seed of each setup (minigame_frequency.lua:79-92; received as rpc_minigame_sync_generate_board).
    ctx.mod:hook_safe("MinigameFrequency", "generate_board", function(self, seed)
        if self._is_server == false then start_seeds[self] = seed end
    end)
    -- A consumed direction changes the server's frequency; the client camera path does not reach the server.
    ctx.mod:hook_safe("MinigameFrequency", "on_axis_set", function(self, t, x, y)
        if self == game and ctx.consuming and (x ~= 0 or y ~= 0) then axis_moved = true end
    end)

    -- Base.action calls this only after consuming the rising edge. Safe hooks still run.
    ctx.mod:hook("MinigameFrequency", "on_action_pressed", function(func, self, t)
        if consuming and t == armed_t and authorized(self) then
            consumed = true
            return
        end
        return func(self, t)
    end)

    -- SoloPlay scores in an on_action_pressed safe hook; redirect that one test.
    ctx.mod:hook("MinigameFrequency", "test_frequency", function(func, self, x, y)
        if consuming and consumed and self == game and self._is_server == true then
            if scored or not authorized(self) then return end
            scored = true
            return func(self, armed_x, armed_y)
        end
        return func(self, x, y)
    end)

    local function finish_action(self, t, ...)
        local pressed = ...
        if pressed and consumed and not scored and authorized(self) then
            if self._is_server then
                self:test_frequency(armed_x, armed_y)
            else
                waiting, stage_received, target_received = true, false, false
                waiting_since, stage_one_failed = t, false
                self:send_rpc_to_server("rpc_minigame_sync_frequency_test_frequency", armed_x, armed_y)
                if armed_plan then
                    -- Reliable RPCs arrive in order; the server scores each against the target the one before set.
                    pipeline = { receipts = 0, targets_seen = 0, targets = armed_plan }
                    self:send_rpc_to_server("rpc_minigame_sync_frequency_test_frequency", armed_plan[1], armed_plan[2])
                    self:send_rpc_to_server("rpc_minigame_sync_frequency_test_frequency", armed_plan[3], armed_plan[4])
                    ctx.mod:debug("Frequency pipeline: three tests sent at %.3f", t)
                end
            end
        end
        local chain = pressed and consumed and self._is_server and ctx.pacing("frequency_solve_speed") == 0
        consuming = false
        armed_t = nil
        if chain then
            -- A local server replaces the target at once (minigame_frequency.lua:258-269): test each new one now.
            local expected = armed_stage + 1
            while self:current_stage() == expected and not self:is_completed()
                and self:state() == Settings.game_states.gameplay do
                local wanted = self:target_frequency()
                self:test_frequency(wanted.x, wanted.y)
                expected = expected + 1
            end
        end
        return ...
    end

    ctx.mod:hook("MinigameFrequency", "action", function(func, self, held, t)
        if not held or t ~= armed_t or armed_frame ~= ctx.input_frame or not authorized(self) then
            return func(self, held, t)
        end
        consuming, consumed, scored = true, false, false
        return finish_action(self, t, func(self, held, t))
    end)

    ctx.mod:hook_require("scripts/ui/views/scanner_display_view/minigame_frequency_view", function(View)
        ctx.mod:hook_safe(View, "draw_widgets", function(self, dt, t, input_service, ui_renderer)
            if not ctx.settings.enable_frequency_highlight or not ui_renderer then return end
            local ext = self._minigame_extension
            local mg = ext and ext:minigame(Settings.types.frequency)
            if not mg or mg ~= ctx.active_minigame or mg:is_completed() or mg:state() ~= Settings.game_states.gameplay then return end
            local current, wanted = mg:frequency(), mg:target_frequency()
            if not current or not wanted then return end
            if not arrows then
                arrows = {}
                for i = 1, 2 do
                    arrows[i] = UIWidget.init("tnb_frequency_" .. i, UIWidget.create_definition({{
                        pass_type = "rotated_texture", style_id = "arrow",
                        value = "content/ui/materials/buttons/arrow_01",
                        style = { hdr = true, angle = 0, color = { 255, 255, 165, 0 }, pivot = {} },
                    }}, "center_pivot", nil, { 120, 120 }))
                    arrows[i].offset[1] = i == 1 and -385 or -240
                    arrows[i].offset[2], arrows[i].offset[3] = 200, 7
                end
            end
            local dx, dy = wanted.x - current.x, wanted.y - current.y
            if math.abs(dx) > margin then
                arrows[1].style.arrow.angle = dx < 0 and math.pi or 0
                UIWidget.draw(arrows[1], ui_renderer)
            end
            if math.abs(dy) > margin then
                arrows[2].style.arrow.angle = dy > 0 and math.pi / 2 or -math.pi / 2
                UIWidget.draw(arrows[2], ui_renderer)
            end
        end)
    end)

    return module
end
