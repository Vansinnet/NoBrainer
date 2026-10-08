---@class NoBrainerMod
local mod = get_mod("NoBrainer")
local S = mod._S

local MinigameSettings = require("scripts/settings/minigame/minigame_settings")

local math_abs = math.abs
local math_clamp = math.clamp
local math_sqrt = math.sqrt

local SAMPLE_TIMEOUT = 0.25
local PING_SAMPLE_INTERVAL = 0.5
local DEFAULT_TICK_RATE = 52
local DEFAULT_TICK_INTERVAL = 1 / DEFAULT_TICK_RATE
local MIN_RECOVERY_SAMPLE_INTERVAL = 1 / 240
local OBSERVER_ALPHA = 0.65
local OBSERVER_BETA = 0.20
local CONTROLLER_OMEGA = 3.5
local SAFETY_MARGIN = 0.02
local COMMAND_HISTORY_SIZE = 48
local PREDICTIVE_GAIN = 0.35
local BALANCE_RESTART_RECOVERY_TIMEOUT = 1.2

mod._bal = {
	timer    = 0,
	active   = false,
	enabled  = true,
	x = 0, y = 0,
	vx = 0, vy = 0,
	dist = 0,
	pending_sample = false,
	pending_x = 0, pending_y = 0,
	pending_time = nil,
	estimate_time = nil,
	estimate_x = 0, estimate_y = 0,
	estimate_vx = 0, estimate_vy = 0,
	observer_ready = false,
	network_samples = false,
	rtt = 0,
	rtt_samples = 0,
	ping_timer = 0,
	tick_interval = DEFAULT_TICK_INTERVAL,
	command_x = 0, command_y = 0,
	command_times = {}, command_xs = {}, command_ys = {},
	command_head = 0, command_count = 0,
	command_stopped = true,
	correction_time = nil,
	correction_apply_time = nil,
	command_recorded_time = nil,
	correction_x = 0, correction_y = 0,
	safety_active = false,
}

local st = mod._bal
local balance_active = false
local active_balance_key = nil
local _balance_cleanup
local balance_stopped_key = nil
local balance_stopped_until = 0
local balance_restart_key = nil
---@type number
local balance_restart_until = 0
local balance_restart_stop_seen = false
local balance_restart_stop_at = 0
local balance_restart_prev_x = nil
local balance_restart_prev_y = nil
local balance_restart_prev_at = nil
local balance_restart_sample_x = nil
local balance_restart_sample_y = nil
local balance_restart_sample_at = nil

local function _is_active_balance_mg(mg)
	return mg ~= nil and active_balance_key == tostring(mg)
end

local function _scanner_view_active()
	local ui = Managers.ui
	return ui and ui:view_active("scanner_display_view")
end

local function _reset_balance_tracking()
	st.timer = 0
	st.x, st.y = 0, 0
	st.vx, st.vy = 0, 0
	st.dist = 0
	st.pending_sample = false
	st.pending_x, st.pending_y = 0, 0
	st.pending_time = nil
	st.estimate_time = nil
	st.estimate_x, st.estimate_y = 0, 0
	st.estimate_vx, st.estimate_vy = 0, 0
	st.observer_ready = false
	st.network_samples = false
	st.rtt = 0
	st.rtt_samples = 0
	st.ping_timer = 0
	st.tick_interval = DEFAULT_TICK_INTERVAL
	st.command_x, st.command_y = 0, 0
	st.command_head, st.command_count = 0, 0
	table.clear(st.command_times)
	table.clear(st.command_xs)
	table.clear(st.command_ys)
	st.command_stopped = true
	st.correction_time = nil
	st.correction_apply_time = nil
	st.command_recorded_time = nil
	st.correction_x, st.correction_y = 0, 0
	st.safety_active = false
end

local function _initialize_balance_tracking(mg)
	local position = mg and mg.position and mg:position()
	if not position then return end

	local x, y = position.x, position.y
	local dist = math.sqrt(x * x + y * y)
	st.x, st.y = x, y
	st.dist = dist
	st.vx, st.vy = 0, 0
	st.estimate_x, st.estimate_y = x, y
	st.estimate_vx, st.estimate_vy = 0, 0
	st.estimate_time = mod._time("gameplay")
	st.observer_ready = st.estimate_time ~= nil
	st.timer = SAMPLE_TIMEOUT
