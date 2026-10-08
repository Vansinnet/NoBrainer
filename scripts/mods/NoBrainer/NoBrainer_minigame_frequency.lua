---@class NoBrainerMod
local mod = get_mod("NoBrainer")
local S = mod._S

local MinigameSettings, UIWidget
local function _deps()
    if not MinigameSettings then
        MinigameSettings = require("scripts/settings/minigame/minigame_settings")
        UIWidget = require("scripts/managers/ui/ui_widget")
    end
end

mod._freq_scale         = mod._freq_scale         or 0

local ARROW_MATERIAL = "content/ui/materials/buttons/arrow_01"
local ARROW_SIZE     = { 120, 120 }
local ARROW_DEPTH    = 7
local ARROW_TOP_Y    = 200
local ARROW_COLOR    = { 255, 255, 165, 0 }
local ARROW_HIDDEN   = { 0,   255, 165, 0 }
local RAD_180       = math.rad(180)
local RAD_90        = math.rad(90)
local RAD_NEG90     = math.rad(-90)
local FREQUENCY_MIN_STRENGTH = 0.45
local FREQUENCY_MAX_STARTUP_DELAY = 0.75
local FREQUENCY_MAX_REACTION_DELAY = 1.00
local FREQUENCY_MAX_CONFIRM_DELAY = 1.20
local FREQUENCY_MAX_COOLDOWN_EXTRA = 0.12
local FREQUENCY_RESTART_RECOVERY_TIMEOUT = 1.2

local ARROW_SPECS = {
    x = { offset = { -385, ARROW_TOP_Y, ARROW_DEPTH } },
    y = { offset = { -240, ARROW_TOP_Y, ARROW_DEPTH } },
}
local frequency_active = false
local active_frequency_key = nil
local frequency_completed = false
local frequency_stopped_key = nil
local frequency_stopped_until = 0
local frequency_restart_key = nil
local frequency_restart_until = 0
local frequency_restart_stop_seen = false
local frequency_restart_board_fresh = false
local frequency_restart_stage_fresh = false
local frequency_restart_target_fresh = false

mod._freq.session_active = false

-- A client acts only after its own start plus the stage and target receipts of the opening (BetterBrainer
-- 1.0.2): a retained board from an earlier session is never steered or submitted.
local openings = setmetatable({}, { __mode = "k" })

local function _opening(mg)
	local receipt = openings[mg]
	if not receipt then
		receipt = {}
		openings[mg] = receipt
	end
	return receipt
end

local function _fresh(mg)
	local receipt = openings[mg]
	return mg._is_server == true or receipt ~= nil and receipt.started and receipt.stage and receipt.target or false
end

local function _reset_frequency_timing()
	mod._freq_cooldown = 0
	mod._freq_last_stage = 0
	mod._freq_reaction_until = 0
	mod._freq_confirm_until = 0
	mod._freq_was_on_target = false
	mod._freq_press_until = 0
	mod._freq_release_until = 0
end

local function _reset_snapshot()
    local freq = mod._freq
    freq.timer = 0
    freq.active = false
    freq.gameplay = false
    freq.completed = false
    freq.current_x = nil
    freq.current_y = nil
    freq.target_x = nil
    freq.target_y = nil
    freq.dir_x = 0
    freq.dir_y = 0
    freq.on_target = false
    freq.stage = nil
    freq.key = nil
    freq.fresh = false
end

local function _snapshot_fresh()
    local freq = mod._freq
    return freq and freq.session_active and freq.active and freq.timer > 0 and freq.gameplay and not freq.completed
        and freq.fresh
end

local function _is_active_frequency_mg(mg)
	return mg ~= nil and active_frequency_key == tostring(mg)
end

local function _stage(mg)
    return mg and mg.current_stage and mg:current_stage() or mg and mg._current_stage
end

