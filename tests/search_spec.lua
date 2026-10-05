-- Run from the workspace root with tools/luajit/luajit.exe (see README.md).
assert(jit and jit.version, "LuaJIT required")
local H = dofile("mods/active/NoBrainer/tests/fixture.lua")
local baseline = arg[1] == "--baseline"
assert(arg[1] == nil or baseline, "usage: search_spec.lua [--baseline]")
local fixture = H.factory()
local eq = H.eq
local passed, failed = 0, 0
local function test(name, body)
    local ok, err = xpcall(body, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end
local SPEED5 = { expedition_solve_speed = 5, enable_scan = false, enable_auto_scan = false }
local TRANSITION = 0.25

print("NoBrainer Search tests | " .. jit.version .. " | source 1.13.0 | "
    .. (baseline and "BASELINE expectations" or "CURRENT runtime"))

-- An online (or local-server) Search on a chosen board seed.
local function open(seed, values, delay, local_server)
    local f = fixture(values or SPEED5)
    local Search = f.env.MinigameDecodeSearch
    local init = Search.init
    Search.init = function(self, unit, is_server, _, context) return init(self, unit, is_server, 1000 + seed * 7, context) end
    f:open("decode_search", not local_server, delay or 0.05)
    Search.init = init
    return f
end

-- Server-side record: stage-advancing presses, cursor moves and mistakes.
local function record(f)
    local log = { presses = {}, moves = {} }
    local press = f.server.on_action_pressed
    f.server.on_action_pressed = function(self, t)
        local before = self._current_stage
        local result = press(self, t)
        if self._current_stage > before then log.presses[#log.presses + 1] = { t = t, stage = self._current_stage } end
        return result
    end
    local axis = f.server.on_axis_set
    f.server.on_axis_set = function(self, t, x, y)
        local cx, cy = self._cursor_position.x, self._cursor_position.y
        local result = axis(self, t, x, y)
        if cx ~= self._cursor_position.x or cy ~= self._cursor_position.y then
            log.moves[#log.moves + 1] = { t = t, stage = self._current_stage }
        end
        return result
    end
    return log
end

local function solve(f, limit)
    local origin = f.t
    for frame = 1, limit or 3000 do
        f:tick(frame)
        if f.server:is_completed() and (not f.client or f.client:is_completed()) then return f.t - origin end
    end
end

-- Delay from each stage-advancing press to the next stage's first server move.
local function leads(log)
    local gaps = {}
    for _, press in ipairs(log.presses) do
        for _, move in ipairs(log.moves) do
            if move.stage == press.stage and move.t >= press.t then gaps[#gaps + 1] = move.t - press.t; break end
        end
    end
    return gaps
end

local function mean(list) local s = 0; for _, v in ipairs(list) do s = s + v end; return #list > 0 and s / #list or 0 end

for _, delay in ipairs({ 0.03, 0.165 }) do
    test("Held first step registers on the first gameplay frame, receipt delay=" .. delay, function()
        local gaps, time = {}, 0
        for seed = 1, 40 do
            local f = open(seed, nil, delay)
            local log = record(f)
            local elapsed = solve(f)
            assert(elapsed, "seed " .. seed .. ": solve stalled")
            eq(f.server._mistakes, 0, "seed " .. seed .. ": mistake")
            for _, gap in ipairs(leads(log)) do
                if not baseline then assert(gap < TRANSITION + 0.05, "seed " .. seed .. ": first step " .. gap .. "s after the press") end
                gaps[#gaps + 1] = gap
            end
            time = time + elapsed
        end
        print(string.format("  press to next first step %.3fs, mean solve %.3fs", mean(gaps), time / 40))
    end)
end

local function late_resume(f, extra)
    local native = f.server.set_state
    f.server.set_state = function(self, state)
        local result = native(self, state)
        if self._current_state == f.settings.game_states.transition then
            self._state_start_time = self._state_start_time + extra
        end
        return result
    end
end

for _, extra in ipairs({ 0.02, 0.1, 0.4 }) do
    test(string.format("Server resumes %.2fs late: no mistake, no stall", extra), function()
        local time = 0
        for seed = 1, 20 do
            local f = open(seed)
            late_resume(f, extra)
            local elapsed = solve(f)
            assert(elapsed, "seed " .. seed .. ": solve stalled")
            eq(f.server._mistakes, 0, "seed " .. seed .. ": mistake")
            time = time + elapsed
        end
        print(string.format("  mean solve %.3fs", time / 20))
    end)
end

-- The server replays the last received input frame while newer frames are late
-- (authoritative_player_input_handler.lua:153-156), starting at a stage's first server move.
local function late_input(f, log, stage, frames)
    local consume, received, lag_until = f.consume, 0, nil
    f.consume = function(self, state, frame, t)
        if state == self.server_state then
            if not lag_until then
                for _, move in ipairs(log.moves) do
                    if move.stage == stage then lag_until = frame + frames; break end
                end
            end
            if lag_until and frame <= lag_until then frame = received else received = frame end
        end
        return consume(self, state, frame, t)
    end
end

for _, frames in ipairs({ 8, 20 }) do
    test(string.format("Input replay (%d frames) after the stage-2 first step: never a mistake", frames), function()
        local finished = 0
        for seed = 1, 30 do
            local f = open(seed)
            local log = record(f)
            late_input(f, log, 2, frames)
            local elapsed = solve(f, 4000)
            eq(f.server._mistakes, 0, "seed " .. seed .. ": mistake")
            if elapsed then finished = finished + 1 end
        end
        print(string.format("  %d of 30 finished", finished))
        eq(finished, 30, "every board finishes")
    end)
end

local function delay_cursor(f, extra, ordered)
    local send, floor = f.send, 0
    f.send = function(self, to, name, ...)
        send(self, to, name, ...)
        local item = self.queue[#self.queue]
        if not item or item.name ~= name then return end
        if name == "rpc_minigame_sync_decode_search_set_cursor" then item.at = item.at + extra end
        if ordered then item.at = math.max(item.at, floor); floor = item.at end
    end
end

for _, case in ipairs({ { 0.3, false }, { 0.8, false }, { 0.8, true } }) do
    test(string.format("Cursor receipts %.1fs late%s: never a mistake", case[1], case[2] and ", in order" or ""), function()
        local finished = 0
        for seed = 1, 20 do
            local f = open(seed)
            delay_cursor(f, case[1], case[2])
            local elapsed = solve(f, 4000)
            eq(f.server._mistakes, 0, "seed " .. seed .. ": mistake")
            if elapsed then finished = finished + 1 end
        end
        print(string.format("  %d of 20 finished", finished))
        eq(finished, 20, "every board finishes")
    end)
end

test("A press the server never applied: no held step into the old stage", function()
    for seed = 1, 10 do
        local f = open(seed)
        local log = record(f)
        local press, dropped = f.server.on_action_pressed, false
        f.server.on_action_pressed = function(self, t)
            if not dropped and self._current_stage == 1 then dropped = true; return end
            return press(self, t)
        end
        assert(solve(f, 4000), "seed " .. seed .. ": solve stalled")
        eq(f.server._mistakes, 0)
    end
end)

test("Local server (solo/host): no hold needed, first step on the first gameplay frame, zero mistakes", function()
    local gaps, time = {}, 0
    for seed = 1, 30 do
        local f = open(seed, nil, nil, true)
        local log = record(f)
        local elapsed = solve(f)
        assert(elapsed, "seed " .. seed .. ": solve stalled")
        eq(f.server._mistakes, 0)
        for _, gap in ipairs(leads(log)) do
            if not baseline then assert(gap < TRANSITION + 0.05, "seed " .. seed .. ": first step " .. gap .. "s after the press") end
            gaps[#gaps + 1] = gap
        end
        time = time + elapsed
    end
    print(string.format("  press to next first step %.3fs, mean solve %.3fs", mean(gaps), time / 30))
end)

test("Speed 3 never holds a step across the transition", function()
    for seed = 1, 10 do
        local f = open(seed, { expedition_solve_speed = 3, enable_scan = false, enable_auto_scan = false })
        local log = record(f)
        assert(solve(f, 4000), "seed " .. seed .. ": solve stalled")
        eq(f.server._mistakes, 0)
        for _, gap in ipairs(leads(log)) do assert(gap > TRANSITION + 0.1, "speed 3 step during the transition") end
    end
end)

-- Abort mid-stage and reopen the same terminal: the client keeps the old cursor and gameplay state until the
-- server's setup_game recentre arrives (minigame_decode_search.lua:80-85). Variants: a solver setting changed
-- between abort and reopen; the abort on the target with receipts stalled past the stale wait.
local function reopen_case(seed, mode)
    local f = open(seed, nil, 0.08)
    local gameplay = f.settings.game_states.gameplay
    local lines = {}
    f.mod.debug = function(_, message, ...) lines[#lines + 1] = string.format(message, ...) end
    local frame, c = 0, nil
    repeat
        frame = frame + 1
        f:tick(frame)
        c = f.client:cursor_position()
    until frame > 3000 or f.client:is_completed() or f.client:current_stage() >= 2
        and f.client:state() == gameplay and c and (c.x ~= 3 or c.y ~= 2)
        and (mode ~= "target" or f.client:is_on_target())
    if f.client:is_completed() or frame > 3000 then return nil end
    -- Land every old-session receipt first; the server then drops the old session's input.
    f:deliver(true)
    c = f.client:cursor_position()
    if c.x == 3 and c.y == 2 then return nil end
    f.local_state:on_exit(f.player.player_unit, f.t, "walking")
    f.server:stop(false)
    if mode == "settings" then f:set("expedition_solve_speed", 5) end
    if mode == "target" then
        local deliver, until_t = f.deliver, f.t + 1.0
        f.deliver = function(self, all) if (self.transport_t or self.t) >= until_t then return deliver(self, all) end end
    end
    f.server:setup_game()
    f.server:start(f.remote)
    f.client:start(f.player)
    f.local_state, f.server_state = f:state(f.client, f.player), f:state(f.server, f.remote)
    local consume, reopen_frame = f.consume, frame
    f.consume = function(self, state, n, ...)
        if state == self.server_state and n <= reopen_frame then return end
        return consume(self, state, n, ...)
    end
    f:consume(f.local_state, frame)
    local mark, reopened, first = #lines, f.t, nil
    for next_frame = frame + 1, frame + 3000 do
        f:tick(next_frame)
        if not first then
            for i = mark + 1, #lines do
                if lines[i]:find("^Search move") then first = f.t - reopened; break end
            end
        end
        if f.server:is_completed() and f.client:is_completed() then break end
    end
    local resyncs = 0
    for i = mark + 1, #lines do if lines[i]:find("^Search resync") then resyncs = resyncs + 1 end end
    return f, first or 0, resyncs
end

for _, mode in ipairs({ "plain", "settings", "target" }) do
    test("Reopen with the cursor off-centre (" .. mode .. "): waits for the recentre, no mistake", function()
        local waits, checked = {}, 0
        for seed = 1, 20 do
            local f, first, resyncs = reopen_case(seed, mode)
            if f then
                checked = checked + 1
                assert(f.server:is_completed(), "seed " .. seed .. ": reopen stalled")
                eq(f.server._mistakes, 0, "seed " .. seed .. ": mistake")
                if not baseline and mode ~= "target" then eq(resyncs, 0, "seed " .. seed .. ": resynchronized") end
                waits[#waits + 1] = first
            end
        end
        assert(checked >= 10, "too few off-centre reopens: " .. checked)
        print(string.format("  %d reopens, reopen to first move %.3fs", checked, mean(waits)))
    end)
end

-- Input stalls: the server runs each frame on the newest input it has (authoritative_player_input_handler
-- .lua:153-156), so a stall that starts on a direction frame repeats that direction after 0.25 s, past a cell
-- the client already saw confirmed. At high ping the press used to reach the server after that repeat.
local function stall(f, stage, offset, frames)
    local moved, received, from, to = false, 0, nil, nil
    local axis = f.server.on_axis_set
    f.server.on_axis_set = function(self, t, x, y)
        local cx, cy = self._cursor_position.x, self._cursor_position.y
        local result = axis(self, t, x, y)
        if self._current_stage == stage and (cx ~= self._cursor_position.x or cy ~= self._cursor_position.y) then
            moved = true
        end
        return result
    end
    local consume = f.consume
    f.consume = function(self, state, frame, t)
        if state == self.server_state then
            if moved and not from then from = frame + offset; to = from + frames end
            if from and frame >= from and frame <= to then frame = received else received = frame end
        end
        return consume(self, state, frame, t)
    end
end

for _, delay in ipairs({ 0.05, 0.165, 0.3 }) do
    test(string.format("Input stalls of 0.24/0.40s from a step's frames, receipts %.3fs: no mistake, no stall", delay), function()
        local boards, mistakes, time = 0, 0, 0
        for _, frames in ipairs({ 12, 20 }) do
            for offset = 0, 5 do
                for seed = 1, 10 do
                    local f = open(seed, nil, delay)
                    f.ping = 2 * delay + 0.06
                    stall(f, 2, offset, frames)
                    local elapsed = solve(f, 6000)
                    boards = boards + 1
                    if f.server._mistakes > 0 then mistakes = mistakes + 1 end
                    if not baseline then
                        eq(f.server._mistakes, 0, string.format("seed %d, stall %d frames from +%d: mistake", seed, frames, offset))
                        assert(elapsed, string.format("seed %d, stall %d frames from +%d: stalled", seed, frames, offset))
                    end
                    time = time + (elapsed or 0)
                end
            end
        end
        print(string.format("  %d boards, %d with a mistake, mean solve %.3fs", boards, mistakes, time / boards))
    end)
end

test("No server input state at all (an engine change): still solves after a one-second wait, no mistake", function()
    for seed = 1, 10 do
        local f = open(seed)
        f.drop_server_state = true
        assert(solve(f, 6000), "seed " .. seed .. ": stalled")
        eq(f.server._mistakes, 0)
    end
end)

test("DMF debug lines report the hold and its result", function()
    local f = open(4)
    local lines = {}
    f.mod.debug = function(_, message, ...) lines[#lines + 1] = string.format(message, ...) end
    assert(solve(f), "solve stalled")
    local holds, results = 0, 0
    for _, line in ipairs(lines) do
        if line:find("^Search hold: stage") then holds = holds + 1 end
        if line:find("^Search hold result") then results = results + 1 end
    end
    if not baseline then assert(holds >= 1 and holds == results, "debug lines: " .. table.concat(lines, " | ")) end
    print("  " .. (lines[1] or "(no lines)"))
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
