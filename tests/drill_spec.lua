-- Run from the workspace root with tools/luajit/luajit.exe (see README.md).
assert(jit and jit.version, "LuaJIT required")
local H = dofile("mods/active/NoBrainer/tests/fixture.lua")
local baseline = arg[1] == "--baseline"
assert(arg[1] == nil or baseline, "usage: drill_spec.lua [--baseline]")
local fixture = H.factory()
local eq, near = H.eq, H.near
local passed, failed = 0, 0
local function test(name, body)
    local ok, err = xpcall(body, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end
local SPEED5 = { drill_solve_speed = 5, enable_scan = false, enable_auto_scan = false }

print("NoBrainer Drill tests | " .. jit.version .. " | source " .. (FIXTURE_SOURCE_VERSION or "darktide-source") .. " | "
    .. (baseline and "BASELINE expectations" or "CURRENT runtime"))

-- An online Drill on a chosen board seed (fixture:open always uses seed 1729).
local function open(seed, values, delay, before, local_server)
    local f = fixture(values or SPEED5)
    if before then before(f) end
    local Drill = f.env.MinigameDrill
    local init = Drill.init
    Drill.init = function(self, unit, is_server, _, context) return init(self, unit, is_server, seed, context) end
    f:open("drill", not local_server, delay or 0.05)
    Drill.init = init
    f.goals = { unpack(f.server._correct_targets) }
    return f
end

-- Every move the native server accepted, and accepted moves that selected nothing.
local function record(f)
    local log = { moves = {}, empty = 0 }
    local native = f.server.on_axis_set
    f.server.on_axis_set = function(self, t, x, y)
        local last, from = self._last_move, self._selected_index
        local result = native(self, t, x, y)
        if self._last_move ~= last then
            if self._selected_index == from then log.empty = log.empty + 1 end
            log.moves[#log.moves + 1] = { stage = self._current_stage, t = t, from = from, to = self._selected_index }
        end
        return result
    end
    return log
end

local function solve(f, limit)
    local origin, sent = f.t, {}
    for frame = 1, limit or 3000 do
        local sample = f:tick(frame)
        if sample.move.x ~= 0 or sample.move.y ~= 0 then
            sent[#sent + 1] = { x = sample.move.x, y = sample.move.y, t = f.t, frame = frame }
        end
        if f.server:is_completed() and (not f.client or f.client:is_completed()) then return f.t - origin, sent end
    end
    return nil, sent
end

local function hops(log)
    local count = {}
    for _, move in ipairs(log.moves) do count[move.stage] = (count[move.stage] or 0) + 1 end
    return count
end

-- Ground truth from the native class: which target one aim from (cx, cy) selects.
local function scratch(f)
    local s = f.env.MinigameDrill:new(nil, true, 1)
    s._client_side, s._targets = true, f.server._targets
    return s
end
local function pick(f, s, stage, cx, cy, selected, theta)
    s._current_state, s._current_stage = f.settings.game_states.gameplay, stage
    s._cursor_position, s._selected_index, s._last_move = { x = cx, y = cy }, selected, -1
    s:on_axis_set(0, math.cos(theta), -math.sin(theta))
    return s._selected_index ~= selected and s._selected_index or nil
end
-- Longest contiguous arc (degrees) of aims from the origin that select the goal directly.
local function arc(f, s, stage, goal)
    local target = f.server._targets[stage][goal]
    local base, run, best = math.atan2(target.y, target.x), 0, 0
    for i = -600, 600 do
        if pick(f, s, stage, 0, 0, nil, base + math.rad(i * 0.1)) == goal then
            run = run + 1; best = math.max(best, run)
        else run = 0 end
    end
    return best * 0.1, pick(f, s, stage, 0, 0, nil, base) == goal
end

-- Whether some aim selects the goal from the origin and then nothing from the goal (a safe hold).
local function convergent(f, s, stage, goal)
    local target = f.server._targets[stage][goal]
    local base, run, best = math.atan2(target.y, target.x), 0, 0
    for i = -600, 600 do
        local theta = base + math.rad(i * 0.1)
        if pick(f, s, stage, 0, 0, nil, theta) == goal and pick(f, s, stage, target.x, target.y, goal, theta) == nil then
            run = run + 1; best = math.max(best, run)
        else run = 0 end
    end
    return best * 0.1 >= 2
end

local function planned(move) return math.abs(math.max(math.abs(move.x), math.abs(move.y)) - 1) < 1e-12 end

local function quantize(f, step)
    f.env.Network.pack_unpack = function(_, value)
        if type(value) == "number" then return math.floor(value / step + 0.5) * step end
        return value
    end
end

local function board_suite(name, seeds, values, step, required_arc)
    test(name, function()
        local stats = { stages = 0, direct_miss = 0, single = 0, two = 0, time = 0 }
        for seed = 1, seeds do
            local f = open(seed, values, nil, step and function(f) quantize(f, step) end)
            local log, s = record(f), scratch(f)
            local elapsed, sent = solve(f)
            assert(elapsed, "seed " .. seed .. ": solve stalled")
            eq(f.server._mistakes, 0, "seed " .. seed .. " mistakes")
            eq(log.empty, 0, "seed " .. seed .. ": accepted move selected nothing")
            local count = hops(log)
            for stage = 1, f.server._stage_amount do
                local width, direct = arc(f, s, stage, f.goals[stage])
                stats.stages = stats.stages + 1
                if not direct then stats.direct_miss = stats.direct_miss + 1 end
                if width >= required_arc then stats.single = stats.single + 1 end
                if count[stage] >= 2 then stats.two = stats.two + 1 end
                assert(count[stage] >= 1 and count[stage] <= 3, "seed " .. seed .. " stage " .. stage .. " hops")
                if not baseline and width >= required_arc then
                    eq(count[stage], 1, "seed " .. seed .. " stage " .. stage .. ": robust single aim exists")
                end
            end
            if not baseline then
                for _, move in ipairs(sent) do assert(planned(move), "seed " .. seed .. ": planner fell back") end
            end
            stats.time = stats.time + elapsed
        end
        print(string.format("  %d stages: direct aim misses %.1f%%, robust single aim exists %.1f%%, "
            .. "two or more hops %.1f%%, mean solve %.3fs", stats.stages, 100 * stats.direct_miss / stats.stages,
            100 * stats.single / stats.stages, 100 * stats.two / stats.stages, stats.time / seeds))
    end)
end

board_suite("Planner: full solves, one hop whenever a robust single aim exists, speed 5", 120, SPEED5, nil, 2)
board_suite("Planner: 1/127 packed joystick, speed 5", 40, SPEED5, 1 / 127, 3)
board_suite("Planner: speed 3 keeps pacing and plans aims",  20,
    { drill_solve_speed = 3, enable_scan = false, enable_auto_scan = false }, nil, 2)

for _, mode in ipairs({ "planned", "fallback" }) do
    for _, position in ipairs({ { 0, 0 }, { 0, 0.01 }, { 0, -0.01 } }) do
        test(string.format("Origin target (%g, %g), %s aim: never stalls", position[1], position[2], mode), function()
            local f = open(7, nil, nil, mode == "fallback" and function(f)
                -- Without pack_unpack/type_index the module starts untrusted and uses direct aim.
                local type_index = f.env.Network.type_index
                f.env.Network.type_index = nil
                f:reload()
                f.env.Network.type_index = type_index
            end or nil)
            local goal = f.goals[1]
            for _, mg in ipairs({ f.server, f.client }) do mg._targets[1][goal] = { x = position[1], y = position[2] } end
            local log = record(f)
            local elapsed = solve(f, 1500)
            if baseline then
                assert(not elapsed, "pre-edit direct aim was expected to stall on an origin target")
                return
            end
            assert(elapsed, "origin target solve stalled")
            eq(f.server._mistakes, 0)
            eq(log.empty, 0)
            eq(hops(log)[1], 1, "origin target selected by the first move")
        end)
    end
end

test("Kill switch: a wrong native model falls back to direct aim and still solves", function()
    local fell_back, seeds = 0, 0
    for seed = 1, 60 do
        local f = open(seed)
        -- The module captured the 0.75 weight at load; the native server now scores differently.
        f.settings.drill_move_distance_power = 0.3
        local log = record(f)
        local elapsed, sent = solve(f, 4000)
        assert(elapsed, "seed " .. seed .. ": solve stalled")
        eq(f.server._mistakes, 0, "seed " .. seed .. " mistakes")
        eq(log.empty, 0, "seed " .. seed .. ": accepted move selected nothing")
        local switched = false
        for i, move in ipairs(sent) do
            if switched then
                near(move.x * move.x + move.y * move.y, 1, "after the switch every move is direct aim")
            elseif i > 1 and not planned(move) then
                switched = true
            end
        end
        if switched then fell_back = fell_back + 1 end
        seeds = seeds + 1
    end
    if not baseline then assert(fell_back > 0, "no seed exercised the kill switch") end
    print(string.format("  kill switch engaged on %d of %d boards", fell_back, seeds))
end)

-- Server presses that advanced the stage, with their fixed-frame time.
local function presses(f)
    local log = {}
    local native = f.server.on_action_pressed
    f.server.on_action_pressed = function(self, t)
        local before = self._current_stage
        local result = native(self, t)
        if self._current_stage ~= before then log[#log + 1] = { t = t, stage = self._current_stage } end
        return result
    end
    return log
end

-- Delay of the first accepted move of each later stage after the press that opened it.
local function lead(f, press_log, log)
    local gaps = {}
    for _, press in ipairs(press_log) do
        for _, move in ipairs(log.moves) do
            if move.stage == press.stage then gaps[#gaps + 1] = move.t - press.t; break end
        end
    end
    return gaps
end

for _, delay in ipairs({ 0.03, 0.165 }) do
    test("Held first move registers on the first gameplay frame, receipt delay=" .. delay, function()
        local total, count, held, time = 0, 0, 0, 0
        for seed = 1, 40 do
            local f = open(seed, nil, delay)
            local log, press_log, s = record(f), presses(f), scratch(f)
            local elapsed = solve(f)
            assert(elapsed, "seed " .. seed .. ": solve stalled")
            eq(f.server._mistakes, 0)
            eq(log.empty, 0)
            for n, gap in ipairs(lead(f, press_log, log)) do
                local stage = press_log[n].stage
                if not baseline and convergent(f, s, stage, f.goals[stage]) then
                    assert(gap > f.settings.drill_transition_time - 1e-9 and gap < f.settings.drill_transition_time + 0.05,
                        "seed " .. seed .. ": first move " .. gap .. "s after the press")
                    held = held + 1
                end
                total, count = total + gap, count + 1
            end
            time = time + elapsed
        end
        print(string.format("  press to next first move %.3fs (%d of %d transitions held), mean solve %.3fs",
            total / count, held, count, time / 40))
    end)
end

local function late_resume(f, extra)
    local native = f.server.handle_state
    f.server.handle_state = function(self, state)
        local result = native(self, state)
        if result == f.settings.game_states.transition then
            self._transition_start_time = self._transition_start_time + extra
        end
        return result
    end
end

for _, extra in ipairs({ 0.04, 0.16, 0.3, 0.8, 2.2, 3.0 }) do
    test(string.format("Server resumes %.2fs late: no mistake, no stall, planner kept", extra), function()
        local time = 0
        for seed = 1, 20 do
            local f = open(seed)
            late_resume(f, extra)
            local log, press_log, s = record(f), presses(f), scratch(f)
            local elapsed, sent = solve(f)
            assert(elapsed, "seed " .. seed .. ": solve stalled")
            eq(f.server._mistakes, 0)
            eq(log.empty, 0, "seed " .. seed .. ": accepted move selected nothing")
            if not baseline then
                -- An ignored hold only stops holding; aim planning stays enabled.
                for _, move in ipairs(sent) do assert(planned(move), "seed " .. seed .. ": planner switched off") end
                local first = press_log[1] and press_log[1].stage
                if extra < 1.8 and first and convergent(f, s, first, f.goals[first]) then
                    local gap = lead(f, press_log, log)[1] - f.settings.drill_transition_time - extra
                    assert(gap < 0.05, "seed " .. seed .. ": held move missed the resume")
                end
            end
            time = time + elapsed
        end
        print(string.format("  mean solve %.3fs", time / 20))
    end)
end

-- The server replays the last received input frame while newer frames are late
-- (authoritative_player_input_handler.lua:153-156).
local function late_input(f, stage, frames)
    local consume, received, lag_until = f.consume, 0, nil
    f.consume = function(self, state, frame, t)
        if state == self.server_state then
            if not lag_until and self.server._current_stage == stage and self.server._selected_index then
                lag_until = frame + frames
            end
            if lag_until and frame <= lag_until then frame = received else received = frame end
        end
        return consume(self, state, frame, t)
    end
end

test("Input replay after the held move selects no second node", function()
    local checked, stalled = 0, 0
    for seed = 1, 40 do
        local f = open(seed)
        local s = scratch(f)
        if convergent(f, s, 2, f.goals[2]) then
            late_input(f, 2, 20)
            local log = record(f)
            local elapsed = solve(f)
            if not elapsed then stalled = stalled + 1 end
            if not baseline then assert(elapsed, "seed " .. seed .. ": solve stalled") end
            eq(f.server._mistakes, 0)
            local selections = 0
            for _, move in ipairs(log.moves) do
                if move.stage == 2 and move.to ~= move.from then selections = selections + 1 end
            end
            if not baseline then eq(selections, 1, "seed " .. seed .. ": replayed hold moved off the goal") end
            checked = checked + 1
        end
    end
    print(string.format("  %d boards with 0.4s of replayed input after the stage-2 selection, %d stalled", checked, stalled))
end)

local function delay_selection(f, extra)
    local send = f.send
    f.send = function(self, to, name, ...)
        send(self, to, name, ...)
        local args = { ... }
        local selection = name == "rpc_minigame_sync_drill_set_cursor" and args[5] ~= 0
            or name == "rpc_minigame_sync_drill_set_search" and args[3]
        if selection and self.queue[#self.queue] and self.queue[#self.queue].name == name then
            self.queue[#self.queue].at = self.queue[#self.queue].at + extra
        end
    end
end

for _, extra in ipairs({ 0.4, 0.8, 1.5 }) do
    test(string.format("Selection receipts %.1fs late: never a stale press", extra), function()
        local finished, exited = 0, 0
        for seed = 1, 20 do
            local f = open(seed)
            delay_selection(f, extra)
            local elapsed = solve(f, 3000)
            eq(f.server._mistakes, 0, "seed " .. seed .. ": stale press scored a mistake")
            if elapsed then finished = finished + 1
            else
                assert(f.modules.drill.cancel_requested(), "seed " .. seed .. ": stalled without the safe exit")
                exited = exited + 1
            end
        end
        if not baseline then eq(finished, 20, "every board finishes") end
        print(string.format("  %d finished, %d left through the existing safe exit", finished, exited))
    end)
end

test("Held-move result later than the 2.5s tolerance, in-order receipts: never a stale press", function()
    local f = open(3)
    -- Stage 2: direct aim from the goal reaches node B, but an offset hold is inert from the goal.
    local goal = f.goals[2]
    local layout, other = { { 0.457, 0.356 }, { -0.6, -0.3 }, { -0.5, 0.4 }, { 0.2, -0.45 } }, 0
    for i = 1, 5 do
        local position = { 0.3, 0.1 }
        if i ~= goal then other = other + 1; position = layout[other] end
        for _, mg in ipairs({ f.server, f.client }) do mg._targets[2][i] = { x = position[1], y = position[2] } end
    end
    -- Ordered transport; only the held move's receipts wait 3.5s, and everything after waits behind them.
    local send, held, floor = f.send, 0, 0
    f.send = function(self, to, name, ...)
        send(self, to, name, ...)
        local item, args = self.queue[#self.queue], { ... }
        if not item or item.name ~= name then return end
        if f.server._current_stage == 2 and held < 2 and (name == "rpc_minigame_sync_drill_set_cursor" and args[5] ~= 0
            or name == "rpc_minigame_sync_drill_set_search" and args[3]) then
            held = held + 1
            item.at = item.at + 3.5
        end
        item.at = math.max(item.at, floor)
        floor = item.at
    end
    local log = record(f)
    local elapsed = solve(f, 3000)
    eq(f.server._mistakes, 0, "stale press scored a mistake")
    assert(elapsed or f.modules.drill.cancel_requested(), "stalled without the safe exit")
    print("  " .. (elapsed and "finished" or "left through the existing safe exit") .. ", stage 2 server moves "
        .. tostring(hops(log)[2]))
end)

-- The server reads every aim rotated: a joystick model error the planner cannot see.
local function skew(f, degrees)
    local native, r = f.server.on_axis_set, math.rad(degrees)
    f.server.on_axis_set = function(self, t, x, y)
        if x ~= 0 or y ~= 0 then
            local a, l = math.atan2(-y, x) + r, math.sqrt(x * x + y * y)
            x, y = l * math.cos(a), -l * math.sin(a)
        end
        return native(self, t, x, y)
    end
end

for _, spike in ipairs({ 0.85, 1.2 }) do
    test(string.format("Model off by 1-3 degrees and receipts slowing to %.2fs after a press: never a mistake", spike), function()
        local finished, exited = 0, 0
        for _, degrees in ipairs({ 1, 3 }) do
            for seed = 1, 40 do
                local f = open(seed, nil, 0.3)
                skew(f, degrees)
                local native = f.server.on_action_pressed
                f.server.on_action_pressed = function(self, t)
                    local result = native(self, t)
                    f.delay = spike -- the press and stage receipts already left at 0.3s
                    return result
                end
                local elapsed = solve(f, 4000)
                eq(f.server._mistakes, 0, string.format("seed %d, %d degrees: mistake", seed, degrees))
                if elapsed then finished = finished + 1
                else
                    assert(f.modules.drill.cancel_requested(), "seed " .. seed .. ": stalled without the safe exit")
                    exited = exited + 1
                end
            end
        end
        print(string.format("  %d finished, %d left through the existing safe exit", finished, exited))
    end)
end

test("Model off by 1-3 degrees at normal latency: unexplained selections stop prediction, no mistake", function()
    for _, degrees in ipairs({ 0, 1, 3 }) do
        local time, finished = 0, 0
        for seed = 1, 40 do
            local f = open(seed)
            skew(f, degrees)
            local elapsed = solve(f, 4000)
            eq(f.server._mistakes, 0, string.format("seed %d, %d degrees: mistake", seed, degrees))
            if elapsed then time, finished = time + elapsed, finished + 1
            else assert(f.modules.drill.cancel_requested(), "seed " .. seed .. ": stalled without the safe exit") end
        end
        print(string.format("  %d degrees: %d of 40 finished, mean solve %.3fs", degrees, finished, time / finished))
    end
end)

for _, delay in ipairs({ 0.6, 0.9 }) do
    test(string.format("High ping (receipts %.1fs): a late stage receipt holds at once, briefly", delay), function()
        local total, count, held, time = 0, 0, 0, 0
        for seed = 1, 30 do
            local f = open(seed, nil, delay)
            local log, press_log, s = record(f), presses(f), scratch(f)
            local elapsed = solve(f, 5000)
            assert(elapsed, "seed " .. seed .. ": solve stalled")
            eq(f.server._mistakes, 0)
            eq(log.empty, 0, "seed " .. seed .. ": accepted move selected nothing")
            for n, gap in ipairs(lead(f, press_log, log)) do
                local stage = press_log[n].stage
                if not baseline and convergent(f, s, stage, f.goals[stage]) then
                    -- Registered on the first frame after the receipt (receipt delay + 3-frame input lag).
                    assert(gap < delay + 0.06 + 0.05, "seed " .. seed .. ": first move " .. gap .. "s after the press")
                    held = held + 1
                end
                total, count = total + gap, count + 1
            end
            time = time + elapsed
        end
        print(string.format("  press to next first move %.3fs (%d of %d held), mean solve %.3fs", total / count, held, count, time / 30))
    end)
end

test("High ping and a 1-3 degree model error: never a mistake", function()
    local finished, exited = 0, 0
    for _, degrees in ipairs({ 1, 3 }) do
        for seed = 1, 30 do
            local f = open(seed, nil, 0.7)
            skew(f, degrees)
            local elapsed = solve(f, 5000)
            eq(f.server._mistakes, 0, string.format("seed %d, %d degrees: mistake", seed, degrees))
            if elapsed then finished = finished + 1
            else
                assert(f.modules.drill.cancel_requested(), "seed " .. seed .. ": stalled without the safe exit")
                exited = exited + 1
            end
        end
    end
    print(string.format("  %d finished, %d left through the existing safe exit", finished, exited))
end)

-- Late input from a given number of frames after the stage's first selection: the server
-- replays the last received frame (a held frame) meanwhile.
local function stall_after(f, stage, offset, frames)
    local consume, received, first = f.consume, 0, nil
    f.consume = function(self, state, frame, t)
        if state == self.server_state then
            if not first and self.server._current_stage == stage and self.server._selected_index then first = frame end
            if first and frame >= first + offset and frame < first + offset + frames then frame = received
            else received = frame end
        end
        return consume(self, state, frame, t)
    end
end

test("High ping late hold, 1-3 degree model error and a stall right after it: never a mistake", function()
    local finished, exited = 0, 0
    for _, delay in ipairs({ 0.85, 1.0 }) do
        for _, degrees in ipairs({ 1, 3 }) do
            for seed = 1, 25 do
                for _, offset in ipairs({ 2, 5, 9 }) do
                    local f = open(seed, nil, delay)
                    skew(f, degrees)
                    stall_after(f, 2, offset, 5)
                    local elapsed = solve(f, 6000)
                    eq(f.server._mistakes, 0, string.format("seed %d, %d degrees, offset %d: mistake", seed, degrees, offset))
                    if elapsed then finished = finished + 1
                    else
                        assert(f.modules.drill.cancel_requested(), "seed " .. seed .. ": stalled without the safe exit")
                        exited = exited + 1
                    end
                end
            end
        end
    end
    print(string.format("  %d finished, %d left through the existing safe exit", finished, exited))
end)

-- Input stalls: the server runs each frame on the newest input it has (authoritative_player_input_handler
-- .lua:153-156); a stall on a direction frame repeats it after 0.25 s. Starts from the first stage-2 gameplay
-- frame, so it covers the held move and the moves after it.
local function stall(f, offset, frames)
    local received, from, to = 0, nil, nil
    local gameplay = f.settings.game_states.gameplay
    local consume = f.consume
    f.consume = function(self, state, frame, t)
        if state == self.server_state then
            if not from and self.server:current_stage() == 2 and self.server:state() == gameplay then
                from = frame + offset; to = from + frames
            end
            if from and frame >= from and frame <= to then frame = received else received = frame end
        end
        return consume(self, state, frame, t)
    end
end

for _, delay in ipairs({ 0.05, 0.3 }) do
    test(string.format("Input stalls of 0.24/0.40s in stage 2, receipts %.2fs: never a mistake", delay), function()
        local boards, aborts = 0, 0
        for _, frames in ipairs({ 12, 20 }) do
            for offset = 0, 16, 4 do
                for seed = 1, 8 do
                    local f = open(seed, nil, delay)
                    f.ping = 2 * delay + 0.06
                    stall(f, offset, frames)
                    local elapsed = solve(f, 4000)
                    boards = boards + 1
                    eq(f.server._mistakes, 0, string.format("seed %d, stall %d frames from +%d: mistake", seed, frames, offset))
                    if not elapsed then
                        -- 1.0.2 exits the minigame after a move without result (it cannot tell a lost move).
                        assert(f.modules.drill.cancel_requested(), string.format("seed %d: neither solved nor aborted", seed))
                        aborts = aborts + 1
                    end
                    if not baseline then assert(elapsed, string.format("seed %d, stall %d frames from +%d: not solved", seed, frames, offset)) end
                end
            end
        end
        print(string.format("  %d boards, %d uncertain-move aborts", boards, aborts))
    end)
end

test("No server input state at all (an engine change): still solves, no mistake", function()
    for seed = 1, 8 do
        local f = open(seed)
        f.drop_server_state = true
        assert(solve(f, 4000), "seed " .. seed .. ": stalled")
        eq(f.server._mistakes, 0)
    end
end)

test("DMF debug lines report the hold and every move", function()
    local f = open(2)
    local lines = {}
    f.mod.debug = function(_, message, ...) lines[#lines + 1] = string.format(message, ...) end
    assert(solve(f), "solve stalled")
    local holds, results, moves = 0, 0, 0
    for _, line in ipairs(lines) do
        if line:find("^Drill hold: stage") then holds = holds + 1 end
        if line:find("^Drill hold result") then results = results + 1 end
        if line:find("^Drill move") then moves = moves + 1 end
    end
    if not baseline then
        assert(holds == results and moves >= 1, "debug lines missing: " .. table.concat(lines, " | "))
    end
    print("  " .. (lines[2] or "(no lines)"))
end)

test("Local server (solo/host): held first move and planned aims, zero mistakes", function()
    local time = 0
    for seed = 1, 30 do
        local f = open(seed, nil, nil, nil, true)
        local log, press_log = record(f), presses(f)
        local elapsed, sent = solve(f)
        assert(elapsed, "seed " .. seed .. ": solve stalled")
        eq(f.server._mistakes, 0)
        eq(log.empty, 0)
        if not baseline then
            for _, gap in ipairs(lead(f, press_log, log)) do
                assert(gap < f.settings.drill_transition_time + 0.23, "seed " .. seed .. ": held move missed the resume")
            end
            for _, move in ipairs(sent) do assert(planned(move), "seed " .. seed .. ": planner fell back") end
        end
        time = time + elapsed
    end
    print(string.format("  mean solve %.3fs", time / 30))
end)

test("Speed 3 never holds a move across the transition", function()
    for seed = 1, 10 do
        local f = open(seed, { drill_solve_speed = 3, enable_scan = false, enable_auto_scan = false })
        local log, press_log = record(f), presses(f)
        assert(solve(f), "seed " .. seed .. ": solve stalled")
        eq(f.server._mistakes, 0)
        for _, gap in ipairs(lead(f, press_log, log)) do
            assert(gap > f.settings.drill_transition_time + 0.1, "speed 3 move during the transition")
        end
    end
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