local function _ensure_arrows(view)
    local arrows = view._nb_freq_arrows
    if arrows and arrows.x and arrows.y then
        return arrows
    end
    _deps()
    arrows = {}
    for axis, spec in pairs(ARROW_SPECS) do
        local def = UIWidget.create_definition({{
            pass_type = "rotated_texture",
            style_id  = "arrow",
            value     = ARROW_MATERIAL,
            style     = {
                hdr    = true,
                angle  = 0,
                color  = table.clone(ARROW_HIDDEN),
                offset = table.clone(spec.offset),
                pivot  = {},
            },
        }}, "center_pivot", nil, ARROW_SIZE)
        arrows[axis] = UIWidget.init("nb_freq_arrow_" .. axis, def)
    end
    view._nb_freq_arrows = arrows
    return arrows
end

local function _is_gameplay(mg)
    _deps()
    local state = mg and mg.state and mg:state()
    return not state or state == MinigameSettings.game_states.gameplay
end

local function _scanner_view_active()
    local ui = Managers.ui
    return ui and ui:view_active("scanner_display_view")
end

local function _freq_on_target_mg(mg)
    if not mg then return false end
    if not _is_gameplay(mg) then return false end

    return mg:is_visually_on_target() == true
end

local function _sample_frequency(mg, allow_server_fallback)
    local freq = mod._freq
    if not freq then return end
	local key = mg and tostring(mg) or nil

	if key and freq.key and freq.key ~= key then
		_reset_frequency_timing()
	end

    if not S("enable_frequency_auto") or not mg or not mg.frequency or not mg.target_frequency then
        _reset_snapshot()
        return
    end

    _deps()
    local completed = mg.is_completed and mg:is_completed() == true or false
    local gameplay = not completed and _is_gameplay(mg)
    local current = gameplay and mg:frequency() or nil
    local target = gameplay and mg:target_frequency() or nil
    local stage = _stage(mg)

    freq.timer = 0.075
    freq.active = true
    freq.gameplay = gameplay
    freq.completed = completed
    freq.stage = stage
    freq.key = key
    freq.fresh = _fresh(mg)
    freq.current_x = current and current.x or nil
    freq.current_y = current and current.y or nil
    freq.target_x = target and target.x or nil
    freq.target_y = target and target.y or nil
    freq.on_target = current and target and _freq_on_target_mg(mg) or false

    if current and target then
        local margin  = (MinigameSettings.frequency_success_margin or 0.1) * 0.35
        local range_x = math.max((MinigameSettings.frequency_width_max_scale  or 3.0) - (MinigameSettings.frequency_width_min_scale  or 1.5), 0.01)
        local range_y = math.max((MinigameSettings.frequency_height_max_scale or 3.5) - (MinigameSettings.frequency_height_min_scale or 1.5), 0.01)
        local dx      = target.x - current.x
        local dy      = target.y - current.y

        freq.dir_x = math.abs(dx) <= margin and 0 or math.clamp(dx / (range_x * 0.2), -1, 1)
        freq.dir_y = math.abs(dy) <= margin and 0 or math.clamp(dy / (range_y * 0.2), -1, 1)
    else
        freq.dir_x = 0
        freq.dir_y = 0
    end

    local now = mod._time("gameplay")
    if allow_server_fallback and frequency_active and freq.session_active and _is_active_frequency_mg(mg)
        and now and mg._is_server and gameplay and not completed and mod._freq_startup_delay <= 0 and freq.fresh
    then
        local on_target = freq.on_target
        local move_vec = mod._freq_move_vec and mod._freq_move_vec()
        if move_vec then
            mg._last_axis_set = now - 0.02
            mg:on_axis_set(now, move_vec.x, move_vec.y)
        end

        if on_target and mod._freq_try_submit and mod._freq_try_submit(now) then
            mg:test_frequency(mg._frequency.x, mg._frequency.y)
        end
    end
end

