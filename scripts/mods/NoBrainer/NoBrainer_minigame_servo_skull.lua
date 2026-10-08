---@class NoBrainerMod
local mod = get_mod("NoBrainer")

local CompanionServoSkullSettings = require("scripts/settings/companion/companion_servo_skull_settings")
local SpecialRulesSettings = require("scripts/settings/ability/special_rules_settings")

local CHECK_INTERVAL = 0.05
local ORDER_RETRY_DELAY = 1
local ORDER_CONFIRM_TIMEOUT = 2
local COMPANION_HACK_TAG = "hacking_over_here_companion"
local HACKING_STATE = CompanionServoSkullSettings.STATES.hacking
local HACKING_SPECIAL_RULE = SpecialRulesSettings.special_rules.cryptic_servo_skull_hack
local LINE_OF_SIGHT_FILTER = "filter_interactable_line_of_sight_check"
local LINE_OF_SIGHT_TARGET_TOLERANCE = 0.25

local next_check = 0
local next_order_at = 0
local attempt_state = {
	phase = "idle",
	target_unit = nil,
	sent_at = nil,
	saw_hacking_state = false,
}

local function active_hack_order(smart_tag_system, player_unit)
	for _, tag in pairs(smart_tag_system._all_tags) do
		local template = tag:template()

		if template and template.name == COMPANION_HACK_TAG and tag:tagger_unit() == player_unit then
			return tag
		end
	end
end

local function servo_skull_state(player_unit)
	local companion_spawner_extension = ScriptUnit.has_extension(player_unit, "companion_spawner_system")
	local companion_unit = companion_spawner_extension and companion_spawner_extension:spawned_unit_lookup(HACKING_SPECIAL_RULE)
	local game_session_manager = Managers.state and Managers.state.game_session
	local unit_spawner = Managers.state and Managers.state.unit_spawner

	if not companion_unit or not Unit.alive(companion_unit) or not game_session_manager or not unit_spawner then
		return nil
	end

	local game_session = game_session_manager:game_session()
	local game_object_id = unit_spawner:game_object_id(companion_unit)

	if not game_object_id or not GameSession.game_object_exists(game_session, game_object_id) then
		return nil
	end

	return GameSession.game_object_field(game_session, game_object_id, "state")
end

local function has_line_of_sight(physics_world, from_position, to_position)
	if not physics_world or not from_position or not to_position then
		return false
	end

	local offset = to_position - from_position
	local distance = Vector3.length(offset)

	if distance <= LINE_OF_SIGHT_TARGET_TOLERANCE then
		return true
	end

	local direction = Vector3.normalize(offset)
	local hit, _, hit_distance = PhysicsWorld.raycast(physics_world, from_position, direction, distance, "closest", "collision_filter", LINE_OF_SIGHT_FILTER)

	return not hit or hit_distance >= distance - LINE_OF_SIGHT_TARGET_TOLERANCE
end

local function nearest_hack_target(smart_tag_system, player_unit, player_position, command_range_sq, require_line_of_sight, physics_world, line_of_sight_origin)
	local nearest_unit
	local nearest_distance_sq = command_range_sq

	for unit, extension in pairs(smart_tag_system._unit_extension_data) do
		if unit ~= player_unit and Unit.alive(unit) and extension._target_type == "hack" then
			local template = extension:contextual_tag_template(player_unit, true)

			if template and template.name == COMPANION_HACK_TAG then
				local target_position = Unit.world_position(unit, 1)
				local distance_sq = Vector3.distance_squared(player_position, target_position)

				if distance_sq <= nearest_distance_sq then
					local visible = true

					if require_line_of_sight then
						local target_actor = extension:target_actor()
						local line_of_sight_target = target_actor and Actor.position(target_actor) or target_position
						visible = has_line_of_sight(physics_world, line_of_sight_origin, line_of_sight_target)
					end

					if visible then
						nearest_unit = unit
						nearest_distance_sq = distance_sq
					end
				end
			end
		end
	end

	return nearest_unit
