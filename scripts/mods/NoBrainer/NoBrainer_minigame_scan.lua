local mod = get_mod("NoBrainer")
local S = mod._S

local scannable_units = {}
local highlighted_units = {}
local SCAN_RETRY_DELAY = 0.3
local last_target = nil
local last_completed_target = nil
local cached_player_unit = nil
local cached_unit_data_ext = nil
local cached_weapon_action = nil
local cached_scanning = nil

local function _set_scannable_visuals(ext, outline, highlight)
    if not ext then return end

    local extension_manager = Managers.state and Managers.state.extension
    if not extension_manager then return end

    ext:set_scanning_outline(outline)
    ext:set_scanning_highlight(highlight)
end

local function _clear_component_cache()
	cached_player_unit = nil
	cached_unit_data_ext = nil
	cached_weapon_action = nil
	cached_scanning = nil
end

local function _local_scan_components()
	local player_manager = Managers.player
	local player = player_manager and player_manager:local_player_safe(1)
	local unit = player and player.player_unit

	if unit ~= cached_player_unit then
		_clear_component_cache()
		cached_player_unit = unit
	end

	if not player then return nil end
	if not unit then return nil end

	cached_unit_data_ext = cached_unit_data_ext or ScriptUnit.has_extension(unit, "unit_data_system")
	if not cached_unit_data_ext then return nil end

	cached_weapon_action = cached_weapon_action or cached_unit_data_ext:read_component("weapon_action")
	if not cached_weapon_action then return nil end

	return cached_unit_data_ext, cached_weapon_action, unit
end


local function _scanning_component(unit_data_ext)
	cached_scanning = cached_scanning or unit_data_ext:read_component("scanning")
	return cached_scanning
end

mod._scan_scanning_component = function()
	local unit_data_ext = _local_scan_components()
	return unit_data_ext and _scanning_component(unit_data_ext) or nil
end

local function _clear_highlights()
    for unit, _ in pairs(highlighted_units) do
        local ext = Unit.alive(unit) and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
        _set_scannable_visuals(ext, false, false)
    end

    table.clear(highlighted_units)
    table.clear(scannable_units)
end

local function _reset_scan_input_state()
    mod._scan_auto_pending = false
    mod._scan_holding = false
    mod._scan_hold_until = 0
    mod._scan_hold_target = nil
    mod._scan_cooldown = 0
    mod._scan_refresh_timer = nil
    mod._current_action = ""
    mod._scan_retry_target = nil
    mod._scan_retry_until = 0
    last_target = nil
    last_completed_target = nil
end

local function _reset_scan_state()
    _clear_highlights()
    _reset_scan_input_state()
	_clear_component_cache()
end

local function _refresh_highlights()
    if not S("enable_scan") then
        _clear_highlights()
        return
    end

    local mgr_ext = Managers.state and Managers.state.extension
    if not mgr_ext then
        _clear_highlights()
        return
    end
    local has_system = mgr_ext and (not mgr_ext.has_system or mgr_ext:has_system("mission_objective_zone_system"))
    if not has_system then
        _clear_highlights()
        return
    end
    local sys = has_system and mgr_ext:system("mission_objective_zone_system")

    if not sys then
        _clear_highlights()
        return
    end

	if not sys:any_active_scanning_zone() then
		_clear_highlights()
		return
	end

	local su = sys:scannable_units() or {}
    table.clear(scannable_units)
    for u in pairs(su) do scannable_units[u] = true end

    for unit, _ in pairs(highlighted_units) do
        if not scannable_units[unit] then
            local ext = Unit.alive(unit) and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
            _set_scannable_visuals(ext, false, false)
            highlighted_units[unit] = nil
        else
            local ext = Unit.alive(unit) and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
            if ext and not ext:is_active() then
                _set_scannable_visuals(ext, false, false)
                highlighted_units[unit] = nil
            elseif not ext then
                highlighted_units[unit] = nil
            end
        end
    end

    for unit, _ in pairs(scannable_units) do
        if not highlighted_units[unit] then
            local ext = Unit.alive(unit) and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
            if ext and ext:is_active() then
                _set_scannable_visuals(ext, true, true)
                highlighted_units[unit] = true
            end
        end
    end
end

mod:hook_safe("AuspexScanningEffects", "init", function(self)
	if not self or not self._is_local_unit then return end
    _refresh_highlights()
end)

mod:hook_safe("AuspexScanningEffects", "wield", function(self)
	if not self or not self._is_local_unit then return end
    _refresh_highlights()
end)

mod:hook_safe("AuspexScanningEffects", "unwield", function(self)
	if not self or not self._is_local_unit then return end
    _reset_scan_input_state()
    _refresh_highlights()
end)

mod:hook_safe("AuspexScanningEffects", "destroy", function(self)
	if not self or not self._is_local_unit then return end
    _reset_scan_input_state()
    _refresh_highlights()
end)

mod:hook_require("scripts/extension_systems/weapon/actions/action_scan_confirm", function(ActionScanConfirm)
    mod:hook_safe(ActionScanConfirm, "_bank_scannable_unit", function()
        last_completed_target = mod._scan_hold_target
    end)
end)


mod._reg("update", function(dt)
    if S("enable_scan") then
        mod._scan_refresh_timer = (mod._scan_refresh_timer or 0) + dt
        if mod._scan_refresh_timer > 1.0 then
            mod._scan_refresh_timer = 0
            _refresh_highlights()
        end
    end

    if not S("enable_auto_scan") then return end

    local unit_data_ext, wac = _local_scan_components()
    if not wac then
		return
	end

    local previous_action = mod._current_action
    local current_action = wac.current_action_name
    if previous_action == "action_scan_confirm" and current_action ~= "action_scan_confirm" then
        if not last_completed_target then
            -- An interrupted confirm delays only a retry of the same target (BetterBrainer 1.0.2).
            local now = mod._time("gameplay")
            if mod._scan_hold_target and now then
                mod._scan_retry_target = mod._scan_hold_target
                mod._scan_retry_until = math.max(mod._scan_retry_until or 0, now + SCAN_RETRY_DELAY)
            end
            last_target = nil
        end
        mod._scan_holding = false
        mod._scan_hold_until = 0
        mod._scan_hold_target = nil
    end

    mod._current_action = current_action

	if current_action == "action_scan" then
        if mod._scan_auto_pending then return end

        local scan = _scanning_component(unit_data_ext)
        if not scan then
            return
        end
        local target = scan.scannable_unit
        local los = scan.line_of_sight
		if target and last_completed_target and target ~= last_completed_target then
			last_completed_target = nil
		end
		local retry_wait = target ~= nil and target == mod._scan_retry_target
			and (mod._time("gameplay") or 0) < (mod._scan_retry_until or 0)
		if scan.is_active and target and los and target ~= last_target and target ~= last_completed_target
			and not retry_wait then
			mod._scan_auto_pending = true
			last_target = target
        end
        if not los then
            last_target = nil
        end
	elseif current_action ~= "action_scan_confirm" then
        last_target = nil
        if mod._scan_auto_pending then
            mod._scan_auto_pending = false
        end
    end
end)

mod._reg("setting_changed", function(id)
    if id == "enable_scan" or id == "enable_auto_scan" then
        _reset_scan_state()
    end
end)

mod._reg("disabled", function()
    _reset_scan_state()
end)

mod._reg("round_end", function()
    _reset_scan_state()
end)

mod._reg("unload", function()
    _reset_scan_state()
end)

return true