mod:hook_require("scripts/ui/views/scanner_display_view/minigame_frequency_view", function(View)
	mod:hook_safe(View, "draw_widgets", function(self, dt, t, input_service, ui_renderer)
		_deps()

		local ext = self._minigame_extension
		if not ext then
			return
		end
		local mg = ext:minigame(MinigameSettings.types.frequency)
		_sample_frequency(mg, true)
		if not S("enable_frequency_highlight") then
			return
		end
		if not ui_renderer then
			return
		end
		if not mg or not mg.frequency or not mg.target_frequency then
			return
		end
		if mg.is_completed and mg:is_completed() then
			return
		end

		local current = mg:frequency()
		local target  = mg:target_frequency()
		if not current or not target then
			return
		end

		local margin = (MinigameSettings.frequency_success_margin or 0.1) * 0.35
		local dx = target.x - current.x
		local dy = target.y - current.y

		local arrows = _ensure_arrows(self)
		if not arrows then
			return
		end

		local xw = arrows.x
		if xw then
			local active = math.abs(dx) > margin
			xw.style.arrow.color = active and ARROW_COLOR or ARROW_HIDDEN
			xw.style.arrow.angle = dx < -margin and RAD_180 or 0
			if active then UIWidget.draw(xw, ui_renderer) end
		end

		local yw = arrows.y
		if yw then
			local active = math.abs(dy) > margin
			yw.style.arrow.color = active and ARROW_COLOR or ARROW_HIDDEN
			yw.style.arrow.angle = dy > margin and RAD_90 or RAD_NEG90
			if active then UIWidget.draw(yw, ui_renderer) end
		end
	end)

    mod:hook_safe(View, "init", function(self)
        self._nb_freq_arrows = nil
    end)
    mod:hook_safe(View, "destroy", function(self)
        self._nb_freq_arrows = nil
    end)
end)

function mod._freq_move_vec()
	local freq = mod._freq
	if not freq or not freq.session_active or freq.timer <= 0 or not freq.active or freq.completed or not freq.fresh then return nil end
	if not freq.gameplay then
		return nil
    end

	_deps()
	if not freq.current_x or not freq.current_y or not freq.target_x or not freq.target_y then
        return nil
    end

    local ix = freq.dir_x or 0
    local iy = freq.dir_y or 0

    if mod._freq_scale < 1 then
        local strength = FREQUENCY_MIN_STRENGTH + mod._freq_scale * (1 - FREQUENCY_MIN_STRENGTH)

		local now = mod._time("gameplay")
        if now and mod._freq_reaction_until > now then
            return Vector3(0, 0, 0)
        end

        ix = ix * strength
        iy = iy * strength
    end

    return Vector3(ix, iy, 0)
end

local function _freq_update_state(now)
    local freq = mod._freq
    if not _snapshot_fresh() or not now then return false end

    local stage = freq.stage
    if not stage then return false end

    if stage ~= mod._freq_last_stage then
		local previous_stage = mod._freq_last_stage
        mod._freq_last_stage = stage
        mod._freq_confirm_until = 0

        if previous_stage ~= 0 and mod._freq_scale < 1 then
            mod._freq_reaction_until = now + mod._speed_pacing("frequency_solve_speed") * FREQUENCY_MAX_REACTION_DELAY
        end
    end

    local on_target = freq.on_target == true
    if on_target and not mod._freq_was_on_target and mod._freq_scale < 1 then
        mod._freq_confirm_until = now + mod._speed_pacing("frequency_solve_speed") * FREQUENCY_MAX_CONFIRM_DELAY
    end

    mod._freq_was_on_target = on_target

    return on_target
end

function mod._freq_try_submit(now)
	local freq = mod._freq
	if not freq or not now then return false end
	if mod._freq_startup_delay > 0 then
        return false
    end

	if mod._freq_cooldown > 0 then
        return false
    end

	if not _freq_update_state(now) then
        return false
    end

	if mod._freq_confirm_until > now or mod._freq_reaction_until > now then
        return false
    end

	local scale = mod._freq_scale or 0
	mod._freq_cooldown = 0.08 + (1 - scale) * FREQUENCY_MAX_COOLDOWN_EXTRA
	mod._freq_press_until = now + 0.08
	mod._freq_release_until = mod._freq_press_until + 0.12

	return true
