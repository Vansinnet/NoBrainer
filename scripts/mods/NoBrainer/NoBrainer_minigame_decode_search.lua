local mod = get_mod("NoBrainer")
local S = mod._S

local MinigameSettings, SearchViewSettings, UIWidget
local BW, BH, CW, CH
local function _deps()
	if not MinigameSettings then
		MinigameSettings = require("scripts/settings/minigame/minigame_settings")
		SearchViewSettings = require("scripts/ui/views/scanner_display_view/scanner_display_view_decode_search_settings")
		UIWidget = require("scripts/managers/ui/ui_widget")
		BW = MinigameSettings.decode_search_board_width or 6
		BH = MinigameSettings.decode_search_board_height or 4
		CW = MinigameSettings.decode_search_cursor_width or 2
		CH = MinigameSettings.decode_search_cursor_height or 2
	end
end

local HIGHLIGHT = { 110, 255, 165, 0 }
-- Movement transport follows the BetterBrainer Search window: native on_axis_set moves one
-- cell per axis per serialized direction frame after a neutral frame, so every command is one
-- direction frame followed by neutral. Receipts are the replicated cursor, never elapsed time.
local SEARCH_BASE_ACK_TIMEOUT = 0.8
local SEARCH_MAX_ACK_TIMEOUT = 3.2
local SEARCH_MAX_BACKOFF = 4
local SEARCH_HIGH_PING_RTT = 0.25
local SEARCH_PING_INTERVAL = 1
local SEARCH_MAX_MOVE_DELAY = 1.054
local SEARCH_MAX_STAGE_DELAY = 1.632
local SEARCH_MAX_SUBMIT_SETTLE = 0.646
local SEARCH_MAX_AFTER_MOVE_DELAY = 0.510
local SEARCH_STARTUP_DELAY = 0.20
local SEARCH_RESTART_RECOVERY_TIMEOUT = 1.2
local _find_target
local search_active = false
local active_search_key = nil
local search_completed = false
local search_restart_key = nil
local search_restart_until = 0
local active_search_mg = nil

local move_pending = {}
local move_limit, move_cautious, move_backoff = 2, false, 1
local move_base_timeout, move_ack_timeout, move_next_ping = SEARCH_BASE_ACK_TIMEOUT, SEARCH_BASE_ACK_TIMEOUT, 0
local move_resync_until = nil
local move_release = true
local move_frame, move_x, move_y = nil, 0, 0

mod._exp.session_active = false
mod._exp_pending_moves = move_pending

local function _game_time()
	return mod._time("gameplay")
end

local function _n(v, fallback)
    local t = type(v)
    if t == "number" then return math.floor(v + 0.5) end
    if t == "string" then
        local n = tonumber(v)
        return n and math.floor(n + 0.5) or fallback
    end

    if t == "table" then
        for _, x in ipairs(v) do
            local r = _n(x, nil)

            if r then
                return r
            end
        end

        for k, x in pairs(v) do
            if k ~= "id" and k ~= "value" then
                local r = _n(x, nil)

                if r then
                    return r
                end
            end
        end

        return v.symbol or v.symbol_id or v.id or v.value or fallback
    end
    return fallback
end

