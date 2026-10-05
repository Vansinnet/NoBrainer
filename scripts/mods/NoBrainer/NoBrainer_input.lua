local mod = get_mod("NoBrainer")
local S = mod._S

local Managers = Managers
local ScriptUnit = ScriptUnit
local Unit = Unit
local math_abs = math.abs
local math_max = math.max

local PRIMARY_HOLD_ACTIONS = {
	action_one_hold = true,
	interact_hold = true,
	interact_primary_hold = true,
	jump_held = true,
}
local MOVE_ACTIONS = {
	move = true,
	move_controller = true,
}
local DIRECTION_ACTIONS = {
	move_left = true,
	move_right = true,
	move_forward = true,
	move_backward = true,
}
local function _is_primary_hold_action(action)
	return PRIMARY_HOLD_ACTIONS[action] == true
end

local function _scan_action_relevant(action)
	return action == "action_one_pressed"
		or action == "action_one_released"
		or action == "action_one_hold"
end

local function _is_movement_action(action)
	return MOVE_ACTIONS[action] == true or DIRECTION_ACTIONS[action] == true
end

local function _minigame_view_active()
	local ui = Managers.ui
	if not ui then return false end
	return ui:view_active("scanner_display_view")
end

local function _frequency(action, result)
	if not _is_primary_hold_action(action) and not _is_movement_action(action) then return result end
	if not S("enable_frequency_auto") then return result end
	local freq = mod._freq
	if not freq or not freq.session_active or freq.timer <= 0 or not freq.active or not freq.gameplay or freq.completed then return result end
	if (mod._freq_startup_delay or 0) > 0 then return result end
	if not _minigame_view_active() then return result end

	local now = mod._time("gameplay")
	if not now then return result end

	if _is_primary_hold_action(action) then
		if mod._freq_release_until > now then
			return false
		end
		if mod._freq_press_until > now then
			return true
		end
		if result then return result end

		if mod._freq_try_submit and mod._freq_try_submit(now) then
			return true
		end

		return result
	end

	if MOVE_ACTIONS[action] then
		local dir = mod._freq_move_vec and mod._freq_move_vec()
		if not dir then return result end

		return dir
	end

	local dir = mod._freq_move_vec and mod._freq_move_vec()
	if not dir then return result end

	if action == "move_left"      and dir.x < -0.15 then return math_max(type(result) == "number" and result or 0, math_abs(dir.x)) end
	if action == "move_right"     and dir.x >  0.15 then return math_max(type(result) == "number" and result or 0, math_abs(dir.x)) end
	if action == "move_forward"   and dir.y >  0.15 then return math_max(type(result) == "number" and result or 0, math_abs(dir.y)) end
	if action == "move_backward"  and dir.y < -0.15 then return math_max(type(result) == "number" and result or 0, math_abs(dir.y)) end

	return result
end

local function _balance(action, result, source)
	if not _is_movement_action(action) then return result end
	if not S("enable_balance") then return result end
	local bal = mod._bal
	if not bal or not bal.active or bal.timer <= 0 or not bal.enabled then
		return result
	end
	if not _minigame_view_active() then
		return result
	end
	if not mod._bal_predictive_correction then return result end

	local record_command = source == "player_unit_input" and MOVE_ACTIONS[action]
	local correction_x, correction_y = mod._bal_predictive_correction(record_command)

	if correction_x == nil then return result end

	if MOVE_ACTIONS[action] then
		local x = correction_x and -correction_x or 0
		local y = correction_y or 0

		if x == 0 and y == 0 then
			return result
		end
		return Vector3(x, y, 0)
	end

	local v, current

	if correction_x and correction_x > 0 and action == "move_left" then
		v, current = correction_x, result
	elseif correction_x and correction_x < 0 and action == "move_right" then
		v, current = -correction_x, result
	elseif correction_y and correction_y > 0 and action == "move_forward" then
		v, current = correction_y, result
	elseif correction_y and correction_y < 0 and action == "move_backward" then
		v, current = -correction_y, result
	else
		return result
	end

	if v then
		local cur = type(current) == "number" and current or 0
		return math_max(cur, v)
	end
	return result
end

