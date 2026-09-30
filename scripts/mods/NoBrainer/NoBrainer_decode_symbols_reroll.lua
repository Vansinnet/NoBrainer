local mod = get_mod("NoBrainer")
local S = mod._S
local next_random = rawget(math, "next_random")

local MAX_REROLLS = 2
local BOARD_SYNC_TIMEOUT = 1.2
local CANCEL_TIMEOUT = 2.5
local REINTERACT_TIMEOUT = 3
local RESTART_TIMEOUT = 2.5
local INITIAL_RETRY_COST = 0.75
local RETRY_COST_ALPHA = 0.3
local MIN_EXPECTED_SAVING = 0.5
local MAX_RECONSTRUCTION_BOARDS = 256
local PRESS_LEAD = 0.095
local PRESS_GRACE = 0.06
local PRESS_DURATION = 0.08
local RELEASE_DURATION = 0.12
local COMPARISON_EPSILON = 0.000001
local PHASE_SAMPLE_COUNT = 32
local MIN_STAGE_READY_DELAY = PRESS_DURATION + RELEASE_DURATION
local STAGE_READY_BUCKET = 0.05
local RESTART_SYNC_MARGIN = 0.12
local SYNC_TARGET_EDGE_MARGIN = 0.03
-- Darktide 1.13.0 sends the Decode Symbols start as fixed_t + LagCompensation.rewind_seconds
-- (1.12.x added milliseconds as seconds), so a client now receives a near-constant start phase.
-- A board is evaluated within the sync wait, so initial_ready at or below this bound is measured
-- start-phase evidence; a larger value means the phase is not deterministic and the uniform
-- phase model is kept. Two consecutive in-bound client evaluations are required before the
-- measured phase is trusted, so a single low sample from a random phase cannot steer decisions.
local MEASURED_PHASE_MAX = 0.5
local MEASURED_PHASE_MIN_STREAK = 2
local MEASURED_PHASE_BUCKET = 0.01

local system_trackers = setmetatable({}, { __mode = "k" })
local extension_initial_seeds = setmetatable({}, { __mode = "k" })
local distribution_cache = {}
local distribution_cache_entries = 0
-- Latest client initial_ready per sync path. The phase follows the game's start-time formula and
-- the mod's sync wait, not the server, so it is kept across terminals in a mission and
-- cleared on mission reset or by an out-of-bound sample.
local measured_phase = { fast = nil, normal = nil, streak = 0 }

local state = {
    phase = "idle",
    attempts = 0,
    minigame_key = nil,
    terminal = nil,
    deadline = 0,
    evaluated_start_time = nil,
    expected_board = nil,
    force_statistical = false,
    cancel_time = nil,
    retry_cost = INITIAL_RETRY_COST,
    retry_samples = 0,
    decision_mode = nil,
    seed_status = nil,
    current_cost = nil,
    alternative_cost = nil,
    expected_saving = nil,
    remaining = nil,
    initial_ready = nil,
    prediction_match = nil,
    fast_sync = false,
    decision_reason = nil,
    stage_ready_delay = MIN_STAGE_READY_DELAY,
    next_phase = nil,
}

local function enabled()
    return S("enable_decode_auto") and S("enable_decode_smart_reroll")
end

local function now()
    return mod._time("gameplay")
end

local function scanner_view_active()
    local ui = Managers.ui
    return ui and ui:view_active("scanner_display_view") or false
end

local function reset_state(keep_retry_cost)
    local retry_cost = keep_retry_cost and state.retry_samples > 0 and state.retry_cost or INITIAL_RETRY_COST
    local retry_samples = keep_retry_cost and state.retry_samples or 0

    state.phase = "idle"
    state.attempts = 0
    state.minigame_key = nil
    state.terminal = nil
    state.deadline = 0
    state.evaluated_start_time = nil
    state.expected_board = nil
    state.force_statistical = false
    state.cancel_time = nil
    state.retry_cost = retry_cost
    state.retry_samples = retry_samples
    state.decision_mode = nil
    state.seed_status = nil
    state.current_cost = nil
    state.alternative_cost = nil
    state.expected_saving = nil
    state.remaining = nil
    state.initial_ready = nil
    state.prediction_match = nil
    state.fast_sync = false
    state.decision_reason = nil
    state.stage_ready_delay = MIN_STAGE_READY_DELAY
    state.next_phase = nil