end

local function _freq_cleanup(reason)
	frequency_active = false
	active_frequency_key = nil
	frequency_completed = reason == "complete"
	frequency_stopped_key = nil
	frequency_stopped_until = 0
	frequency_restart_key = nil
	frequency_restart_until = 0
	frequency_restart_stop_seen = false
	frequency_restart_board_fresh = false
	frequency_restart_stage_fresh = false
	frequency_restart_target_fresh = false
	mod._freq.session_active = false
	_reset_snapshot()
	mod._freq_startup_delay = 0
	_reset_frequency_timing()
end

local function _arm_frequency_session(mg, restart_until)
	frequency_active = true
	active_frequency_key = tostring(mg)
	frequency_completed = false
	frequency_stopped_key = nil
	frequency_stopped_until = 0
	frequency_restart_key = nil
	frequency_restart_until = restart_until or 0
	frequency_restart_stop_seen = false
	frequency_restart_board_fresh = false
	frequency_restart_stage_fresh = false
	frequency_restart_target_fresh = false
	mod._freq.session_active = true
	if not mg._is_server then _opening(mg).started = true end
	_reset_snapshot()
	_sample_frequency(mg, false)
	mod._freq_scale = mod._speed_scale("frequency_solve_speed")
	_reset_frequency_timing()
	mod._freq_startup_delay = mod._speed_pacing("frequency_solve_speed") * FREQUENCY_MAX_STARTUP_DELAY
end

mod:hook_safe("MinigameFrequency", "start", function(self, player)
	if mod._is_local_minigame_player(player) then
		if openings[self] and openings[self].foreign then openings[self] = nil end
		_opening(self).started = true
	elseif player or not (frequency_active and _is_active_frequency_mg(self)) then
		openings[self] = { foreign = true }
	end

	if not mod._is_local_minigame_player(player) then
		if frequency_active and _is_active_frequency_mg(self)
			or frequency_restart_key and frequency_restart_key == tostring(self)
			or frequency_stopped_key and frequency_stopped_key == tostring(self)
		then
			_freq_cleanup("ownership_transferred")
		end
		return
	end

	if not S("enable_frequency_auto") then
		return
	end

	local now = mod._time("gameplay")
	local quick_restart = self._is_server ~= true
		and now ~= nil
		and frequency_stopped_key == tostring(self)
		and now <= frequency_stopped_until
	local restart_until = quick_restart and now + FREQUENCY_RESTART_RECOVERY_TIMEOUT or 0

	if quick_restart then
		_freq_cleanup("restart_sync")
		frequency_restart_key = tostring(self)
		frequency_restart_until = restart_until
	else
		_arm_frequency_session(self, restart_until)
	end
end)

mod:hook_safe("MinigameFrequency", "stop", function(self, ...)
	local key = tostring(self)
	local active = _is_active_frequency_mg(self)
	local player = select(1, ...)
	local arg_count = select("#", ...)
	local now = mod._time("gameplay")
	local local_stop = arg_count > 0 and mod._is_local_minigame_player(player)
	local stale_stop_before_restart = arg_count == 0
		and not active
		and self._is_server ~= true
		and frequency_stopped_key == key
	local recoverable_restart = (active or frequency_restart_key == key)
		and arg_count == 0
		and self._is_server ~= true
		and not frequency_completed
		and now ~= nil
		and now <= frequency_restart_until
	local restart_until = frequency_restart_until

	-- A continuing argumentless receipt (including the server stop after a quick restart) keeps the
	-- opening; a real stop retires it.
	if arg_count > 0 or not active and frequency_restart_key ~= key then
		openings[self] = nil
	end

	if active or frequency_restart_key == key then
		_freq_cleanup(not frequency_completed and "stop" or nil)
	end

	if local_stop and self._is_server ~= true and now then
		frequency_stopped_key = key
		frequency_stopped_until = now + FREQUENCY_RESTART_RECOVERY_TIMEOUT
	elseif stale_stop_before_restart then
		frequency_stopped_key = nil
		frequency_stopped_until = 0
	elseif recoverable_restart then
		frequency_restart_key = key
		frequency_restart_until = restart_until
		frequency_restart_stop_seen = true
	end
end)
mod:hook_safe("MinigameFrequency", "complete", function(self)
	if _is_active_frequency_mg(self) or frequency_restart_key == tostring(self) then
		_freq_cleanup("complete")
	end
end)