end

local function _outward_acceleration(x, y)
	local dist = math_sqrt(x * x + y * y)

	if dist >= 1 then
		return 0, 0, dist
	end

	local power = (1 - dist) * MinigameSettings.balance_push_ratio

	if dist <= 0.000001 then
		return power, 0, dist
	end

	return x / dist * power, y / dist * power, dist
end

local function _record_command(apply_time, correction_x, correction_y)
	if not apply_time then return end

	local head = st.command_head % COMMAND_HISTORY_SIZE + 1
	st.command_head = head
	st.command_count = math.min(st.command_count + 1, COMMAND_HISTORY_SIZE)
	st.command_times[head] = apply_time
	st.command_xs[head] = correction_x
	st.command_ys[head] = correction_y
end

local function _commit_predictive_command(now, apply_time, correction_x, correction_y)
	_record_command(apply_time, correction_x, correction_y)
	st.command_x, st.command_y = correction_x, correction_y
	st.command_stopped = false
	st.command_recorded_time = now
end

local function _command_at(time)
	for offset = 0, st.command_count - 1 do
		local index = (st.command_head - offset - 1) % COMMAND_HISTORY_SIZE + 1

		if st.command_times[index] <= time then
			return st.command_xs[index], st.command_ys[index]
		end
	end

	return 0, 0
end

local function _advance_state(x, y, vx, vy, from_time, to_time, tick_interval)
	local current_time = from_time or 0
	local end_time = math.min(to_time or current_time, current_time + 0.35)
	local max_step = tick_interval or DEFAULT_TICK_INTERVAL

	while current_time < end_time do
		local dt = math.min(end_time - current_time, max_step)
		local correction_x, correction_y = _command_at(current_time)

		vx = vx - MinigameSettings.balance_move_ratio * correction_x * dt
		vy = vy - MinigameSettings.balance_move_ratio * correction_y * dt
		x = x + vx * dt
		y = y + vy * dt

		local gx, gy, dist = _outward_acceleration(x, y)

		if dist > 1.02 then
			x = x / dist * 1.01
			y = y / dist * 1.01
			vx, vy = 0, 0
		else
			vx = math_clamp(vx + gx * dt, -MinigameSettings.balance_max_speed, MinigameSettings.balance_max_speed)
			vy = math_clamp(vy + gy * dt, -MinigameSettings.balance_max_speed, MinigameSettings.balance_max_speed)
		end

		current_time = current_time + dt
	end

	return x, y, vx, vy
end


local function _queue_predictive_sample(x, y, network_sample)
	st.pending_x, st.pending_y = x, y
	st.pending_time = mod._time("gameplay")
	st.pending_sample = true
	st.network_samples = st.network_samples or network_sample == true
	st.timer = SAMPLE_TIMEOUT
end

local function _process_predictive_sample()
	if not st.pending_sample then return end

	local now = st.pending_time or mod._time("gameplay")
	local x, y = st.pending_x, st.pending_y
	st.pending_sample = false
	st.pending_time = nil
	st.x, st.y = x, y
	st.dist = math_sqrt(x * x + y * y)

	if not now then
		st.observer_ready = false
		return
	end

	local measurement_time = now - (st.rtt or 0) * 0.5
	local dt = st.estimate_time and measurement_time - st.estimate_time or 0

	if not st.observer_ready or dt <= 0 or dt > SAMPLE_TIMEOUT then
		st.estimate_x, st.estimate_y = x, y
		st.estimate_vx, st.estimate_vy = 0, 0
		st.observer_ready = true
	else
		local px, py, pvx, pvy = _advance_state(
			st.estimate_x,
			st.estimate_y,
			st.estimate_vx,
			st.estimate_vy,
			st.estimate_time,
			measurement_time,
			st.tick_interval
		)
		local residual_x = x - px
		local residual_y = y - py

		st.estimate_x = px + residual_x * OBSERVER_ALPHA
		st.estimate_y = py + residual_y * OBSERVER_ALPHA
		st.estimate_vx = math_clamp(pvx + residual_x * OBSERVER_BETA / dt, -MinigameSettings.balance_max_speed, MinigameSettings.balance_max_speed)
		st.estimate_vy = math_clamp(pvy + residual_y * OBSERVER_BETA / dt, -MinigameSettings.balance_max_speed, MinigameSettings.balance_max_speed)
	end

	st.estimate_time = measurement_time
	st.vx, st.vy = st.estimate_vx, st.estimate_vy
	st.correction_time = nil
