-- Smart Seed Reroll (DESIGN.md): BetterBrainer's Symbols reroll, decided from the exact upcoming boards. A terminal's
-- boards all follow from one seed (minigame_decode_symbols.lua:93-141), so with the seed known every reroll's board
-- is known before it is dealt. Without it, BetterBrainer's own reroll decides from the average board.
local HIT_MARGIN = 0.03 -- as BetterBrainer's symbols.lua
local REROLL_MARGIN = 0.15
local REROLL_BASE = 0.2
local MAX_RECONSTRUCTION_BOARDS = 256
local next_random = rawget(math, "next_random")

-- press_time and board_cost are BetterBrainer's (symbols.lua), so both rerolls value a board alike.
local function press_time(target, ready, t0, start, dt, period, spacing, radius)
    local best
    local c = (target - 1) * spacing
    for i = 1, 2 do
        local centre = start + (i == 1 and c or period - c)
        local k = math.ceil((ready - centre - radius) / period - 1e-9)
        for _ = 1, 2 do
            local from = centre - radius + k * period
            local at = t0 + math.ceil((math.max(ready, from) - t0) / dt - 1e-9) * dt
            if at <= from + 2 * radius + 1e-9 then
                if not best or at < best then best = at end
                break
            end
            k = k + 1
        end
    end
    return best
end

local sent = {}
local function board_cost(targets, first, last, t0, start, dt, period, spacing, radius, ack)
    local ready, at = t0, t0
    for s = first, last do
        local i = s - first + 1
        if i >= 3 then ready = math.max(ready, sent[i - 2] + ack) end
        at = press_time(targets[s], ready, t0, start, dt, period, spacing, radius)
        sent[i], ready = at, at + 2 * dt
    end
    return at - t0
end

-- MinigameDecodeSymbols.setup_game with table.shuffle (table.lua:781-797), returning the seed it leaves behind.
local function generate_board(seed, stages, items)
    local symbols, targets = {}, {}
    for i = 1, stages * items do symbols[i] = i end
    for i = #symbols, 2, -1 do
        local swap
        seed, swap = next_random(seed, i)
        symbols[swap], symbols[i] = symbols[i], symbols[swap]
    end
    local previous
    for stage = 1, stages do
        local target
        if previous then
            seed, target = next_random(seed, 1, items - 1)
            if previous <= target then target = target + 1 end
        else
            seed, target = next_random(seed, 1, items)
        end
        targets[stage], previous = target, target
    end
    return { symbols = symbols, targets = targets, post_seed = seed }
end

local function board_matches(mg, board)
    local symbols, targets = mg._symbols, mg._decode_targets
    if type(symbols) ~= "table" or type(targets) ~= "table"
        or #symbols ~= #board.symbols or #targets ~= #board.targets then return false end
    for i = 1, #board.symbols do
        if symbols[i] ~= board.symbols[i] then return false end
    end
    for i = 1, #board.targets do
        if targets[i] ~= board.targets[i] then return false end
    end
    return true
end

-- Clients get no seed: the server hands extension n the level seed + n (minigame_system.lua:30-71), and the client
-- adds the same level extensions. Its board is then found among the boards that seed deals, if it is the only match.
local trackers = setmetatable({}, { __mode = "k" })
local initial_seeds = setmetatable({}, { __mode = "k" })

local function reconstruct(mg)
    local extension = mg._minigame_extension
    local seed = extension and initial_seeds[extension]
    if type(seed) ~= "number" then return nil, "no initial seed" end
    local found, matches = nil, 0
    for _ = 1, MAX_RECONSTRUCTION_BOARDS do
        local board = generate_board(seed, mg._stage_amount, mg._decode_symbols_items_per_stage)
        if board_matches(mg, board) then found, matches = board.post_seed, matches + 1 end
        seed = board.post_seed
    end
    if matches == 1 then return found, "rebuilt" end
    return nil, matches == 0 and "no match" or "ambiguous"
end