end

local function client_retry_floor(minigame)
    if minigame._is_server == true then
        return nil
    end

    local get_rtt = mod._ds_network_rtt
    local rtt = type(get_rtt) == "function" and get_rtt() or nil

    return type(rtt) == "number" and rtt >= 0 and rtt * 2 + RESTART_SYNC_MARGIN or nil
end

local function apply_retry_floor(minigame)
    local retry_floor = client_retry_floor(minigame)
    if retry_floor then
        state.retry_cost = math.max(state.retry_cost, retry_floor)
    end
end

local function exact_retry_cost(minigame)
    if state.retry_samples > 0 then
        return state.retry_cost
    end

    return client_retry_floor(minigame) or state.retry_cost
end

local function stage_ready_delay(minigame)
    local get_delay = mod._ds_stage_ready_delay
    local delay = type(get_delay) == "function" and get_delay(minigame._is_server == true)
        or MIN_STAGE_READY_DELAY

    delay = math.max(MIN_STAGE_READY_DELAY, delay or 0)

    return math.floor(delay / STAGE_READY_BUCKET + 0.5) * STAGE_READY_BUCKET
end

local function clear_decision()
    state.decision_mode = nil
    state.seed_status = nil
    state.current_cost = nil
    state.alternative_cost = nil
    state.expected_saving = nil
    state.remaining = nil
    state.initial_ready = nil
    state.prediction_match = nil
    state.fast_sync = false
    state.decision_reason = nil
    state.stage_ready_delay = nil
    state.next_phase = nil
end

local function accept_board(reason)
    state.phase = "accepted"
    state.deadline = 0
    state.expected_board = nil
    state.decision_reason = reason or state.decision_reason
end

local function sequence_equal(left, right, count)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= count or #right ~= count then
        return false
    end

    for i = 1, count do
        if left[i] ~= right[i] then
            return false
        end
    end

    return true
end

local function valid_board(minigame)
    local stage_amount = minigame and minigame._stage_amount
    local items_per_stage = minigame and minigame._decode_symbols_items_per_stage
    local symbols = minigame and minigame._symbols
    local targets = minigame and minigame._decode_targets

    if stage_amount ~= 4 or items_per_stage ~= 7 or type(symbols) ~= "table" or type(targets) ~= "table" then
        return false
    end

    local total_items = stage_amount * items_per_stage
    if #symbols ~= total_items or #targets ~= stage_amount then
        return false
    end

    local seen = {}
    for i = 1, total_items do
        local symbol = symbols[i]
        if type(symbol) ~= "number" or symbol < 1 or symbol > total_items or seen[symbol] then
            return false
        end
        seen[symbol] = true
    end

    for i = 1, stage_amount do
        local target = targets[i]
        if type(target) ~= "number" or target < 1 or target > items_per_stage then
            return false
        end
        if i > 1 and target == targets[i - 1] then
            return false
        end
    end

    return true
end

local function generate_board(seed, stage_amount, items_per_stage)
    if type(seed) ~= "number" then
        return nil
    end

    local total_items = stage_amount * items_per_stage
    local symbols = {}
    for i = 1, total_items do
        symbols[i] = i
    end

    for i = total_items, 2, -1 do
        local swap
        seed, swap = next_random(seed, i)
        symbols[swap], symbols[i] = symbols[i], symbols[swap]
    end

    local targets = {}
    local previous
    for stage = 1, stage_amount do
        local target
        if previous then
            seed, target = next_random(seed, 1, items_per_stage - 1)
            if previous <= target then
                target = target + 1
            end
        else
            seed, target = next_random(seed, 1, items_per_stage)
        end

        targets[stage] = target
        previous = target
    end

    return {
        symbols = symbols,
        targets = targets,
        post_seed = seed,
    }
end

local function next_periodic_time(at, phase, period)
    if at <= phase then
        return phase
    end

    return phase + math.ceil((at - phase) / period) * period