end

local function clear_attempt()
	attempt_state.phase = "idle"
	attempt_state.target_unit = nil
	attempt_state.sent_at = nil
	attempt_state.saw_hacking_state = false
end

local function update_attempt(t, active_tag, state)
	if attempt_state.phase == "sent" then
		if active_tag and active_tag:target_unit() == attempt_state.target_unit then
			attempt_state.phase = "confirmed"
		elseif t - attempt_state.sent_at >= ORDER_CONFIRM_TIMEOUT then
			clear_attempt()
			next_order_at = t + ORDER_RETRY_DELAY
		end
	end

	if attempt_state.phase ~= "idle" and state == HACKING_STATE then
		attempt_state.saw_hacking_state = true
	end

	if attempt_state.phase == "confirmed" and not attempt_state.saw_hacking_state
		and (not active_tag or active_tag:target_unit() ~= attempt_state.target_unit)
		and t - attempt_state.sent_at >= ORDER_CONFIRM_TIMEOUT then
		clear_attempt()
		next_order_at = t + ORDER_RETRY_DELAY
		return
	end

	if attempt_state.phase == "confirmed" or attempt_state.phase == "hacking" then
		if (not active_tag or active_tag:target_unit() ~= attempt_state.target_unit) and attempt_state.saw_hacking_state then
			attempt_state.phase = "hacking"
		end

		if attempt_state.saw_hacking_state and state ~= HACKING_STATE then
			clear_attempt()
		end
	end
end

mod._reg("update", function()
	if not mod._S("enable_servo_skull_auto_hack") then
		return
	end

	local t = mod._time("gameplay")

	if not t or t < next_check then
		return
	end

	next_check = t + CHECK_INTERVAL

	local player_manager = Managers.player
	local player = player_manager and player_manager:local_player_safe(1)
	local player_unit = player and player.player_unit
	local extension_manager = Managers.state and Managers.state.extension
	local smart_tag_system = extension_manager and extension_manager:system("smart_tag_system")

	if not player_unit or not Unit.alive(player_unit) or not smart_tag_system then
		return
	end

	local active_tag = active_hack_order(smart_tag_system, player_unit)
	local state = attempt_state.phase ~= "idle" and servo_skull_state(player_unit) or nil

	update_attempt(t, active_tag, state)

	if active_tag then
		return
	end

	if attempt_state.phase ~= "idle" or t < next_order_at then
		return
	end

	local player_position = Unit.world_position(player_unit, 1)
	local command_range = mod._N("servo_skull_command_range", CompanionServoSkullSettings.max_target_distance_range, 5, 100)
	local command_range_sq = command_range * command_range
	local require_line_of_sight = mod._S("servo_skull_require_line_of_sight")
	local physics_world
	local line_of_sight_origin

	if require_line_of_sight then
		local world_manager = Managers.world

		if world_manager and world_manager:has_world("level_world") then
			physics_world = World.physics_world(world_manager:world("level_world"))
		end

		local unit_data_extension = ScriptUnit.has_extension(player_unit, "unit_data_system")
		local first_person_component = unit_data_extension and unit_data_extension:read_component("first_person")

		line_of_sight_origin = first_person_component and first_person_component.position
	end

	local target_unit = nearest_hack_target(smart_tag_system, player_unit, player_position, command_range_sq, require_line_of_sight, physics_world, line_of_sight_origin)

	if not target_unit then
		return
	end

	attempt_state.phase = "sent"
	attempt_state.target_unit = target_unit
	attempt_state.sent_at = t

	smart_tag_system:set_contextual_unit_tag(player_unit, target_unit, true)
	next_order_at = t + ORDER_RETRY_DELAY
end)

local function reset()
	next_check = 0
	next_order_at = 0
	clear_attempt()
end

mod._reg("runtime_reset", reset)
mod._reg("enabled", function()
	reset()
end)
mod._reg("setting_changed", function(id)
	if id == "enable_servo_skull_auto_hack" then
		reset()
	end
end)

return true