return function(ctx)
    local mod = ctx.mod
    local seed = {}
    -- Rerolls this hack: ours, and BetterBrainer's own (its count stays below the limit it is given).
    local rerolls, others = 0, 0
    local decided, decided_limit, rolling, pending, pressed = nil, nil, false, nil, false
    local expected -- the board our last reroll will deal
    local observing, observed_t
    local reroll_t, delay_estimate, rtt, next_ping = nil, nil, 0, 0
    local holds = { action_one_hold = true, interact_hold = true, interact_primary_hold = true, jump_held = true }

    mod:hook("MinigameSystem", "init", function(func, self, context, system_init_data, ...)
        local level_seed = system_init_data and system_init_data.level_seed
        trackers[self] = type(level_seed) == "number" and { next = level_seed } or nil
        return func(self, context, system_init_data, ...)
    end)
    mod:hook("MinigameSystem", "on_add_extension", function(func, self, ...)
        local extension = func(self, ...)
        local tracker = trackers[self]
        if tracker and extension then
            initial_seeds[extension] = tracker.next
            tracker.next = tracker.next + 1
        end
        return extension
    end)

    local function remaining()
        return math.max(0, (ctx.settings.decode_reroll_limit or 0) - rerolls)
    end

    local function left()
        return math.max(0, remaining() - others)
    end

    local function try_reroll(mg, t)
        if not ctx.request_reopen(mg) then return end
        rerolls, reroll_t, rolling, expected, pending = rerolls + 1, t, true, pending.board, nil
        mod:debug("Seed reroll %d of %d", rerolls, ctx.settings.decode_reroll_limit)
    end

    -- Called where BetterBrainer's reroll reads its limit: once per board, at its first synchronized frame before
    -- any press. Returns the limit BetterBrainer's own reroll gets: none when this board is decided here.
    local function decide()
        local mg, t = observing, observed_t
        local start = mg and mg._decode_start_time
        if not start or not t then return remaining() end
        if decided == start then return decided_limit end
        decided, decided_limit, pressed = start, remaining(), false
        if reroll_t then
            local sample = t - reroll_t
            delay_estimate = delay_estimate and delay_estimate + (sample - delay_estimate) * 0.5 or sample
            reroll_t = nil
        end
        local count, prediction = left(), expected
        expected = nil
        if not ctx.settings.enable_decode_smart_reroll or count <= 0 or mg._current_stage ~= 1 or not next_random then
            return decided_limit
        end
        local post, how
        if prediction and board_matches(mg, prediction) then
            post, how = prediction.post_seed, "predicted"
        elseif mg._is_server then
            post, how = mg._seed, "host"
        else
            post, how = reconstruct(mg)
        end
        if type(post) ~= "number" then
            mod:debug("Seed reroll: seed unknown (%s), average board used", tostring(how))
            return decided_limit
        end
        if not mg._is_server and t >= next_ping then
            local connection = Managers.connection
            local host = connection and connection:host()
            local ping = host and Network.ping(host)
            rtt = type(ping) == "number" and ping == ping and ping >= 0 and ping < 2 and ping or 0
            next_ping = t + 1
        end
        local session = Managers.state and Managers.state.game_session
        local dt = session and session.fixed_time_step or 1 / 52
        local sweep, items, stages = mg._decode_symbols_sweep_duration, mg._decode_symbols_items_per_stage, mg._stage_amount
        local period, spacing = 2 * sweep, sweep / (items - 1)
        local radius = math.max(0, spacing * 0.5 - HIT_MARGIN)
        local ack = (mg._is_server and 0 or rtt) + 2 * dt
        local delay = delay_estimate or REROLL_BASE + (mg._is_server and 0 or rtt)
        -- As in BetterBrainer, a reopened board starts at the phase this board was first seen at.
        local phase = (t - start) % period
        local cost = board_cost(mg._decode_targets, 1, stages, t, start, dt, period, spacing, radius, ack)
        local boards, next_seed = {}, post
        for i = 1, count do
            boards[i] = generate_board(next_seed, stages, items)
            next_seed = boards[i].post_seed
        end
        -- Backwards over the known boards: each is played or rerolled by the same rule as the current one.
        local value = board_cost(boards[count].targets, 1, stages, phase, 0, dt, period, spacing, radius, ack)
        for i = count - 1, 1, -1 do
            local board = board_cost(boards[i].targets, 1, stages, phase, 0, dt, period, spacing, radius, ack)
            value = board > delay + value + REROLL_MARGIN and delay + value or board
        end
        value = delay + value
        decided_limit = 0
        if cost <= value + REROLL_MARGIN then
            mod:debug("Seed board kept (%s seed): %.2fs, reroll %.2fs", how, cost, value)
            return 0
        end
        mod:debug("Seed board rerolled (%s seed): %.2fs, reroll %.2fs (delay %.2fs)", how, cost, value, delay)
        pending = { board = boards[1], start = start }
        try_reroll(mg, t)
        return 0
    end

    -- Symbols gets this context: its reroll limit is read through decide().
    local settings = setmetatable({}, { __index = function(_, id)
        if id == "decode_reroll_limit" then return decide() end
        return ctx.settings[id]
    end })
    seed.ctx = setmetatable({ settings = settings, request_reopen = function(mg)
        local accepted = ctx.request_reopen(mg)
        if accepted then others = others + 1 end
        return accepted
    end }, { __index = ctx })

    function seed.wrap(module)
        local base = {}
        for name, value in pairs(module) do base[name] = value end
        function module.observe(mg, t)
            observing, observed_t = mg, t
            -- A reroll the terminal could not take yet (not in view) is tried again until the board's first press.
            if pending and not rolling then
                if pressed or not mg or mg._decode_start_time ~= pending.start then pending = nil else try_reroll(mg, t) end
            end
            return base.observe(mg, t)
        end
        function module.input(action, original, t, source)
            if rolling and holds[action] then return false end
            local value = base.input(action, original, t, source)
            if value == true and holds[action] then pressed = true end
            return value
        end
        function module.resume(mg, t)
            rolling = false
            return base.resume(mg, t)
        end
        function module.reopen_failed()
            rolling, expected = false, nil
            return base.reopen_failed()
        end
        function module.reset(reason)
            rerolls, others, decided, decided_limit, rolling, pending, pressed, expected = 0, 0, nil, nil, false, nil, false, nil
            reroll_t = nil
            if reason == "gameplay_exit" then delay_estimate, rtt, next_ping = nil, 0, 0 end
            return base.reset(reason)
        end
        return module
    end

    return seed
end
