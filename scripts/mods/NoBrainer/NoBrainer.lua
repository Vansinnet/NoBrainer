---@class NoBrainerMod: DMFMod
---@field _on_update? function[] # Callbacks registered through mod._reg("update", cb).
---@field _on_runtime_reset? function[] # Callbacks registered through mod._reg("runtime_reset", cb).
---@field _on_round_end? function[] # Callbacks registered through mod._reg("round_end", cb).
---@field _on_setting_changed? function[] # Callbacks registered through mod._reg("setting_changed", cb).
---@field _on_enabled? function[] # Callbacks registered through mod._reg("enabled", cb).
---@field _on_disabled? function[] # Callbacks registered through mod._reg("disabled", cb).
---@field _on_unload? function[] # Callbacks registered through mod._reg("unload", cb).
local mod = get_mod("NoBrainer")

local cache = {}

mod._S = function(k)
    if cache[k] == nil then
        cache[k] = mod:get(k)
    end

    return cache[k]
end

mod._clear_cache = function()
    for k in pairs(cache) do
        cache[k] = nil
    end
end

mod._time = function(clock)
    local time_manager = Managers.time
    local timer_name = clock or "gameplay"

    if not time_manager or not time_manager:has_timer(timer_name) then
        return nil
    end

    return time_manager:time(timer_name)
end
mod._N = function(k, fallback, min, max)
	local raw = mod._S(k)
	local val = tonumber(raw)

	if not val then
		mod:warning("NoBrainer: setting '%s' is %s (expected number), using fallback", k, type(raw))
		val = fallback or 0
	end

	if min and val < min then
        val = min
    end

	if max and val > max then
        val = max
    end

	return val
end
mod._speed_scale = function(id)
	local val = mod._N(id, 1, 1, 5)
	return (val - 1) / 4
end

mod._speed_pacing = function(id)
	return 1 - mod._speed_scale(id)
end

do
	local schema_setting = "_speed_schema_v2"
	local speed_settings = {
		expedition_solve_speed = 5,
		drill_solve_speed = 5,
		frequency_solve_speed = 2,
	}

	local function rounded_number(raw)
		local value = tonumber(raw)

		if not value or value ~= value or value == math.huge or value == -math.huge then
			return nil
		end

		return math.floor(value + 0.5)
	end

	local function clamp(value, low, high)
		return math.max(low, math.min(value, high))
	end

	local function migrate_speed(raw, old_default)
		if type(raw) == "string" then
			local legacy = string.lower(raw):match("^%s*(.-)%s*$")

			if legacy == "human" then return 1 end
			if legacy == "inhuman" then return 5 end
		end

		local old_speed = rounded_number(raw)

		if not old_speed then return 1 end

		old_speed = clamp(old_speed, 1, 10)

		if old_speed <= old_default then return 1 end

		local migrated = 1 + math.floor((old_speed - old_default) * 4 / (10 - old_default) + 0.5)
		return clamp(migrated, 1, 5)
	end

	if mod:get(schema_setting) ~= true then
		for id, old_default in pairs(speed_settings) do
			mod:set(id, migrate_speed(mod:get(id), old_default), false)
		end

		mod:set(schema_setting, true, false)
	else
		for id in pairs(speed_settings) do
			local raw = mod:get(id)
			local speed = rounded_number(raw)
			speed = speed and clamp(speed, 1, 5) or 1

			if raw ~= speed then
				mod:set(id, speed, false)
			end
		end
	end
end

local function _fire(list, ...)
	if type(list) ~= "table" then
        return
    end

	for _, cb in ipairs(list) do
		cb(...)
	end
end

-- A reload re-runs every module; start from empty callback lists.
for key in pairs(mod) do
    if type(key) == "string" and key:sub(1, 4) == "_on_" then
        mod[key] = nil
    end
end