end

local function _update_network_timing(dt)
	st.ping_timer = st.ping_timer - dt

	if st.ping_timer > 0 then return end

	st.ping_timer = PING_SAMPLE_INTERVAL

	local connection = Managers.connection
	local tick_rate = connection and connection.tick_rate and connection:tick_rate()

	if type(tick_rate) == "number" and tick_rate > 0 then
		st.tick_interval = 1 / tick_rate
	end

	local host = connection and connection.host and connection:host()
	local rtt

	local network = rawget(_G, "Network")

	if host and network and network.ping then
		rtt = network.ping(host)
	end

	local fallback = type(rtt) ~= "number" or rtt < 0

	if fallback then
		local is_client = connection and connection.is_client and connection:is_client()
		rtt = is_client and 0.075 or 0
	end

	rtt = math_clamp(rtt, 0, 0.25)

	local previous_rtt = st.rtt

	if st.rtt_samples == 0 then
		st.rtt = rtt
	else
		st.rtt = st.rtt + (rtt - st.rtt) * 0.2
	end

	if st.estimate_time then
		st.estimate_time = st.estimate_time - (st.rtt - previous_rtt) * 0.5
	end

	st.rtt_samples = st.rtt_samples + 1
	st.correction_time = nil
end

mod:hook_safe("MinigameBalanceView", "_update_cursor", function(self)
	if not S("enable_balance") then
		return
	end
	local ext = self._minigame_extension
	local mg = ext and ext:minigame(MinigameSettings.types.balance)
	if not mg then
		return
	end

	if mg.is_completed and mg:is_completed() then
		return
	end
	local state = mg.state and mg:state()
	if state and state ~= MinigameSettings.game_states.gameplay then
		return
	end

	local p = mg:position()

	if mg._is_server and _is_active_balance_mg(mg) and not st.network_samples then
		_queue_predictive_sample(p.x, p.y, false)
	end

	return
end)

mod:hook_safe("MinigameBalance", "set_position", function(self, x, y)
	if balance_active and _is_active_balance_mg(self) then
		_queue_predictive_sample(x, y, true)
	elseif balance_restart_key == tostring(self) and balance_restart_stop_seen then
		local now = mod._time("gameplay")
		if now and now >= balance_restart_stop_at and now <= balance_restart_until then
			balance_restart_prev_x = balance_restart_sample_x
			balance_restart_prev_y = balance_restart_sample_y
			balance_restart_prev_at = balance_restart_sample_at
			balance_restart_sample_x = x
			balance_restart_sample_y = y
			balance_restart_sample_at = now
		end
	end
end)

local function on_update(dt)
	if not balance_active then return end

	_update_network_timing(dt)
	_process_predictive_sample()

	if st.timer > 0 then
		st.timer = st.timer - dt
	end

	if st.timer <= 0 then
		if not st.command_stopped then
			local now = mod._time("gameplay")
			local apply_time = now and now + (st.rtt or 0) * 0.5 + (st.tick_interval or DEFAULT_TICK_INTERVAL)

			_record_command(apply_time, 0, 0)
			st.command_x, st.command_y = 0, 0
			st.command_stopped = true
			st.correction_time = nil
		end

		if st.safety_active then
			st.safety_active = false
		end
	end

end