local scan_hold_duration = nil
local function _scan_hold_duration()
	if scan_hold_duration then return scan_hold_duration end

	local duration = 1
	local scanner = require("scripts/settings/equipment/weapon_templates/devices/scanner_equip")
	local actions = scanner and scanner.actions
	local action = actions and (actions.action_scan_confirm or actions.action_scan)
	local scan_settings = action and action.scan_settings

	if scan_settings and tonumber(scan_settings.confirm_time) then
		duration = tonumber(scan_settings.confirm_time)
	end

	scan_hold_duration = duration + 0.15
	return scan_hold_duration
end

local function _scan(action, result)
	if not _scan_action_relevant(action) then return result end
	if not S("enable_auto_scan") then return result end

	if mod._scan_holding then
		if action == "action_one_hold" then
			local now = mod._time("gameplay")
			if not now then
				return result
			end
			if now and now > mod._scan_hold_until then
				mod._scan_holding = false
				mod._scan_hold_until = 0
				mod._scan_hold_target = nil
				return result
			end
			return true
		end
		if action == "action_one_released" then
			return false
		end
		return result
	end

	local current_action = mod._current_action or ""
	local scan_active_action = current_action == "action_scan" or current_action == "action_scan_confirm"

	if not mod._scan_auto_pending then
		return result
	end

	if not scan_active_action then
		return result
	end

	if action == "action_one_pressed" then
		local scan = mod._scan_scanning_component and mod._scan_scanning_component()
		local target = scan and scan.scannable_unit
		if not target then
			return result
		end

		if not scan.line_of_sight then
			return result
		end

		if target and scan.line_of_sight then
			local scannable_ext = Unit.alive(target) and ScriptUnit.has_extension(target, "mission_objective_zone_scannable_system")
			if scannable_ext and scannable_ext:is_active() then
				local now = mod._time("gameplay")
				if not now then
					return result
				end
				mod._scan_auto_pending = false
				mod._scan_holding = true
				mod._scan_hold_target = target
				mod._scan_hold_until = now + _scan_hold_duration()
				mod._scan_retry_target = target
				mod._scan_retry_until = now + 0.3
				return true
			end
		end
	end
	return result
end

local function _any_minigame_active()
	local bal = mod._bal
	local freq = mod._freq

	return (freq and freq.session_active and freq.active and (freq.timer or 0) > 0)
		or mod._scan_holding
		or mod._scan_auto_pending
		or (bal and bal.active and bal.enabled and (bal.timer or 0) > 0)
end

local function _apply_route(fn, action, result, source)
	local next_result = fn(action, result, source)

	if next_result == nil then
		return result
	end

	return next_result
end

function mod._route_input(action, result, source)
	local r = result

	if not mod:is_enabled() then
		return r
	end

	if (action == "action_two_pressed" or action == "interact_pressed") and mod._ds_reroll_input then
		return _apply_route(mod._ds_reroll_input, action, r, source)
	end

	local primary_action = _is_primary_hold_action(action)
	local movement_action = _is_movement_action(action)
	local scan_action = _scan_action_relevant(action)

	if not primary_action and not movement_action and not scan_action then
		return r
	end

	if not _any_minigame_active() then
		return r
	end

	if primary_action then
		r = _apply_route(_frequency, action, r, source)
	end

	if movement_action then
		r = _apply_route(_frequency, action, r, source)
		r = _apply_route(_balance, action, r, source)
	end

	if scan_action then
		r = _apply_route(_scan, action, r, source)
	end

	return r
end

-- InputService._get is hooked in NoBrainer_core.lua, which calls mod._route_input first.
if rawget(CLASS.InputService, "_get_simulate") then
	mod:hook(CLASS.InputService, "_get_simulate", function(func, self, action)
		local r = func(self, action)
		local source = self and self.type == "Ingame" and "input_service" or "input_service_other"
		return mod._route_input(action, r, source)
	end)
end

mod:hook_require("scripts/extension_systems/input/player_unit_input_extension", function(PlayerUnitInputExtension)
	mod:hook(PlayerUnitInputExtension, "get", function(func, self, action)
		local r = func(self, action)
		local player = self and self._player

		if player and player.is_human_controlled and not player:is_human_controlled() then
			return r
		end

		return mod._route_input(action, r, "player_unit_input")
	end)
end)

return true
