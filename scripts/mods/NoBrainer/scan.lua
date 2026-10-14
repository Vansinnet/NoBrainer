local Scanner = require("scripts/settings/equipment/weapon_templates/devices/scanner_equip")
local HOLD_DURATION = Scanner.actions.action_scan_confirm.scan_settings.confirm_time + 0.15
local ACK_TIMEOUT = 1

return function(ctx)
    local module = {}
    local marked = {}
    local next_refresh = 0
    local player_unit, weapon_action, scanning
    local hold_target, pending_target, retry_target
    local ack_until = 0
    local pressed_at, hold_until, retry_at = nil, 0, 0
    local confirming = false

    local function clear_input()
        hold_target, pending_target, retry_target, pressed_at = nil, nil, nil, nil
        ack_until = 0
        hold_until, retry_at, confirming = 0, 0, false
    end

    local function release_marker(unit, extension)
        local requested = marked[unit]
        -- Remove ownership before replay, including while hooks remain enabled on unload.
        marked[unit] = nil
        if extension then
            extension:set_scanning_outline(requested.outline)
            extension:set_scanning_highlight(requested.highlight)
        end
    end

    local function clear_markers()
        local extensions = Managers.state and Managers.state.extension
        for unit in pairs(marked) do
            local extension = extensions and Unit.alive(unit)
                and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
            release_marker(unit, extension)
        end
    end

    function module.reset(reason)
        clear_markers()
        clear_input()
        player_unit, weapon_action, scanning = nil, nil, nil
        next_refresh = 0
    end

    local function components()
        local players = Managers.player
        local player = players and players:local_player_safe(1)
        local unit = player and ctx.is_local_player(player) and player.player_unit
        if not unit or not Unit.alive(unit) then
            clear_input()
            player_unit, weapon_action, scanning = nil, nil, nil
            return false
        end
        if player_unit ~= unit then
            clear_input()
            player_unit, weapon_action, scanning = unit, nil, nil
        end
        if not weapon_action then
            local data = ScriptUnit.has_extension(unit, "unit_data_system")
            if not data then
                return false
            end
            weapon_action = data:read_component("weapon_action")
            scanning = data:read_component("scanning")
        end
        return weapon_action ~= nil and scanning ~= nil
    end

    local function eligible_target()
        if not scanning.is_active or not scanning.line_of_sight then
            return nil
        end
        local target = scanning.scannable_unit
        local extension = target and Unit.alive(target)
            and ScriptUnit.has_extension(target, "mission_objective_zone_scannable_system")
        if extension and extension:is_active() then
            return target
        end
    end

    local function refresh_markers()
        local extensions = Managers.state and Managers.state.extension
        local system = extensions and extensions:has_system("mission_objective_zone_system")
            and extensions:system("mission_objective_zone_system")
        if not ctx.settings.enable_scan or not system or not system:any_active_scanning_zone() then
            clear_markers()
            return
        end
        -- scannable_units() returns shared scratch storage; never retain it.
        local units = system:scannable_units()
        for unit in pairs(marked) do
            local extension = Unit.alive(unit) and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
            if not units[unit] or not extension or not extension:is_active() then
                release_marker(unit, extension)
            end
        end
        for unit in pairs(units) do
            local extension = not marked[unit] and Unit.alive(unit)
                and ScriptUnit.has_extension(unit, "mission_objective_zone_scannable_system")
            if extension and extension:is_active() then
                -- The engine's field names are reversed relative to its public setters.
                local requested = { outline = extension._has_highlight, highlight = extension._has_outline }
                extension:set_scanning_outline(true)
                extension:set_scanning_highlight(true)
                marked[unit] = requested
            end
        end
    end

    function module.update(dt, t)
        if not t then
            return
        end
        if ctx.settings.enable_scan and t >= next_refresh then
            next_refresh = t + 1
            refresh_markers()
        end
        if not ctx.settings.enable_auto_scan or not components() then
            return
        end
        local action = weapon_action.current_action_name
        if action ~= "action_scan" and action ~= "action_scan_confirm" then
            clear_input()
            return
        end
        if hold_target then
            if action == "action_scan_confirm" then
                confirming = true
            end
            if eligible_target() ~= hold_target or t > hold_until or confirming and action ~= "action_scan_confirm" then
                retry_target = hold_target
                hold_target, pressed_at, confirming = nil, nil, false
                retry_at = math.max(retry_at, t + 0.3)
            end
        end
        if pending_target then
            local extension = Unit.alive(pending_target)
                and ScriptUnit.has_extension(pending_target, "mission_objective_zone_scannable_system")
            if t >= ack_until or not extension or not extension:is_active() then
                pending_target, ack_until = nil, 0
            end
        end
    end

    function module.input(action, original, t, source)
        if action ~= "action_one_pressed" and action ~= "action_one_hold" and action ~= "action_one_released" then
            return original
        end
        if not t or not ctx.settings.enable_auto_scan or ctx.active_minigame
            or source ~= "input_service" and source ~= "player_unit_input" or not components() then
            return original
        end
        local current_action = weapon_action.current_action_name
        if current_action ~= "action_scan" and current_action ~= "action_scan_confirm" then
            clear_input()
            return original
        end
        local target = eligible_target()
        if hold_target and (hold_target ~= target or t > hold_until) then
            retry_target = hold_target
            hold_target, pressed_at, confirming = nil, nil, false
            retry_at = t + 0.3
        end
        if pending_target and t >= ack_until then
            pending_target, ack_until = nil, 0
        end
        if not target or target == pending_target then
            return original
        end
        if not hold_target then
            -- Only the service press enters the serialized input stream.
            if source ~= "input_service" or action ~= "action_one_pressed"
                or current_action ~= "action_scan" or target == retry_target and t < retry_at then
                return original
            end
            hold_target, pressed_at = target, t
            retry_target = target
            hold_until, retry_at = t + HOLD_DURATION, t + 0.3
        end
        if action == "action_one_hold" then
            return true
        elseif action == "action_one_released" then
            return false
        elseif pressed_at == t then
            return true
        end
        return original
    end

    function module.settings_changed(id)
        if id == "enable_scan" or id == "enable_auto_scan" then
            module.reset("settings")
        end
    end

    ctx.mod:hook_require("scripts/extension_systems/weapon/actions/action_scan_confirm", function(class)
        ctx.mod:hook(class, "_bank_scannable_unit", function(func, self)
            -- The original clears the component, including on the predicting client.
            local target = self._scanning_compomnent.scannable_unit
            if target and ctx.settings.enable_auto_scan and ctx.is_local_player(self._player) and target == hold_target then
                -- Prediction is not an acknowledgement; only replicated inactivity rules out a retry.
                local t = ctx.time()
                pending_target = t and target or nil
                ack_until = t and t + ACK_TIMEOUT or 0
                hold_target, pressed_at, confirming = nil, nil, false
            end
            return func(self)
        end)
    end)

    ctx.mod:hook_require("scripts/extension_systems/mission_objective_zone_scannable/mission_objective_zone_scannable_extension", function(class)
        -- The server deactivates a scannable once it banked the scan (mission_objective_zone_scan_extension.lua:108-109);
        -- clients get the same call from rpc_mission_objective_zone_scannable_set_active. Release the marker right
        -- then: never on the client's predicted confirm, never a refresh interval later.
        ctx.mod:hook_safe(class, "set_active", function(self, active)
            if not active and marked[self._unit] then
                release_marker(self._unit, self)
            end
        end)
        ctx.mod:hook(class, "set_scanning_outline", function(func, self, active)
            local requested = marked[self._unit]
            if requested then
                requested.outline = active
                if ctx.settings.enable_scan and self:is_active() then
                    active = true
                end
            end
            return func(self, active)
        end)
        ctx.mod:hook(class, "set_scanning_highlight", function(func, self, active)
            local requested = marked[self._unit]
            if requested then
                requested.highlight = active
                if ctx.settings.enable_scan and self:is_active() then
                    active = true
                end
            end
            return func(self, active)
        end)
    end)

    ctx.mod:hook_require("scripts/extension_systems/visual_loadout/wieldable_slot_scripts/auspex_scanning_effects", function(class)
        local function equipment_changed(self)
            if self._is_local_unit then
                clear_input()
                next_refresh = 0
            end
        end
        ctx.mod:hook_safe(class, "init", equipment_changed)
        ctx.mod:hook_safe(class, "wield", equipment_changed)
        ctx.mod:hook_safe(class, "unwield", equipment_changed)
        ctx.mod:hook_safe(class, "destroy", equipment_changed)
    end)

    return module
end