mod._reg = function(ev, cb)
    mod["_on_" .. ev] = mod["_on_" .. ev] or {}
    mod["_on_" .. ev][#mod["_on_" .. ev] + 1] = cb
end

mod._is_local_minigame_player = function(player)
	local player_manager = Managers.player
	local local_player = player_manager and player_manager:local_player_safe(1)

	return player ~= nil and local_player ~= nil and player == local_player
end

local function _reset_runtime(reason)
	_fire(mod._on_runtime_reset, reason)
	_fire(mod._on_round_end, reason)
end

mod._exp = { timer = 0, active = false, gameplay = false, completed = false,
	cursor_x = nil, cursor_y = nil, target_x = nil, target_y = nil,
	dir_x = 0, dir_y = 0, on_target = false, stage = nil, key = nil }
mod._exp_press_until   = 0
mod._exp_release_until = 0
mod._exp_move_cooldown = 0
mod._exp_startup_delay = 0
mod._exp_submitted_stage = nil
mod._exp_submitted_until = 0
mod._exp_prev_cursor = nil
mod._drill = { timer = 0, active = false, gameplay = false, searching = false,
	cursor_x = nil, cursor_y = nil, target_x = nil, target_y = nil,
	dir_x = 0, dir_y = 0, search = 0, on_target = false, stage = nil, target_index = nil, key = nil }
mod._drill_cooldown      = 0
mod._drill_press_until   = 0
mod._drill_release_until = 0
mod._drill_move_cooldown = 0
mod._drill_startup_delay = 0
mod._drill_submit_ready_since = nil
mod._freq_startup_delay = 0
mod._freq = { timer = 0, active = false, gameplay = false, completed = false,
	current_x = nil, current_y = nil, target_x = nil, target_y = nil,
	dir_x = 0, dir_y = 0, on_target = false, stage = nil, key = nil }
mod._freq_cooldown      = 0
mod._freq_last_stage    = 0
mod._freq_reaction_until = 0
mod._freq_confirm_until  = 0
mod._freq_was_on_target  = false
mod._freq_press_until    = 0
mod._freq_release_until  = 0
mod._scan_auto_pending   = false
mod._scan_holding        = false
mod._scan_hold_until     = 0
mod._scan_cooldown       = 0
mod._scan_refresh_timer  = nil
mod._current_action      = ""
mod._ds = { timer = 0, active = false, completed = false, server = false,
	stage = nil, start_time = nil, target = nil, items_per_stage = nil, sweep_duration = nil, key = nil }
mod._bal = { timer = 0, enabled = false,
	x = 0, y = 0, vx = 0, vy = 0, dist = 0,
}

local mod_dir = "NoBrainer/scripts/mods/NoBrainer/"
local function _load(path)
	if not mod:io_dofile(mod_dir .. path) then
		mod:echo("NoBrainer: failed to load " .. path)
	end
end

for _, m in ipairs({ "scan", "balance", "frequency", "servo_skull" }) do
    _load("NoBrainer_minigame_" .. m)
end

_load("NoBrainer_decode_symbols_reroll")
_load("NoBrainer_input")
-- Decode Symbols, Decode Search and Drill: frame solvers loaded by the core.
_load("NoBrainer_core")

mod.update = function(dt)
    if mod:is_enabled() then
        _fire(mod._on_update, dt)
    end
end

mod.on_setting_changed = function(id)
    mod._clear_cache()

    _fire(mod._on_setting_changed, id)
end

mod.on_enabled = function()
    mod._clear_cache()
    _fire(mod._on_enabled)
end

mod.on_disabled = function()
    mod._clear_cache()
    _fire(mod._on_disabled)
    _reset_runtime("disabled")
end

mod.on_game_state_changed = function(st, name)
	if st == "exit" and name == "StateGameplay" then
        _reset_runtime("gameplay_exit")
    end
end
mod.on_unload = function(exit_game)
	_reset_runtime("unload")
	_fire(mod._on_unload, exit_game)
	mod._clear_cache()
end