local function _arm_balance_session(mg, restart_until, previous_x, previous_y, previous_at, sample_x, sample_y, sample_at)
	_reset_balance_tracking()
	balance_active = true
	active_balance_key = tostring(mg)
	st.active = true
	st.enabled = true
	balance_stopped_key = nil
	balance_stopped_until = 0
	balance_restart_key = nil
	balance_restart_until = restart_until or 0
	balance_restart_stop_seen = false
	balance_restart_stop_at = 0
	balance_restart_prev_x = nil
	balance_restart_prev_y = nil
	balance_restart_prev_at = nil
	balance_restart_sample_x = nil
	balance_restart_sample_y = nil
	balance_restart_sample_at = nil
	local sample_dt = previous_at and sample_at and sample_at - previous_at
	if sample_dt and sample_dt >= MIN_RECOVERY_SAMPLE_INTERVAL and sample_dt <= SAMPLE_TIMEOUT then
		_update_network_timing(0)
		local velocity_x = math_clamp((sample_x - previous_x) / sample_dt, -MinigameSettings.balance_max_speed, MinigameSettings.balance_max_speed)
		local velocity_y = math_clamp((sample_y - previous_y) / sample_dt, -MinigameSettings.balance_max_speed, MinigameSettings.balance_max_speed)

		st.x, st.y = sample_x, sample_y
		st.vx, st.vy = velocity_x, velocity_y
		st.dist = math_sqrt(sample_x * sample_x + sample_y * sample_y)
		st.estimate_x, st.estimate_y = sample_x, sample_y
		st.estimate_vx, st.estimate_vy = velocity_x, velocity_y
		st.estimate_time = sample_at - (st.rtt or 0) * 0.5
		st.observer_ready = true
		st.network_samples = true
		st.timer = SAMPLE_TIMEOUT
	else
		_initialize_balance_tracking(mg)
		_update_network_timing(0)
	end
end

mod:hook_safe("MinigameBalance", "start", function(self, player)
	if not mod._is_local_minigame_player(player) then
		if balance_active and _is_active_balance_mg(self)
			or balance_restart_key and balance_restart_key == tostring(self)
			or balance_stopped_key and balance_stopped_key == tostring(self)
		then
			_balance_cleanup()
		end
		return
	end

	if not S("enable_balance") then
		return
	end

	local now = mod._time("gameplay")
	local quick_restart = self._is_server ~= true
		and now ~= nil
		and balance_stopped_key == tostring(self)
		and now <= balance_stopped_until
	local restart_until = quick_restart and now + BALANCE_RESTART_RECOVERY_TIMEOUT or 0

	if quick_restart then
		_balance_cleanup()
		balance_restart_key = tostring(self)
		balance_restart_until = restart_until
	else
		_arm_balance_session(self, restart_until)
	end
end)

_balance_cleanup = function()
	balance_active = false
	active_balance_key = nil
	balance_stopped_key = nil
	balance_stopped_until = 0
	balance_restart_key = nil
	balance_restart_until = 0
	balance_restart_stop_seen = false
	balance_restart_stop_at = 0
	balance_restart_prev_x = nil
	balance_restart_prev_y = nil
	balance_restart_prev_at = nil
	balance_restart_sample_x = nil
	balance_restart_sample_y = nil
	balance_restart_sample_at = nil
	st.active = false
	_reset_balance_tracking()
end

mod:hook_safe("MinigameBalance", "stop", function(self, ...)
	local key = tostring(self)
	local active = _is_active_balance_mg(self)
	local player = select(1, ...)
	local arg_count = select("#", ...)
	local now = mod._time("gameplay")
	local local_stop = arg_count > 0 and mod._is_local_minigame_player(player)
	local stale_stop_before_restart = arg_count == 0
		and not active
		and self._is_server ~= true
		and balance_stopped_key == key
	local recoverable_restart = (active or balance_restart_key == key)
		and arg_count == 0
		and self._is_server ~= true
		and not (self.is_completed and self:is_completed())
		and now ~= nil
		and now <= balance_restart_until
	local restart_until = balance_restart_until

	if active or balance_restart_key == key then
		_balance_cleanup()
	end

	if local_stop and self._is_server ~= true and now then
		balance_stopped_key = key
		balance_stopped_until = now + BALANCE_RESTART_RECOVERY_TIMEOUT
	elseif stale_stop_before_restart then
		balance_stopped_key = nil
		balance_stopped_until = 0
	elseif recoverable_restart then
		---@cast now number
		balance_restart_key = key
		balance_restart_until = restart_until
		balance_restart_stop_seen = true
		balance_restart_stop_at = now
	end
end)
mod:hook_safe("MinigameBalance", "complete", function(self)
	if _is_active_balance_mg(self) or balance_restart_key == tostring(self) then
		_balance_cleanup()
	end
end)