local function _flat4(grid)
    if type(grid) ~= "table" then return nil end
    local flat = {}
    if #grid == CW * CH and type(grid[1]) == "number" then
        for i = 1, CW * CH do
            flat[i] = _n(grid[i], 1) or 1
        end

        return flat
    end
    if type(grid[1]) == "table" then
        for y = 1, CH do
            for x = 1, CW do
                flat[#flat + 1] = _n(grid[y] and grid[y][x], 1) or 1
            end
        end

        return flat
    end
    if #grid >= BW then
        return nil
    end
    return nil
end

local function _mg(view)
	local ext = view and view._minigame_extension
	if not ext or not ext.minigame then return nil end

	return ext:minigame(MinigameSettings.types.decode_search)
end

local function _exp_move_delay()
	return mod._speed_pacing("expedition_solve_speed") * SEARCH_MAX_MOVE_DELAY
end

local function _arm_move_cooldown()
	mod._exp_move_cooldown = math.max(mod._exp_move_cooldown or 0, _exp_move_delay())
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

local function _reset_submit_settle()
	mod._exp_on_target_since = 0
	mod._exp_on_target_stage = nil
	mod._exp_on_target_cursor_x = nil
	mod._exp_on_target_cursor_y = nil
	mod._exp_on_target_target_x = nil
	mod._exp_on_target_target_y = nil
end

-- Dropping unconfirmed commands is safe: a later cursor change without a matching command
-- is a mismatch and enters neutral resynchronization.
local function _clear_pending_move()
	table.clear(move_pending)
	mod._exp_pending_move = nil
end

local function _reset_move_state()
	_clear_pending_move()
	move_limit, move_cautious, move_backoff = 2, false, 1
	move_base_timeout, move_ack_timeout, move_next_ping = SEARCH_BASE_ACK_TIMEOUT, SEARCH_BASE_ACK_TIMEOUT, 0
	move_resync_until = nil
	move_release = true
	move_frame, move_x, move_y = nil, 0, 0
	mod._exp_prev_cursor = nil
end

local function _moves_busy()
	return move_pending[1] ~= nil or move_resync_until ~= nil
end

local function _stage(mg)
	return mg and mg.current_stage and mg:current_stage() or mg and mg._current_stage
end

local function _reset_snapshot()
	local exp = mod._exp
	exp.timer = 0
	exp.active = false
	exp.gameplay = false
	exp.completed = false
	exp.cursor_x = nil
	exp.cursor_y = nil
	exp.target_x = nil
	exp.target_y = nil
	exp.dir_x = 0
	exp.dir_y = 0
	exp.on_target = false
	exp.stage = nil
	exp.key = nil
end

local function _snapshot_fresh()
	local exp = mod._exp
	return exp and exp.session_active and exp.active and exp.timer > 0 and exp.gameplay and not exp.completed
end

local function _is_active_search_mg(mg)
	return search_active and mg ~= nil and active_search_key == tostring(mg)
end

local function _sample_search(mg)
	local exp = mod._exp
	if not exp then return end
	local key = mg and tostring(mg) or nil

	if key and exp.key and exp.key ~= key then
		_clear_pending_move()
		_reset_submit_settle()
		mod._exp_press_until = 0
		mod._exp_release_until = 0
		mod._exp_move_cooldown = 0
		mod._exp_submitted_stage = nil
		mod._exp_submitted_until = 0
		mod._exp_prev_cursor = nil
		mod._exp_last_move_at = 0
	end

	if not S("enable_expedition_auto_solve") or not mg or not mg.cursor_position then
		_reset_snapshot()
		return
	end

	_deps()
	local completed = mg.is_completed and mg:is_completed() == true or false
	local gameplay = not completed and _is_gameplay(mg)
	local cursor = gameplay and mg:cursor_position() or nil
	local target = cursor and _find_target(mg, cursor) or nil
	local stage = _stage(mg)

	exp.timer = 0.075
	exp.active = true
	exp.gameplay = gameplay
	exp.completed = completed
	exp.stage = stage
	exp.key = key
	exp.cursor_x = cursor and cursor.x or nil
	exp.cursor_y = cursor and cursor.y or nil
	exp.target_x = target and target.x or nil
	exp.target_y = target and target.y or nil
	exp.on_target = cursor and target and cursor.x == target.x and cursor.y == target.y or false

	if cursor and target then
		local dx = target.x - cursor.x
		local dy = target.y - cursor.y
		exp.dir_x = dx == 0 and 0 or dx > 0 and 1 or -1
		exp.dir_y = dy == 0 and 0 or dy > 0 and -1 or 1
	else
		exp.dir_x = 0
		exp.dir_y = 0
	end

end

local function _cursor_target()
	local exp = mod._exp
	if not _snapshot_fresh() then return nil, nil, nil, nil, exp and exp.stage end
	return exp.cursor_x, exp.cursor_y, exp.target_x, exp.target_y, exp.stage
end

_find_target = function(mg, cursor)
	_deps()
	if not mg or not mg.get_symbols_for_target then return nil end
	local stage = mg.current_stage and mg:current_stage() or mg._current_stage
	if not stage then return nil end

	local cache = mg._nb_mtc
	if cache and cache._stage == stage then return cache end

	local target = mg._decode_targets and mg._decode_targets[stage]
	if not target then
		if mg.decode_targets then
			local tgs = mg.decode_targets(mg)
			target = tgs and tgs[stage]
		end
	end
	if not target then return nil end

	local tx, ty
	if type(target) == "table" then
		if target.x then tx, ty = target.x, target.y
		elseif target.target_x then tx, ty = target.target_x, target.target_y
		elseif #target == 2 and type(target[1]) == "number" then tx, ty = target[1], target[2]
		end
	end

	if tx ~= nil then
		local mx = math.max(BW - CW + 1, 1)
        local my = math.max(BH - CH + 1, 1)

		if tx >= 0 and tx <= mx - 1 then tx = tx + 1 end
		if ty >= 0 and ty <= my - 1 then ty = ty + 1 end
		tx = math.clamp(math.floor(tx + 0.5), 1, mx)
		ty = math.clamp(math.floor(ty + 0.5), 1, my)
		cache = { x = tx, y = ty, _stage = stage }
		mg._nb_mtc = cache
		return cache
	end

	local tflat = _flat4(target)
	if not tflat then return nil end

	if not mg.get_symbols_for_target then return nil end
	local mx = math.max(BW - CW + 1, 1)
    local my = math.max(BH - CH + 1, 1)
	if not cursor and mg.cursor_position then
		cursor = mg:cursor_position()
	end
	local best
	local best_steps = math.huge
	local best_distance = math.huge

	for y = 1, my do
        for x = 1, mx do
			local grid = mg.get_symbols_for_target(mg, x, y)
			if grid then
				local gflat = _flat4(grid)
				if gflat then
					local match = true

					for i = 1, CW * CH do
                        if gflat[i] ~= tflat[i] then
                            match = false
                            break
                        end
					end

					if match then
						local dx = cursor and math.abs(x - cursor.x) or 0
						local dy = cursor and math.abs(y - cursor.y) or 0
						local steps = math.max(dx, dy)
						local distance = dx + dy

						if not best or steps < best_steps or steps == best_steps and distance < best_distance then
							best = { x = x, y = y }
							best_steps = steps
							best_distance = distance
						end
					end
				end
			end
		end
    end

	if best then
		cache = { x = best.x, y = best.y, _stage = stage }
		mg._nb_mtc = cache
		return cache
	end

	return nil
end

local function _widgets(view, n)
	if n <= 0 then
        view._nb_mw = nil
        return nil
    end

	local w = view._nb_mw
	if w and #w == n then return w end
	_deps()
	w = {}
	for i = 1, n do
		local def = UIWidget.create_definition({{
			pass_type = "texture", style_id = "highlight",
			value = "content/ui/materials/backgrounds/scanner/scanner_decode_symbol_highlight",
			style = { hdr = true, color = HIGHLIGHT },
		}}, "center_pivot", nil, SearchViewSettings.symbol_widget_size)
		w[i] = UIWidget.init("nb_mw_" .. i, def)
	end
	view._nb_mw = w
	return w
end

mod:hook_require("scripts/ui/views/scanner_display_view/minigame_decode_search_view", function(View)
	mod:hook_safe(View, "draw_widgets", function(self, _, __, ___, ui_renderer)
		_deps()
		local mg = _mg(self)
		_sample_search(mg)
		if not S("enable_matching") or not ui_renderer then
			return
		end
		if not mg or not mg.symbols or not mg.current_stage then
			return
		end

        if self._nb_mm ~= mg then
            self._nb_mm = mg
            self._nb_mw = nil

            if mg then
                mg._nb_mtc = nil
            end
        end

		local pos = _find_target(mg)
		if not pos then
			return
		end

		local w = _widgets(self, CW * CH)
		if not w then return end

		local ws = SearchViewSettings.symbol_widget_size
		local sp = SearchViewSettings.symbol_spacing or 0
		local ox = SearchViewSettings.symbol_starting_offset_x or 0
		local oy = SearchViewSettings.symbol_starting_offset_y or 0

		local i = 0
		for y = 0, CH - 1 do
			for x = 0, CW - 1 do
				i = i + 1
				local wi = w[i]
				local sx = pos.x + x
				local sy = pos.y + y

				wi.style.highlight.color = HIGHLIGHT
				wi.offset[1] = ox + (ws[1] + sp) * (sx - 1)
				wi.offset[2] = oy + (ws[2] + sp) * (sy - 1)
				wi.offset[3] = 6
				UIWidget.draw(wi, ui_renderer)
			end
		end
	end)
end)

mod._exp_find_target = _find_target

local function _clear_match_cache(mg)
	if mg then
		mg._nb_mtc = nil
	end

	_clear_pending_move()
	_reset_submit_settle()
end

local function _poll_ping(mg, t)
	if mg._is_server or t < move_next_ping then return end

	local connection = Managers.connection
	local host = connection and connection:host()
	local rtt = host and Network.ping(host)
	if type(rtt) ~= "number" or rtt ~= rtt or rtt < 0 or rtt == math.huge then rtt = 0 end

	-- Reduce the window immediately; expand only after outstanding commands drain.
	if rtt >= SEARCH_HIGH_PING_RTT then
		move_limit = 1
	elseif not move_pending[1] then
		move_limit = 2
	end

	move_base_timeout = math.min(SEARCH_MAX_ACK_TIMEOUT, math.max(SEARCH_BASE_ACK_TIMEOUT, rtt * 2 + 0.2))
	move_ack_timeout = math.min(SEARCH_MAX_ACK_TIMEOUT, move_base_timeout * move_backoff)
	move_next_ping = t + SEARCH_PING_INTERVAL
end

local function _observe_moves(mg, t)
	_poll_ping(mg, t)

	local cursor = mg:cursor_position()
	if not cursor then return nil end

	local prev = mod._exp_prev_cursor
	local changed = prev ~= nil and (prev.x ~= cursor.x or prev.y ~= cursor.y)
	local mismatch = false

	if move_resync_until then
		-- Wait for a quiet authoritative cursor before trusting a new baseline.
		if changed then move_resync_until = t + move_ack_timeout end
		if t >= move_resync_until then move_resync_until = nil end
	elseif changed then
		local matched = false

		for i = #move_pending, 1, -1 do
			local command = move_pending[i]
			local complete = cursor.x == command.x and cursor.y == command.y
			-- A diagonal replicates X before Y. Retire predecessors, not this partial move.
			local partial = command.diagonal and cursor.x == command.x and cursor.y == command.cursor_y

			if complete or partial then
				for _ = 1, complete and i or i - 1 do
					table.remove(move_pending, 1)
				end

				if complete then
					move_cautious, move_backoff, move_ack_timeout = false, 1, move_base_timeout
					mod._exp_last_move_at = t
					_arm_move_cooldown()
				end

				matched = true
				break
			end
		end

		mismatch = not matched
	end

	if not move_resync_until and (mismatch or move_pending[1] and t >= move_pending[1].until_t) then
		-- Overshoot, undershoot or a lost command: a timeout is not an ACK. Drain late traffic
		-- with neutral input, then re-plan from the authoritative cursor one command at a time.
		table.clear(move_pending)
		move_cautious = true
		move_backoff = math.min(SEARCH_MAX_BACKOFF, move_backoff * 2)
		move_ack_timeout = math.min(SEARCH_MAX_ACK_TIMEOUT, move_base_timeout * move_backoff)
		move_resync_until = t + move_ack_timeout
		move_release = true
	end

	if changed or mismatch then
		_reset_submit_settle()
	end

	mod._exp_pending_move = move_pending[1]

	if prev then
		prev.x, prev.y = cursor.x, cursor.y
	else
		mod._exp_prev_cursor = { x = cursor.x, y = cursor.y }
	end

	return cursor
end

local function _plan_move(mg, cursor, t)
	if move_resync_until or #move_pending >= (move_cautious and 1 or move_limit) then return end
	if (mod._exp_startup_delay or 0) > 0 or (mod._exp_move_cooldown or 0) > 0 then return end
	if t < (mod._exp_release_until or 0) or t < (mod._exp_submitted_until or 0) then return end

	local target = _find_target(mg, cursor)
	if not target then return end

	local tail = move_pending[#move_pending]
	local x, y = tail and tail.x or cursor.x, tail and tail.y or cursor.y
	local dx, dy = target.x - x, target.y - y
	if dx == 0 and dy == 0 then return end

	move_x = dx == 0 and 0 or dx > 0 and 1 or -1
	move_y = dy == 0 and 0 or dy > 0 and -1 or 1
	move_pending[#move_pending + 1] = {
		cursor_x = x,
		cursor_y = y,
		dir_x = move_x,
		dir_y = move_y,
		x = x + move_x,
		y = y - move_y,
		diagonal = move_x ~= 0 and move_y ~= 0,
		until_t = t + move_ack_timeout,
	}
	mod._exp_pending_move = move_pending[1]
	mod._exp_last_move_at = t
	_arm_move_cooldown()
	move_release = true
	_reset_submit_settle()
end

-- Called only while HumanInputHandler serializes a fixed frame for the local player.
-- Returns nil when the solver does not own movement; otherwise one direction frame per
-- command and neutral on every other frame, never the player's own movement.
function mod._exp_move_input(action, frame)
	local mg = active_search_mg
	if not mg or not search_active or not frame or not S("enable_expedition_auto_solve") then return nil end
	if not _scanner_view_active() or mg:is_completed() or not _is_gameplay(mg) then return nil end

	local t = _game_time()
	if not t then return nil end

	if move_frame ~= frame then
		move_frame, move_x, move_y = frame, 0, 0

		local cursor = _observe_moves(mg, t)
		if move_release then
			move_release = false
		elseif cursor then
			_plan_move(mg, cursor, t)
		end
	end

	if action == "move_left" then return math.max(-move_x, 0) end
	if action == "move_right" then return math.max(move_x, 0) end
	if action == "move_forward" then return math.max(move_y, 0) end
	if action == "move_backward" then return math.max(-move_y, 0) end

	return Vector3(move_x, move_y, 0)
end

function mod._exp_is_on_target()
	local exp = mod._exp
	return exp and exp.timer > 0 and exp.on_target == true
end

function mod._exp_ready_to_submit(now)
	now = now or _game_time()
	local exp = mod._exp
	if not exp or not exp.session_active or not now or exp.timer <= 0 or not exp.active then return false end
	if not exp.gameplay then
		_reset_submit_settle()
        return false
    end

	local cursor_x, cursor_y, target_x, target_y, stage = _cursor_target()

	if cursor_x == nil or cursor_y == nil or target_x == nil or target_y == nil or not exp.on_target then
		_reset_submit_settle()
		return false
	end

	local pacing = mod._speed_pacing("expedition_solve_speed")
	local fast_submit = pacing <= 0

	if _moves_busy() then
		_reset_submit_settle()
		return false
	end

	if not fast_submit then
		local last_move_at = mod._exp_last_move_at or 0
		local since_move = now - last_move_at

		if since_move < SEARCH_MAX_AFTER_MOVE_DELAY * pacing then
			return false
		end
	end

	local changed = mod._exp_on_target_stage ~= stage
		or mod._exp_on_target_cursor_x ~= cursor_x
		or mod._exp_on_target_cursor_y ~= cursor_y
		or mod._exp_on_target_target_x ~= target_x
		or mod._exp_on_target_target_y ~= target_y

	if changed then
		mod._exp_on_target_since = now
		mod._exp_on_target_stage = stage
		mod._exp_on_target_cursor_x = cursor_x
		mod._exp_on_target_cursor_y = cursor_y
		mod._exp_on_target_target_x = target_x
		mod._exp_on_target_target_y = target_y
		return false
	end

	local elapsed = now - (mod._exp_on_target_since or now)

	if fast_submit and elapsed <= 0 then
		return false
	elseif not fast_submit and elapsed < SEARCH_MAX_SUBMIT_SETTLE * pacing then
		return false
	end

	return true
end

function mod._exp_handle_stage_changed(_old_stage, _new_stage)
	_clear_pending_move()
	_reset_submit_settle()
	mod._exp_move_cooldown = mod._speed_pacing("expedition_solve_speed") * SEARCH_MAX_STAGE_DELAY
	mod._exp_submitted_stage = nil
	mod._exp_submitted_until = 0
end

local function _exp_cleanup(reason)
	search_active = false
	active_search_key = nil
	search_completed = reason == "complete"
	search_restart_key = nil
	search_restart_until = 0
	mod._exp.session_active = false
	_reset_snapshot()
	mod._exp_press_until = 0
	mod._exp_release_until = 0
	mod._exp_move_cooldown = 0
	mod._exp_startup_delay = 0
	mod._exp_submitted_stage = nil
	mod._exp_submitted_until = 0
	mod._exp_prev_cursor = nil
	mod._exp_last_move_at = 0
	active_search_mg = nil
	_reset_move_state()
	_reset_submit_settle()
end

local function _arm_search_session(mg, restart_until)
	local now = _game_time()

	_reset_snapshot()
	mod._exp.session_active = true
	mod._exp_press_until = 0
	mod._exp_release_until = 0
	mod._exp_move_cooldown = 0
	mod._exp_startup_delay = SEARCH_STARTUP_DELAY
	mod._exp_submitted_stage = nil
	mod._exp_submitted_until = 0
	mod._exp_prev_cursor = nil
	mod._exp_last_move_at = 0
	search_active = true
	active_search_key = tostring(mg)
	active_search_mg = mg
	_reset_move_state()
	search_completed = false
	search_restart_key = nil
	search_restart_until = restart_until or (now and now + SEARCH_RESTART_RECOVERY_TIMEOUT or 0)
	_sample_search(mg)
end

local function _is_teardown_stop_error(err)
	local text = tostring(err)

	return text:find("destroyed object of type MinigameExtension", 1, true) ~= nil
		or text:find("UnitReference is not valid", 1, true) ~= nil
end

mod:hook_safe("MinigameDecodeSearch", "start", function(self, player)
	if not mod._is_local_minigame_player(player) then
		if search_active and _is_active_search_mg(self)
			or search_restart_key and search_restart_key == tostring(self)
		then
			_exp_cleanup("ownership_transferred")
		end
		return
	end
	_clear_match_cache(self)

	if S("enable_expedition_auto_solve") then
		_arm_search_session(self)
	end
end)
mod:hook("MinigameDecodeSearch", "stop", function(func, self, ...)
	local unit = self and self._minigame_unit
	local active = _is_active_search_mg(self)
	local cleanup_reason = active and not search_completed and "stop" or nil
	local now = _game_time()
	local restart_until = search_restart_until
	local recoverable_restart = active
		and select(1, ...) == nil
		and not search_completed
		and now ~= nil
		and now <= restart_until

	if unit and Unit.alive(unit) then
		local ok, result = pcall(func, self, ...)
		if not ok then
			if _is_teardown_stop_error(result) then
				if active then _exp_cleanup(cleanup_reason or "stop_teardown_race") end
				return nil
			end

			error(result)
		end

		if active then
			_exp_cleanup(cleanup_reason)

			if recoverable_restart then
				search_restart_key = tostring(self)
				search_restart_until = restart_until
			end
		end
		return result
	end

	if active then
		_exp_cleanup(search_active and not search_completed and "stop_invalid_unit" or nil)
	end
end)
mod:hook_safe("MinigameDecodeSearch", "complete", function(self)
	if _is_active_search_mg(self) or search_restart_key == tostring(self) then
		_exp_cleanup("complete")
	end
end)
mod:hook_safe("MinigameDecodeSearch", "generate_board", _clear_match_cache)
mod:hook_safe("MinigameDecodeSearch", "set_symbols", _clear_match_cache)

function mod._exp_rearm_from_state(state, t)
	if not search_restart_key then return end

	local now = t or _game_time()
	if not now or now > search_restart_until then
		search_restart_key = nil
		search_restart_until = 0
		return
	end
	if search_active or not S("enable_expedition_auto_solve") then return end

	local mg = state and state._minigame
	local player = state and state._player
	if not mg or tostring(mg) ~= search_restart_key then return end
	if not mod._is_local_minigame_player(player) or not _scanner_view_active() then return end
	if mg.is_completed and mg:is_completed() or not _is_gameplay(mg) then return end

	local restart_until = search_restart_until
	_clear_match_cache(mg)
	_arm_search_session(mg, restart_until)
end

local function on_round_end_move() _exp_cleanup(search_active and "round_end" or nil) end
mod._reg("round_end", on_round_end_move)

local function on_setting(id)
	if id == "enable_expedition_auto_solve" then
		_exp_cleanup(search_active and "setting_changed" or nil)
	end
end
mod._reg("setting_changed", on_setting)

local function on_update_exp(dt)
	local exp = mod._exp
	if exp and exp.timer > 0 then exp.timer = math.max(exp.timer - dt, 0) end
	if mod._exp_startup_delay > 0 then
		mod._exp_startup_delay = math.max(mod._exp_startup_delay - dt, 0)
	end
	if mod._exp_move_cooldown > 0 then mod._exp_move_cooldown = math.max(mod._exp_move_cooldown - dt, 0) end

	if not S("enable_expedition_auto_solve") or not exp or not exp.session_active or exp.timer <= 0 or not exp.active then return end

	if mod._exp_startup_delay > 0 then return end

	local stage = exp.stage
	if mod._exp_submitted_stage and stage and mod._exp_submitted_stage ~= stage then
		mod._exp_handle_stage_changed(mod._exp_submitted_stage, stage)
	elseif (mod._exp_submitted_until or 0) > 0 then
		local now = mod._time("gameplay")
		if now and now >= mod._exp_submitted_until then
			mod._exp_submitted_stage = nil
			mod._exp_submitted_until = 0
		end
	end
end
mod._reg("update", on_update_exp)

return true