end

local function board_cost(targets, sweep_duration, items_per_stage, initial_ready, ready_delay, startup_safe)
    local period = sweep_duration * 2
    local margin = sweep_duration / (items_per_stage - 1)
    local ready_time = initial_ready
    local start_ready = initial_ready
    ready_delay = ready_delay or MIN_STAGE_READY_DELAY

    for stage = 1, #targets do
        local center = (targets[stage] - 1) * margin
        local press_time
        if stage == 1 and startup_safe then
            local phase = initial_ready % period
            local cursor = phase > sweep_duration and period - phase or phase
            local edge_margin = margin * 0.5 - math.abs(cursor - center)
            if edge_margin >= SYNC_TARGET_EDGE_MARGIN then
                press_time = ready_time
            end
        end
        if not press_time then
            local forward = next_periodic_time(ready_time - PRESS_GRACE, center, period)
            local reverse = next_periodic_time(ready_time - PRESS_GRACE, period - center, period)
            local center_time = math.min(forward, reverse)

            press_time = math.max(center_time - PRESS_LEAD, ready_time)
        end

        if stage == #targets then
            return press_time - start_ready
        end

        ready_time = press_time + ready_delay
    end

    return ready_time
end

local function distribution(sweep_duration, items_per_stage, ready_delay, startup_safe, fixed_phase)
    if items_per_stage ~= 7 then
        return nil
    end

    local cache_key = table.concat({ sweep_duration, items_per_stage, ready_delay, tostring(startup_safe), tostring(fixed_phase) }, ":")
    local cached = distribution_cache[cache_key]
    if cached then
        return cached
    end

    local costs = {}
    local targets = { 0, 0, 0, 0 }
    local total = 0

    for first = 1, items_per_stage do
        targets[1] = first
        for second = 1, items_per_stage do
            if second ~= first then
                targets[2] = second
                for third = 1, items_per_stage do
                    if third ~= second then
                        targets[3] = third
                        for fourth = 1, items_per_stage do
                            if fourth ~= third then
                                targets[4] = fourth
                                local period = sweep_duration * 2
                                local samples = fixed_phase and 1 or PHASE_SAMPLE_COUNT
                                for phase_index = 1, samples do
                                    local initial_ready = fixed_phase or (phase_index - 0.5) * period / PHASE_SAMPLE_COUNT
                                    local cost = board_cost(targets, sweep_duration, items_per_stage, initial_ready, ready_delay, startup_safe)
                                    costs[#costs + 1] = cost
                                    total = total + cost
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    cached = {
        costs = costs,
        mean = total / #costs,
    }
    if distribution_cache_entries >= 3 then
        table.clear(distribution_cache)
        distribution_cache_entries = 0
    end
    distribution_cache[cache_key] = cached
    distribution_cache_entries = distribution_cache_entries + 1

    return cached
end

local function statistical_threshold(sweep_duration, items_per_stage, ready_delay, startup_safe, remaining, next_phase)
    local values = distribution(sweep_duration, items_per_stage, ready_delay, startup_safe, next_phase)
    if not values then
        return nil
    end

    local expected = values.mean
    for _ = 1, remaining - 1 do
        local threshold = state.retry_cost + expected
        local cutoff = threshold + MIN_EXPECTED_SAVING
        local total = 0
        for i = 1, #values.costs do
            local cost = values.costs[i]
            total = total + (cost - cutoff > COMPARISON_EPSILON and threshold or cost)
        end
        expected = total / #values.costs
    end

    return state.retry_cost + expected
end

local function expected_phase_cost(targets, sweep_duration, items_per_stage, ready_delay, startup_safe, reroll_value)
    local period = sweep_duration * 2
    local total = 0

    for phase_index = 1, PHASE_SAMPLE_COUNT do
        local initial_ready = (phase_index - 0.5) * period / PHASE_SAMPLE_COUNT
        local cost = board_cost(targets, sweep_duration, items_per_stage, initial_ready, ready_delay, startup_safe)

        if reroll_value and cost - reroll_value - MIN_EXPECTED_SAVING > COMPARISON_EPSILON then
            total = total + reroll_value
        else
            total = total + cost
        end
    end

    return total / PHASE_SAMPLE_COUNT
end

-- A known future board is valued at the measured start phase when one exists, else over the
-- uniform phase distribution.
local function board_value(targets, sweep_duration, items_per_stage, ready_delay, startup_safe, reroll_value, next_phase)
    if not next_phase then
        return expected_phase_cost(targets, sweep_duration, items_per_stage, ready_delay, startup_safe, reroll_value)
    end

    local cost = board_cost(targets, sweep_duration, items_per_stage, next_phase, ready_delay, startup_safe)
    if reroll_value and cost - reroll_value - MIN_EXPECTED_SAVING > COMPARISON_EPSILON then
        return reroll_value
    end

    return cost
end

local function quantize_phase(phase)
    return math.floor(phase / MEASURED_PHASE_BUCKET + 0.5) * MEASURED_PHASE_BUCKET
end

local function record_measured_phase(minigame, initial_ready)
    if minigame._is_server == true then
        return
    end

    if initial_ready > MEASURED_PHASE_MAX then
        measured_phase.fast, measured_phase.normal, measured_phase.streak = nil, nil, 0
        return
    end

    measured_phase.streak = measured_phase.streak + 1
    if state.fast_sync then
        measured_phase.fast = initial_ready
    else
        measured_phase.normal = initial_ready
    end
end

-- A predicted board restarts on the fast sync path; an unknown board on the normal path.
local function predicted_next_phase(minigame, predicted)
    if minigame._is_server == true or measured_phase.streak < MEASURED_PHASE_MIN_STREAK then
        return nil
    end

    local phase = predicted and (measured_phase.fast or measured_phase.normal) or measured_phase.normal
    return phase and quantize_phase(phase) or nil
end

local function board_matches(minigame, board)
    local stage_amount = minigame._stage_amount
    local total_items = stage_amount * minigame._decode_symbols_items_per_stage

    return board
        and sequence_equal(minigame._symbols, board.symbols, total_items)
        and sequence_equal(minigame._decode_targets, board.targets, stage_amount)
end

function mod._ds_reroll_predicted_sync_ready(minigame, previous_start_time)
    if state.phase ~= "evaluating" or state.minigame_key ~= tostring(minigame) or not state.expected_board then
        return false
    end

    local start_time = minigame and minigame._decode_start_time
    if type(start_time) ~= "number" or start_time == previous_start_time or minigame._current_stage ~= 1 then
        return false
    end

    local matched = board_matches(minigame, state.expected_board)
    state.fast_sync = matched

    return matched
end

local function reconstructed_post_seed(minigame)
    local extension = minigame and minigame._minigame_extension
    local initial_seed = extension and extension_initial_seeds[extension]
    if type(initial_seed) ~= "number" then
        return nil, "missing_initial_seed"
    end

    local stage_amount = minigame._stage_amount
    local items_per_stage = minigame._decode_symbols_items_per_stage
    local seed = initial_seed
    local matched_seed
    local matches = 0

    for _ = 1, MAX_RECONSTRUCTION_BOARDS do
        local board = generate_board(seed, stage_amount, items_per_stage)
        if not board then
            return nil, "generation_failed"
        end

        if board_matches(minigame, board) then
            matches = matches + 1
            matched_seed = board.post_seed
        end

        seed = board.post_seed
    end

    if matches == 1 then
        return matched_seed, "reconstructed"
    end

    return nil, matches == 0 and "no_match" or "ambiguous"
end

local function exact_choice(minigame, post_seed, current_cost, ready_delay, startup_safe, remaining, retry_cost, next_phase)
    local stage_amount = minigame._stage_amount
    local items_per_stage = minigame._decode_symbols_items_per_stage
    local sweep_duration = minigame._decode_symbols_sweep_duration
    local seed = post_seed
    local boards = {}
    local first_board

    for rerolls = 1, remaining do
        local board = generate_board(seed, stage_amount, items_per_stage)
        if not board then
            break
        end

        boards[rerolls] = board
        seed = board.post_seed
    end

    first_board = boards[1]
    if not first_board then
        return false, nil, nil
    end

    local future_value = board_value(boards[#boards].targets, sweep_duration, items_per_stage, ready_delay, startup_safe, nil, next_phase)
    for index = #boards - 1, 1, -1 do
        local reroll_value = retry_cost + future_value
        future_value = board_value(boards[index].targets, sweep_duration, items_per_stage, ready_delay, startup_safe, reroll_value, next_phase)
    end

    local reroll_value = retry_cost + future_value
    local should_reroll = current_cost - reroll_value - MIN_EXPECTED_SAVING > COMPARISON_EPSILON

    return should_reroll, first_board, reroll_value
end

local function can_reinteract()
    local terminal = state.terminal
    if not terminal or not Unit.alive(terminal) or scanner_view_active() then
        return false
    end

    local player_manager = Managers.player
    local player = player_manager and player_manager:local_player_safe(1)
    local player_unit = player and player.player_unit
    if not player_unit or not Unit.alive(player_unit) then
        return false
    end

    local interactor = ScriptUnit.has_extension(player_unit, "interactor_system")
    if not interactor or interactor:is_interacting() or interactor:target_unit() ~= terminal then
        return false
    end

    local decoder = ScriptUnit.has_extension(terminal, "decoder_device_system")
    return decoder ~= nil
        and decoder:interaction_allowed()
        and interactor:can_interact(terminal, "decoding")
end

local function begin_evaluation(minigame, preserve_attempts)
    local game_time = now()
    if not game_time then
        reset_state(true)
        return
    end

    if not preserve_attempts then
        state.attempts = 0
        state.expected_board = nil
        state.force_statistical = false
        state.cancel_time = nil
    end

    state.phase = "evaluating"
    state.minigame_key = tostring(minigame)
    state.terminal = minigame._minigame_unit
    state.deadline = game_time + BOARD_SYNC_TIMEOUT
    state.evaluated_start_time = nil
    clear_decision()
end

function mod._ds_reroll_start(minigame)
    if not enabled() then
        reset_state(true)
        return
    end

    local key = tostring(minigame)
    local terminal = minigame and minigame._minigame_unit
    local same_session = state.minigame_key == key and state.terminal == terminal
    if same_session and (state.phase == "cancel_sent" or state.phase == "await_server_stop") then
        return
    end

    local continuing = state.phase == "await_restart"
        and same_session

    if not continuing then
        reset_state(true)
    end

    begin_evaluation(minigame, continuing)
end

function mod._ds_reroll_stop(minigame, stop_arg)
    if state.minigame_key ~= tostring(minigame) then
        return
    end

    local game_time = now()
    if state.phase == "cancel_sent" then
        if minigame._is_server == true or stop_arg == nil then
            state.phase = "reinteract"
            state.deadline = game_time and game_time + REINTERACT_TIMEOUT or 0
        else
            state.phase = "await_server_stop"
            state.deadline = game_time and game_time + CANCEL_TIMEOUT or 0
        end
    elseif state.phase == "await_server_stop" then
        if stop_arg == nil then
            state.phase = "reinteract"
            state.deadline = game_time and game_time + REINTERACT_TIMEOUT or 0
        end
    elseif state.phase ~= "reinteract" and state.phase ~= "await_restart" then
        reset_state(true)
    end
end

function mod._ds_reroll_complete(minigame)
    if state.minigame_key == tostring(minigame) then
        reset_state(true)
    end
end

function mod._ds_reroll_abort(minigame)
    if state.minigame_key == tostring(minigame) then
        reset_state(true)
    end
end

function mod._ds_reroll_active()
    return state.phase == "evaluating"
end

function mod._ds_reroll_blocks_solver()
    return state.phase == "evaluating"
        or state.phase == "cancel_pending"
        or state.phase == "cancel_sent"
        or state.phase == "await_server_stop"
        or state.phase == "reinteract"
        or state.phase == "await_restart"
end

function mod._ds_reroll_evaluate(minigame, game_time, sync_ready)
    if state.phase ~= "evaluating" or state.minigame_key ~= tostring(minigame) then
        return mod._ds_reroll_blocks_solver()
    end

    if not enabled() then
        reset_state(true)
        return false
    end

    if not game_time or game_time > state.deadline then
        accept_board("sync_timeout")
        return false
    end

    if not sync_ready or not valid_board(minigame) or type(minigame._decode_start_time) ~= "number" then
        return true
    end

    if minigame._current_stage ~= 1 or minigame._current_state ~= "gameplay" then
        accept_board("invalid_stage_or_state")
        return false
    end

    local start_time = minigame._decode_start_time
    if state.evaluated_start_time == start_time then
        return state.phase ~= "accepted"
    end
    state.evaluated_start_time = start_time

    local predicted_post_seed
    if state.expected_board then
        if board_matches(minigame, state.expected_board) then
            predicted_post_seed = state.expected_board.post_seed
            state.prediction_match = true
        else
            state.force_statistical = true
            state.prediction_match = false
        end
        state.expected_board = nil
    end

    if state.cancel_time then
        local observed_now = now()
        local observed_cost = observed_now and observed_now - state.cancel_time
        if observed_cost and observed_cost > 0 and observed_cost < REINTERACT_TIMEOUT + RESTART_TIMEOUT then
            state.retry_cost = observed_cost > state.retry_cost
                and observed_cost
                or state.retry_cost + (observed_cost - state.retry_cost) * RETRY_COST_ALPHA
            state.retry_samples = state.retry_samples + 1
        end
        state.cancel_time = nil
    end

    apply_retry_floor(minigame)

    local remaining = MAX_REROLLS - state.attempts
    if remaining <= 0 then
        accept_board("reroll_limit")
        return false
    end

    local targets = minigame._decode_targets
    local sweep_duration = minigame._decode_symbols_sweep_duration
    local items_per_stage = minigame._decode_symbols_items_per_stage
    local initial_ready = (game_time - minigame._decode_start_time) % (sweep_duration * 2)
    local ready_delay = stage_ready_delay(minigame)
    local startup_safe = minigame._is_server ~= true

    local current_cost = board_cost(targets, sweep_duration, items_per_stage, initial_ready, ready_delay, startup_safe)
    local should_reroll = false
    local next_board
    local alternative_cost

    state.current_cost = current_cost
    state.remaining = remaining
    state.initial_ready = initial_ready
    state.stage_ready_delay = ready_delay
    record_measured_phase(minigame, initial_ready)

    if not state.force_statistical then
        local post_seed = predicted_post_seed
        if predicted_post_seed then
            state.seed_status = "predicted_match"
        end
        if not post_seed and minigame._is_server == true and type(minigame._seed) == "number" then
            post_seed = minigame._seed
            state.seed_status = "host"
        elseif not post_seed and minigame._is_server ~= true then
            local reconstruction_status
            post_seed, reconstruction_status = reconstructed_post_seed(minigame)
            state.seed_status = reconstruction_status
        end

        if post_seed then
            local retry_cost = exact_retry_cost(minigame)
            local next_phase = predicted_next_phase(minigame, true)
            state.next_phase = next_phase
            should_reroll, next_board, alternative_cost = exact_choice(minigame, post_seed, current_cost, ready_delay, startup_safe, remaining, retry_cost, next_phase)
            if next_board then
                state.retry_cost = retry_cost
            end
            state.decision_mode = "exact"
        end
    end

    if not should_reroll and not next_board then
        local next_phase = predicted_next_phase(minigame, false)
        state.next_phase = next_phase
        local threshold = statistical_threshold(sweep_duration, items_per_stage, ready_delay, startup_safe, remaining, next_phase)
        alternative_cost = threshold
        state.decision_mode = "statistical"
        state.seed_status = state.seed_status or (state.force_statistical and "prediction_mismatch" or "unavailable")
        if threshold and current_cost - threshold - MIN_EXPECTED_SAVING > COMPARISON_EPSILON then
            should_reroll = true
        end
    end

    state.alternative_cost = alternative_cost
    state.expected_saving = alternative_cost and current_cost - alternative_cost or nil

    if not should_reroll then
        accept_board("current_faster")
        return false
    end

    state.expected_board = next_board
    state.phase = "cancel_pending"
    state.deadline = game_time + CANCEL_TIMEOUT
    mod._ds_submitted_stage = nil
    mod._ds_submitted_until = 0
    mod._ds_press_until = 0
    mod._ds_release_until = 0
    mod._ds_submit_time = nil

    return true
end

function mod._ds_reroll_input(action, result, source)
    if not enabled() then
        return result
    end

    local game_time = now()
    if not game_time then
        reset_state(true)
        return result
    end

    if action == "action_two_pressed" and state.phase == "cancel_pending" and source == "input_service" then
        state.phase = "cancel_sent"
        state.attempts = state.attempts + 1
        state.cancel_time = game_time
        state.deadline = game_time + CANCEL_TIMEOUT
        return true
    end

    if action == "interact_pressed" and state.phase == "reinteract" and source == "input_service"
        and can_reinteract()
    then
        state.phase = "await_restart"
        state.deadline = game_time + RESTART_TIMEOUT
        return true
    end

    return result
end

function mod._ds_reroll_snapshot()
    return {
        enabled = enabled(),
        phase = state.phase,
        attempts = state.attempts,
        max_attempts = MAX_REROLLS,
        deadline = state.deadline,
        minigame_key = state.minigame_key,
        terminal_alive = state.terminal ~= nil and Unit.alive(state.terminal) or false,
        evaluated_start_time = state.evaluated_start_time,
        expected_board = state.expected_board ~= nil,
        force_statistical = state.force_statistical,
        cancel_time = state.cancel_time,
        retry_cost = state.retry_cost,
        retry_samples = state.retry_samples,
        decision_mode = state.decision_mode,
        seed_status = state.seed_status,
        current_cost = state.current_cost,
        alternative_cost = state.alternative_cost,
        expected_saving = state.expected_saving,
        remaining = state.remaining,
        initial_ready = state.initial_ready,
        prediction_match = state.prediction_match,
        fast_sync = state.fast_sync,
        next_phase = state.next_phase,
        measured_phase_fast = measured_phase.fast,
        measured_phase_normal = measured_phase.normal,
        decision_reason = state.decision_reason,
        stage_ready_delay = state.stage_ready_delay,
        stage_ack_cost = mod._ds_stage_ack_cost,
        stage_ack_samples = mod._ds_stage_ack_samples,
        last_stage_ack = mod._ds_last_stage_ack,
    }
end

function mod._ds_reroll_phase()
    return state.phase, state.attempts
end

local function on_update()
    if state.phase == "idle" or state.phase == "accepted" then
        return
    end

    local game_time = now()
    if not game_time then
        reset_state(true)
        return
    end

    if state.deadline > 0 and game_time > state.deadline then
        if state.phase == "evaluating" or state.phase == "cancel_pending" then
            accept_board(state.phase == "evaluating" and "sync_timeout" or "cancel_timeout")
        else
            reset_state(true)
        end
    end
end

local function on_setting(id)
    if id == "enable_decode_auto" or id == "enable_decode_smart_reroll" then
        reset_state(true)
    end
end

local function on_round_end()
    reset_state(false)
    measured_phase.fast, measured_phase.normal, measured_phase.streak = nil, nil, 0
end

mod._reg("update", on_update)
mod._reg("setting_changed", on_setting)
mod._reg("round_end", on_round_end)

mod:hook("MinigameSystem", "init", function(func, self, context, system_init_data, ...)
    local level_seed = system_init_data and system_init_data.level_seed
    system_trackers[self] = type(level_seed) == "number" and {
        level_seed = level_seed,
        next_offset = 0,
    } or nil

    return func(self, context, system_init_data, ...)
end)

mod:hook("MinigameSystem", "on_add_extension", function(func, self, world, unit, extension_name, extension_init_data, ...)
    local tracker = system_trackers[self]
    local offset = tracker and tracker.next_offset
    local extension = func(self, world, unit, extension_name, extension_init_data, ...)

    if tracker and extension then
        extension_initial_seeds[extension] = tracker.level_seed + offset
        tracker.next_offset = offset + 1
    end

    return extension
end)

return true
