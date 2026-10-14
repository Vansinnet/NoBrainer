local MinigameSettings = require("scripts/settings/minigame/minigame_settings")

local SAMPLE_TIMEOUT = 0.25
local MAX_RTT = 0.5
local PREDICTION_HORIZON = MAX_RTT + SAMPLE_TIMEOUT + 0.1
local HISTORY_SIZE = 256
local RECOVERY_TIMEOUT = 1.2
local DEFAULT_TICK = 1 / 52
local clamp = math.clamp
local sqrt = math.sqrt
local abs = math.abs
local move_ratio = MinigameSettings.balance_move_ratio
local push_ratio = MinigameSettings.balance_push_ratio
local max_speed = MinigameSettings.balance_max_speed

return function(ctx)
    local module = {}
    local current
    local observed_at, sample_at, estimate_at
    local x, y, vx, vy = 0, 0, 0, 0
    local ready, recovering = false, false
    local recovery_until, blocked_key
    local rtt, next_ping, tick = 0, 0, DEFAULT_TICK
    local ping_ready = false
    local correction_at, apply_at, recorded_at
    local correction_x, correction_y = 0, 0
    local times, xs, ys = {}, {}, {}
    local head, count = 0, 0
    local stopped = true

    function module.reset(reason)
        current = nil
        observed_at, sample_at, estimate_at = nil, nil, nil
        x, y, vx, vy = 0, 0, 0, 0
        ready, recovery_until, blocked_key = false, nil, nil
        recovering = false
        rtt, next_ping, tick, ping_ready = 0, 0, DEFAULT_TICK, false
        correction_at, apply_at, recorded_at = nil, nil, nil
        correction_x, correction_y = 0, 0
        head, count, stopped = 0, 0, true
        table.clear(times)
        table.clear(xs)
        table.clear(ys)
    end

    local function outward(px, py)
        local distance = sqrt(px * px + py * py)
        if distance >= 1 then
            return 0, 0, distance
        end
        local power = (1 - distance) * push_ratio
        if distance <= 0.000001 then
            return power, 0, distance
        end
        return px / distance * power, py / distance * power, distance
    end

    local function record(t, cx, cy)
        if count > 0 then t = math.max(t, times[head]) end
        if count > 0 and times[head] == t then
            xs[head], ys[head] = cx, cy
            return
        end
        head = head % HISTORY_SIZE + 1
        count = math.min(count + 1, HISTORY_SIZE)
        times[head], xs[head], ys[head] = t, cx, cy
    end

    local function advance(px, py, sx, sy, from_t, to_t)
        local end_t = math.min(to_t, from_t + PREDICTION_HORIZON)
        local offset = count - 1
        local cx, cy = 0, 0
        -- Bound both prediction duration and integration work, even with bad timing.
        for _ = 1, 205 do
            if from_t >= end_t then
                break
            end
            local dt = math.min(end_t - from_t, tick)
            -- Walk the ordered ring once, rather than scanning it for every tick.
            while offset >= 0 do
                local index = (head - offset - 1) % HISTORY_SIZE + 1
                if times[index] > from_t then break end
                cx, cy = xs[index], ys[index]
                offset = offset - 1
            end
            sx, sy = sx - move_ratio * cx * dt, sy - move_ratio * cy * dt
            px, py = px + sx * dt, py + sy * dt
            local gx, gy, distance = outward(px, py)
            if distance > 1.02 then
                px, py, sx, sy = px / distance * 1.01, py / distance * 1.01, 0, 0
            else
                sx = clamp(sx + gx * dt, -max_speed, max_speed)
                sy = clamp(sy + gy * dt, -max_speed, max_speed)
            end
            from_t = from_t + dt
        end
        return px, py, sx, sy
    end

    local function network_timing(t)
        if t < next_ping then
            return
        end
        next_ping = t + 0.5
        local connection = Managers.connection
        local client = connection and connection:is_client()
        if connection and (client or connection:is_host()) then
            local rate = connection:tick_rate()
            if type(rate) == "number" and rate > 0 then
                tick = clamp(1 / rate, 1 / 240, 0.1)
            end
        end
        local measured = 0
        if client and not current._is_server then
            local host = connection:host()
            measured = host and Network.ping(host) or 0.075
            if type(measured) ~= "number" or measured ~= measured or measured < 0 then
                measured = 0.075
            end
        end
        measured = clamp(measured, 0, MAX_RTT)
        local previous = rtt
        rtt = ping_ready and rtt + (measured - rtt) * 0.2 or measured
        ping_ready = true
        if estimate_at then
            estimate_at = estimate_at - (rtt - previous) * 0.5
        end
        correction_at = nil
    end

    local function sample(px, py, t)
        if sample_at and t <= sample_at then
            return
        end
        local measurement_t = t - rtt * 0.5
        local dt = estimate_at and measurement_t - estimate_at or 0
        if not estimate_at or dt <= 0 or dt > SAMPLE_TIMEOUT then
            x, y, vx, vy = px, py, 0, 0
            ready = current._is_server
        elseif not ready then
            if dt < 1 / 240 then return end
            vx = clamp((px - x) / dt, -max_speed, max_speed)
            vy = clamp((py - y) / dt, -max_speed, max_speed)
            x, y, ready = px, py, true
            recovering = false
        else
            local predicted_x, predicted_y, predicted_vx, predicted_vy = advance(x, y, vx, vy, estimate_at, measurement_t)
            local dx, dy = px - predicted_x, py - predicted_y
            x, y = predicted_x + dx * 0.65, predicted_y + dy * 0.65
            vx = clamp(predicted_vx + dx * 0.20 / dt, -max_speed, max_speed)
            vy = clamp(predicted_vy + dy * 0.20 / dt, -max_speed, max_speed)
        end
        sample_at, estimate_at = t, measurement_t
        correction_at = nil
    end

    function module.observe(minigame, t)
        t = ctx.time()
        if minigame and blocked_key == tostring(minigame) then return end
        if recovering and t and t > recovery_until then
            module.reset("recovery_timeout")
            blocked_key = tostring(minigame)
            return
        end
        if not t or not ctx.settings.enable_balance or not minigame
            or minigame ~= ctx.active_minigame or minigame:is_completed()
            or minigame:state() ~= MinigameSettings.game_states.gameplay then
            module.reset("inactive")
            return
        end
        if current ~= minigame or observed_at and t < observed_at then
            module.reset("session")
            current = minigame
            recovery_until = t + RECOVERY_TIMEOUT
        end
        if observed_at == t then
            return
        end
        observed_at = t
        network_timing(t)
        if current._is_server then
            local position = current:position()
            sample(position.x, position.y, t)
        end
        if sample_at and t - sample_at > SAMPLE_TIMEOUT and not stopped then
            record(t + rtt * 0.5 + tick, 0, 0)
            stopped = true
            correction_at = nil
        end
    end

    -- RPC samples, not repeated UI reads, determine online observer freshness.
    ctx.mod:hook_require("scripts/extension_systems/minigame/minigames/minigame_balance", function(class)
        ctx.mod:hook_safe(class, "start", function(self, player)
            if ctx.is_local_player(player) and ctx.settings.enable_balance then
                module.reset("start")
                current = self
                local t = ctx.time()
                recovery_until = t and t + RECOVERY_TIMEOUT
            elseif player and self == current then
                module.reset("ownership_changed")
            end
        end)
        ctx.mod:hook_safe(class, "stop", function(self, ...)
            if self ~= current then return end
            local t = ctx.time()
            local ui = Managers.ui
            local deadline = recovery_until
            local recover = select("#", ...) == 0 and self._is_server == false
                and t and deadline and t <= deadline and ctx.session_valid(self)
                and ui and ui:view_active("scanner_display_view")
                and not self:is_completed()
                and self:state() == MinigameSettings.game_states.gameplay
                and self._minigame_unit and Unit.alive(self._minigame_unit)
            module.reset("stop")
            if recover then
                -- A late stop clears ownership, but must not reuse pre-stop velocity or input.
                current, recovery_until = self, deadline
                recovering = true
            else
                blocked_key = tostring(self)
            end
        end)
        ctx.mod:hook_safe(class, "set_position", function(self, px, py)
            if self ~= current or self ~= ctx.active_minigame or not ctx.settings.enable_balance
                or not ctx.session_valid(self) or self:is_completed()
                or self:state() ~= MinigameSettings.game_states.gameplay
                or not self._minigame_unit or not Unit.alive(self._minigame_unit) then
                return
            end
            local t = ctx.time()
            if t and (not recovering or t <= recovery_until) then
                network_timing(t)
                sample(px, py, t)
            end
        end)
    end)

    function module.input(action, original, t, source)
        local vector = action == "move" or action == "move_controller"
        local direction = action == "move_left" or action == "move_right"
            or action == "move_forward" or action == "move_backward"
        if not vector and not direction then
            return original
        end
        -- RPC receipts use gameplay time; the caller's fixed-step time can lag behind them.
        t = ctx.time()
        if not t or not current or current ~= ctx.active_minigame or not ctx.settings.enable_balance
            or not ready or not sample_at or t < sample_at or t - sample_at > SAMPLE_TIMEOUT
            or current:is_completed() or current:state() ~= MinigameSettings.game_states.gameplay
            or not current._minigame_unit or not Unit.alive(current._minigame_unit) then
            return original
        end
        if source ~= "input_service" and source ~= "player_unit_input" then
            return original
        end
        if correction_at ~= t then
            apply_at = t + rtt * 0.5 + tick
            if count > 0 then apply_at = math.max(apply_at, times[head]) end
            local px, py, sx, sy = advance(x, y, vx, vy, estimate_at, apply_at)
            local gx, gy, distance = outward(px, py)
            local cx = (gx + 12.25 * px + 7 * sx) / move_ratio
            local cy = (gy + 12.25 * py + 7 * sy) / move_ratio
            local radial_speed = distance > 0.000001 and (px * sx + py * sy) / distance or 0
            local worst_speed = math.max(radial_speed, 0) + MinigameSettings.balance_disrupt_power
            local braking_distance = worst_speed * (rtt + tick) + worst_speed * worst_speed / (2 * (move_ratio - push_ratio))
            if distance > 0.000001 and 1 - distance - braking_distance <= 0.02 then
                cx = abs(px) > 0.000001 and (px > 0 and 1 or -1) or 0
                cy = abs(py) > 0.000001 and (py > 0 and 1 or -1) or 0
            else
                cx, cy = cx * 0.35, cy * 0.35
            end
            correction_x, correction_y = clamp(cx, -1, 1), clamp(cy, -1, 1)
            correction_at = t
        end
        -- Online authority consumes serialized directions, not the local move read.
        local sent = source == "input_service" and direction
            or source == "player_unit_input" and action == "move" and current._is_server
        if sent then
            if recorded_at == t then
                times[head], xs[head], ys[head] = apply_at, correction_x, correction_y
            else
                record(apply_at, correction_x, correction_y)
            end
            recorded_at, stopped = t, false
        end
        if vector then
            return Vector3(-correction_x, correction_y, 0)
        elseif action == "move_left" then
            return math.max(correction_x, 0)
        elseif action == "move_right" then
            return math.max(-correction_x, 0)
        elseif action == "move_forward" then
            return math.max(correction_y, 0)
        end
        return math.max(-correction_y, 0)
    end

    function module.settings_changed(id)
        if id == "enable_balance" then module.reset("setting") end
    end

    return module
end