function mod._bal_rearm_from_state(state, t)
	if not balance_restart_key then return end

	local now = t or mod._time("gameplay")
	if not now or now > balance_restart_until then
		_balance_cleanup()
		return
	end
	if balance_active or not S("enable_balance") then return end
	if not balance_restart_stop_seen then return end

	local mg = state and state._minigame
	local player = state and state._player
	if not mg or tostring(mg) ~= balance_restart_key then return end
	if mg._is_server == true or not mod._is_local_minigame_player(player) or not _scanner_view_active() then return end
	if mg.is_completed and mg:is_completed() then return end
	local game_state = mg.state and mg:state()
	if game_state and game_state ~= MinigameSettings.game_states.gameplay then return end
	local unit = mg._minigame_unit
	if not unit or not Unit.alive(unit) then return end
	if not balance_restart_prev_at or not balance_restart_sample_at then return end
	local sample_dt = balance_restart_sample_at - balance_restart_prev_at
	if sample_dt < MIN_RECOVERY_SAMPLE_INTERVAL or sample_dt > SAMPLE_TIMEOUT then return end
	if now - balance_restart_sample_at > SAMPLE_TIMEOUT then return end

	local restart_until = balance_restart_until
	_arm_balance_session(
		mg,
		restart_until,
		balance_restart_prev_x,
		balance_restart_prev_y,
		balance_restart_prev_at,
		balance_restart_sample_x,
		balance_restart_sample_y,
		balance_restart_sample_at
	)
end

local function on_setting(id)
	if id == "enable_balance" and not S("enable_balance") then _balance_cleanup() end
end
local function on_enabled()
	st.enabled = true
end
local function on_disabled()
	_balance_cleanup()
	st.enabled = false
end
local function on_round_end()
	_balance_cleanup()
end
local function on_unload()
	_balance_cleanup()
end

mod._reg("update", on_update)
mod._reg("setting_changed", on_setting)
mod._reg("enabled", on_enabled)
mod._reg("disabled", on_disabled)
mod._reg("round_end", on_round_end)
mod._reg("unload", on_unload)

function mod._bal_predictive_correction(record_command)
	if not st.observer_ready then return nil end

	local now = mod._time("gameplay")

	if now and st.correction_time == now then
		if record_command and st.command_recorded_time ~= now then
			_commit_predictive_command(now, st.correction_apply_time, st.correction_x, st.correction_y)
		end

		return st.correction_x, st.correction_y
	end

	if not now or not st.estimate_time then return nil end

	local apply_time = now + (st.rtt or 0) * 0.5 + (st.tick_interval or DEFAULT_TICK_INTERVAL)
	local px, py, pvx, pvy = _advance_state(
		st.estimate_x,
		st.estimate_y,
		st.estimate_vx,
		st.estimate_vy,
		st.estimate_time,
		apply_time,
		st.tick_interval
	)
	local gx, gy, dist = _outward_acceleration(px, py)
	local kp = CONTROLLER_OMEGA * CONTROLLER_OMEGA
	local kd = 2 * CONTROLLER_OMEGA
	local move_ratio = MinigameSettings.balance_move_ratio
	local correction_x = (gx + kp * px + kd * pvx) / move_ratio
	local correction_y = (gy + kp * py + kd * pvy) / move_ratio
	local radial_speed = dist > 0.000001 and (px * pvx + py * pvy) / dist or 0
	local inward_acceleration = move_ratio - MinigameSettings.balance_push_ratio
	local response_delay = (st.rtt or 0) + (st.tick_interval or DEFAULT_TICK_INTERVAL)
	local disruption = MinigameSettings.balance_disrupt_power
	local worst_outward_speed = math.max(radial_speed, 0) + disruption
	local safety_distance = worst_outward_speed * response_delay + worst_outward_speed * worst_outward_speed / (2 * inward_acceleration)
	local safety_headroom = 1 - dist - safety_distance
	local safety_active = dist > 0.000001 and safety_headroom <= SAFETY_MARGIN

	if safety_active then
		correction_x = math_abs(px) > 0.000001 and (px > 0 and 1 or -1) or 0
		correction_y = math_abs(py) > 0.000001 and (py > 0 and 1 or -1) or 0
	else
		correction_x = correction_x * PREDICTIVE_GAIN
		correction_y = correction_y * PREDICTIVE_GAIN
	end

	correction_x = math_clamp(correction_x, -1, 1)
	correction_y = math_clamp(correction_y, -1, 1)
	st.correction_time = now
	st.correction_apply_time = apply_time
	st.correction_x, st.correction_y = correction_x, correction_y
	st.safety_active = safety_active

	if record_command then
		_commit_predictive_command(now, apply_time, correction_x, correction_y)
	end

	return correction_x, correction_y
end

return true