mod:hook_safe("MinigameFrequency", "generate_board", function(self)
	if frequency_restart_key == tostring(self) and frequency_restart_stop_seen then
		frequency_restart_board_fresh = true
		frequency_restart_stage_fresh = false
		frequency_restart_target_fresh = false
	end
end)

mod:hook_safe("MinigameFrequency", "set_current_stage", function(self, stage)
	if self._is_server == false then _opening(self).stage = true end
	if frequency_restart_key == tostring(self) and frequency_restart_stop_seen and frequency_restart_board_fresh and stage == 1 then
		frequency_restart_stage_fresh = true
		frequency_restart_target_fresh = false
	end
end)

mod:hook_safe("MinigameFrequency", "set_target_frequency", function(self)
	if self._is_server == false then _opening(self).target = true end
	if frequency_restart_key == tostring(self) and frequency_restart_stop_seen and frequency_restart_board_fresh and frequency_restart_stage_fresh then
		frequency_restart_target_fresh = true
	end
end)

function mod._freq_rearm_from_state(state, t)
	if not frequency_restart_key then return end

	local now = t or mod._time("gameplay")
	if not now or now > frequency_restart_until then
		_freq_cleanup("restart_timeout")
		return
	end
	if frequency_active or not S("enable_frequency_auto") then return end
	if not frequency_restart_stop_seen then return end
	if not frequency_restart_board_fresh or not frequency_restart_stage_fresh or not frequency_restart_target_fresh then return end

	local mg = state and state._minigame
	local player = state and state._player
	if not mg or tostring(mg) ~= frequency_restart_key then return end
	if mg._is_server == true or not mod._is_local_minigame_player(player) or not _scanner_view_active() then return end
	if mg.is_completed and mg:is_completed() or not _is_gameplay(mg) then return end
	local unit = mg._minigame_unit
	if not unit or not Unit.alive(unit) then return end

	_sample_frequency(mg, false)
	local freq = mod._freq
	if freq.key ~= frequency_restart_key or freq.stage ~= 1 then return end
	if type(freq.current_x) ~= "number" or type(freq.current_y) ~= "number" then return end
	if type(freq.target_x) ~= "number" or type(freq.target_y) ~= "number" then return end

	local restart_until = frequency_restart_until
	_arm_frequency_session(mg, restart_until)
end

local function on_update(dt)
	local freq = mod._freq
	if freq and freq.timer > 0 then
		freq.timer = math.max(freq.timer - dt, 0)
	end
	if mod._freq_startup_delay > 0 then
		mod._freq_startup_delay = math.max(mod._freq_startup_delay - dt, 0)
	end
	if mod._freq_cooldown > 0 then
		mod._freq_cooldown = math.max(mod._freq_cooldown - dt, 0)
	end

	if not freq or not S("enable_frequency_auto") then return end
	if freq.completed then
		_freq_cleanup("complete")
		return
	end
	if not _snapshot_fresh() then return end

	local now = mod._time("gameplay")
	if not now then return end

	_freq_update_state(now)
end

local function on_setting(id)
	if id == "frequency_solve_speed" then
		mod._freq_scale = mod._speed_scale("frequency_solve_speed")
	end
	if id == "enable_frequency_auto" and not S("enable_frequency_auto") then
		_freq_cleanup(frequency_active and "setting_changed" or nil)
	end
end

local function on_round_end()
	_freq_cleanup(frequency_active and "round_end" or nil)
	table.clear(openings)
end

mod._reg("update",          on_update)
mod._reg("setting_changed", on_setting)
mod._reg("round_end",       on_round_end)

return true
