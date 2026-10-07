-- Run from the workspace root with tools/luajit/luajit.exe (see README.md).
assert(jit and jit.version, "LuaJIT required")
local H = dofile("mods/active/NoBrainer/tests/fixture.lua")
local baseline = arg[1] == "--baseline"
assert(arg[1] == nil or baseline, "usage: speed_spec.lua [--baseline]")
local fixture = H.factory()
local eq, near, copy, rpc, deliver = H.eq, H.near, H.copy, H.rpc, H.deliver
local passed, failed, skipped = 0, 0, 0
-- NoBrainer keeps its own Frequency and Scan solvers; their BetterBrainer cases do not apply.
local function applies(name)
    return not (name:find("^Frequency") or name:find("^Scan") or name:find("^Full native solve: frequency"))
end
local function test(name, body)
    if not applies(name) then skipped = skipped + 1; return end
    local ok, err = xpcall(body, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end
local function step(f, frame, t, consume)
    f.t = t
    local sample = f:sample(frame)
    if consume ~= false then f:consume(f.local_state, frame) end
    return sample
end

print("NoBrainer focused speed tests (Search, Symbols) | " .. jit.version .. " | source " .. (FIXTURE_SOURCE_VERSION or "darktide-source") .. " | "
    .. (baseline and "BASELINE expectations" or "CURRENT runtime"))

test("fixture uses LuaJIT quadrant-aware atan2, vararg arity and seconds clock", function()
    local f = fixture()
    near(f.env.math.atan2(1, -1), math.pi * 0.75)
    local packed = f.env.table.pack(1, nil, 3, nil)
    eq(select("#", f.env.table.unpack(packed, 1, packed.n)), 4)
    f.rewind = 0.18
    f:open("decode_symbols", true, 10)
    near(f.client:start_time(), f.t + 0.18)
end)

for _, speed in ipairs({ 1, 3, 5 }) do
    test("Frequency opening delay, speed " .. speed, function()
        local f = fixture({ frequency_solve_speed = speed })
        f:open("frequency", true, 10)
        local origin, first = f.t
        for frame = 1, 100 do
            local sample = step(f, frame, origin + frame * 0.01)
            if sample.action_one_hold then first = frame * 0.01; break end
        end
        local expected = baseline and ({ [1] = 0.75, [3] = 0.63, [5] = 0.5 })[speed]
            or ({ [1] = 0.75, [3] = 0.38, [5] = 0.02 })[speed]
        near(first or -1, expected, "first serialized rising edge")
        deliver(f, "rpc_minigame_sync_frequency_test_frequency")
        eq(f.server:current_stage(), 2, "native scoring")
        eq(f.server._mistakes, 0)
        print(string.format("  timing Frequency speed %d: %.3fs", speed, first))
    end)
end

-- Server state: the server ran frame `frame` on its own input (see BetterBrainer.lua movement_settled).
local function input_ack(f, frame) f:report_frame(frame, true) end

local function search_case(speed, x, y)
    local f = fixture({ expedition_solve_speed = speed })
    f:open("decode_search", true, 10)
    for _, mg in ipairs({ f.server, f.client }) do
        local symbols = {}
        for i = 1, mg._board_width * mg._board_height do symbols[i] = i end
        mg:set_symbols(symbols)
        mg._decode_targets[1] = copy(mg:get_symbols_for_target(x, y))
        mg:set_cursor_position(1, 1)
    end
    f:set("expedition_solve_speed", speed)
    return f
end

test("Search full diagonal ACK presses on first settled sample at speed 5", function()
    local f = search_case(5, 2, 2)
    local origin = f.t
    eq(step(f, 1, origin + 0.02).action_one_hold, false, "initial release")
    local move = step(f, 2, origin + 0.04)
    eq(move.move.x, 1); eq(move.move.y, -1)
    eq(move.action_one_hold, false, "movement frame")
    f:consume(f.server_state, 2)
    deliver(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f.client:cursor_position().y, 1, "partial X receipt")
    eq(step(f, 3, origin + 0.06).action_one_hold, false, "partial diagonal must not press")
    deliver(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(f.client:is_on_target(), true)
    if not baseline then input_ack(f, 3) end
    local ready = step(f, 4, origin + 0.08)
    eq(ready.action_one_hold, not baseline, "first fully confirmed sample")
    local next_sample = step(f, 5, origin + 0.10)
    eq(next_sample.action_one_hold, baseline, "old wait versus mandatory release")
    local hit_frame = baseline and 5 or 4
    f:consume(f.server_state, hit_frame)
    eq(f.server:current_stage(), 2)
    eq(f.server._mistakes, 0)
    print("  timing Search after final ACK: " .. (baseline and "0.020s" or "0.000s"))
end)

for _, first in ipairs({ "stage", "target" }) do
    for _, identical in ipairs({ false, true }) do
        test("Frequency ACK guard: " .. first .. " first, repeated target=" .. tostring(identical), function()
            local f = fixture({ frequency_solve_speed = 5 })
            f:open("frequency", true, 10)
            local origin, frame = f.t, 0
            repeat
                frame = frame + 1
                step(f, frame, origin + frame * 0.02)
                assert(frame < 100, "no opening submission")
            until f.rpc_count.rpc_minigame_sync_frequency_test_frequency == 1
            local submitted = deliver(f, "rpc_minigame_sync_frequency_test_frequency")
            local target = f.native_scores[1].target
            eq(submitted.args[3], target.x); eq(submitted.args[4], target.y)
            eq(f.server:current_stage(), 2)
            local stage_rpc = "rpc_minigame_sync_set_stage"
            local target_rpc = "rpc_minigame_sync_frequency_set_target_frequency"
            if identical then
                for _, item in ipairs(f.queue) do
                    if item.name == target_rpc then item.args[3], item.args[4] = target.x, target.y end
                end
                f.server:set_target_frequency(target.x, target.y)
            end
            local function blocked()
                for _ = 1, 20 do
                    frame = frame + 1
                    local sample = step(f, frame, origin + frame * 0.02)
                    eq(sample.action_one_hold, false, "incomplete ACK cannot retry")
                    eq(sample.action_two_pressed, false, "still inside ACK grace period")
                end
                eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency, 1)
            end
            blocked()
            deliver(f, first == "stage" and stage_rpc or target_rpc)
            blocked()
            deliver(f, first == "stage" and target_rpc or stage_rpc)
            frame = frame + 1
            eq(step(f, frame, origin + frame * 0.02).action_one_hold, true, "complete ACK unlocks")
            deliver(f, "rpc_minigame_sync_frequency_test_frequency")
            eq(f.server:current_stage(), 3); eq(f.server._mistakes, 0)
            eq(step(f, frame + 1, origin + (frame + 1) * 0.02).action_one_hold, false, "release edge")
        end)
    end
end

test("Frequency stage-one failed test needs only unchanged stage ACK", function()
    local f = fixture({ frequency_solve_speed = 5 })
    f:open("frequency", true, 10)
    local frame = 0
    repeat
        frame = frame + 1
        step(f, frame, 10 + frame * 0.02)
        assert(frame < 100)
    until f.rpc_count.rpc_minigame_sync_frequency_test_frequency == 1
    for _, item in ipairs(f.queue) do
        if item.name == "rpc_minigame_sync_frequency_test_frequency" then
            item.args[3], item.args[4] = 0, 0
        end
    end
    deliver(f, "rpc_minigame_sync_frequency_test_frequency")
    eq(f.server:current_stage(), 1); eq(f.server._mistakes, 1)
    eq(#f.queue, 1, "failure sends stage only")
    deliver(f, "rpc_minigame_sync_set_stage")
    eq(step(f, frame + 1, 10 + (frame + 1) * 0.02).action_one_hold, false, "release still required")
    eq(step(f, frame + 2, 10 + (frame + 2) * 0.02).action_one_hold, true)
    deliver(f, "rpc_minigame_sync_frequency_test_frequency")
    eq(f.server:current_stage(), 2)
end)

test("Search movement-frame ACK cannot change the serialized press decision", function()
    local f = search_case(5, 2, 2)
    step(f, 1, 10.02)
    local sample = step(f, 2, 10.04)
    eq(sample.action_one_hold, false)
    f:consume(f.server_state, 2)
    deliver(f, "rpc_minigame_sync_decode_search_set_cursor")
    deliver(f, "rpc_minigame_sync_decode_search_set_cursor")
    f.modules.search.observe(f.client, 10.041)
    eq(f.modules.search.input("action_one_hold", false, 10.041, "input_service"), false,
        "same input frame remains movement-only after immediate full ACK")
    if baseline then
        eq(step(f, 3, 10.06).action_one_hold, true, "next frame can press")
        eq(step(f, 4, 10.08).action_one_hold, false, "next frame releases")
    else
        input_ack(f, 2)
        eq(step(f, 3, 10.06).action_one_hold, false, "the movement frame itself running timely is not enough")
        input_ack(f, 3)
        eq(step(f, 4, 10.08).action_one_hold, true, "a later frame ran timely: press")
        eq(step(f, 5, 10.10).action_one_hold, false, "next frame releases")
    end
end)

test("Search speed 1 retains ready_at and settled pacing", function()
    local f = search_case(1, 1, 1)
    for frame, t in ipairs({ 10.02, 10.20, 10.40, 10.665 }) do
        eq(step(f, frame, t).action_one_hold, false, "configured slow pacing")
    end
    eq(step(f, 5, 10.667).action_one_hold, true)
    eq(step(f, 6, 10.687).action_one_hold, false)
    f:consume(f.server_state, 1, 10.02)
    f:consume(f.server_state, 5)
    eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
end)

test("Search slower-speed full ACK retains movement ready_at", function()
    local f = search_case(3, 2, 2)
    step(f, 1, 10.02)
    local moved = step(f, 2, 10.221)
    eq(moved.move.x, 1); eq(moved.move.y, -1); eq(moved.action_one_hold, false)
    f:consume(f.server_state, 2)
    deliver(f, "rpc_minigame_sync_decode_search_set_cursor")
    deliver(f, "rpc_minigame_sync_decode_search_set_cursor")
    eq(step(f, 3, 10.26).action_one_hold, false)
    if not baseline then input_ack(f, 3) end
    eq(step(f, 4, 10.60).action_one_hold, false, "settled pacing elapsed, movement pacing has not")
    eq(step(f, 5, 10.786).action_one_hold, false)
    eq(step(f, 6, 10.788).action_one_hold, true)
    f:consume(f.server_state, 6)
    eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
end)

for _, missing in ipairs({ "rpc_minigame_sync_set_stage", "rpc_minigame_sync_frequency_set_target_frequency" }) do
    test("Frequency opening cannot press with missing " .. missing, function()
        local f = fixture({ frequency_solve_speed = 5 })
        f.deliver = function() end
        f:open("frequency", true, 10)
        local held = {}
        for _, item in ipairs(f.queue) do
            if item.name == missing then held[#held + 1] = item
            else f:dispatch(item.to, item.name, item.args) end
        end
        f.queue = held
        for frame = 1, 40 do
            eq(step(f, frame, 10 + frame * 0.02).action_one_hold, false, "incomplete opening receipt")
        end
        eq(f.rpc_count.rpc_minigame_sync_frequency_test_frequency, nil)
        deliver(f, missing)
        eq(step(f, 41, 10.82).action_one_hold, true)
        deliver(f, "rpc_minigame_sync_frequency_test_frequency")
        eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
    end)
end

local SYMBOLS = "decode_symbols_set_symbols"
local CLOCK = "decode_symbols_set_start_time"
local TARGET = "decode_symbols_set_target"

local function symbols_case()
    local f = fixture()
    f.enabled = false
    f:open("decode_symbols", true, 10)
    f.enabled = true
    f.mod.on_enabled()
    f.server:stop(false)
    f:deliver(true)
    f.t = 20
    f.server:setup_game()
    local center = (f.server:current_decode_target() - 1)
        * f.server:sweep_duration() / (f.server._decode_symbols_items_per_stage - 1)
    f.rewind = -center
    f.server:start(f.remote)
    local events = {}
    for _, item in ipairs(f.queue) do
        local suffix = item.name:match("^rpc_minigame_sync_(.*)$")
        local key = suffix == SYMBOLS and "symbols" or suffix == CLOCK and "clock"
            or suffix == "set_stage" and "stage" or suffix == TARGET and ("t" .. item.args[3])
        if key then events[key] = item
        else f:dispatch(item.to, item.name, item.args) end
    end
    f.queue = {}
    function f:receipt(key)
        local item = assert(events[key], key)
        self:dispatch(item.to, item.name, item.args)
    end
    function f:local_start()
        self.extensions[self.terminal] = { minigame_system = self.client._minigame_extension }
        self.local_state._minigame, self.local_state._is_server = nil, false
        self.local_state._minigame_character_state_component = {
            interface_is_level_unit = true, interface_level_unit_id = 1, interface_game_object_id = -1,
        }
        assert(self.local_state:_check_initialize_minigame_from_unit(), "native local initialization")
    end
    function f:attach()
        self:consume(self.local_state, 0)
        self:consume(self.server_state, 0)
        eq(self.ctx.active_minigame, self.client)
    end
    return f
end

local orders = {
    { "t1", "t2", "t3", "t4", "stage", "clock" },
    { "t4", "t3", "t2", "t1", "clock", "stage" },
    { "stage", "t1", "t2", "t3", "t4", "clock" },
    { "stage", "clock", "t1", "t2", "t3", "t4" },
    { "clock", "t1", "t2", "t3", "t4", "stage" },
    { "clock", "stage", "t1", "t2", "t3", "t4" },
    { "t3", "stage", "t1", "clock", "t4", "t2" },
}
for index, order in ipairs(orders) do
    for _, local_start in ipairs({ "before", "middle", "after" }) do
        test("Symbols complete board order " .. index .. ", local start " .. local_start, function()
            local f = symbols_case()
            if local_start == "before" then f:local_start() end
            f:receipt("symbols")
            for i, key in ipairs(order) do
                f:receipt(key)
                if i == 3 and local_start == "middle" then f:local_start() end
            end
            if local_start == "after" then f:local_start() end
            f:attach()
            eq(step(f, 1, 20).action_one_hold, false, "first sample releases")
            eq(step(f, 2, 20.01).action_one_hold, not baseline, "all receipts bypass only stable wait")
            if baseline then
                eq(step(f, 3, 20.119).action_one_hold, false, "old 120ms wait")
                eq(step(f, 4, 20.121).action_one_hold, true, "old stable-board fallback")
            end
            local hit_frame, hit_t = baseline and 4 or 2, baseline and 20.121 or 20.01
            eq(f.server:is_on_target(hit_t), true, "native target oracle")
            f:consume(f.server_state, hit_frame, hit_t)
            eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
            eq(step(f, hit_frame + 1, hit_t + 0.01).action_one_hold, false, "next sample releases")
            if index == 1 and local_start == "before" then
                print(string.format("  timing Symbols complete receipt to first edge: %.3fs", hit_t - 20))
            end
        end)
    end
end

for _, missing in ipairs({ "t1", "t2", "t3", "t4", "stage", "clock" }) do
    test("Symbols partial receipt cannot bypass wait: missing " .. missing, function()
        local f = symbols_case()
        f:local_start()
        f:receipt("symbols")
        for _, key in ipairs(orders[1]) do if key ~= missing then f:receipt(key) end end
        f:attach()
        for frame, t in ipairs({ 20, 20.01, 20.08, 20.119 }) do
            eq(step(f, frame, t).action_one_hold, false, "partial fresh-board gate")
        end
    end)
    test("Symbols last " .. missing .. " receipt unlocks an already-observed partial board", function()
        local f = symbols_case()
        f:local_start()
        f:attach()
        eq(step(f, 1, 20).action_one_hold, false, "retained board before setup")
        f:receipt("symbols")
        for _, key in ipairs(orders[1]) do if key ~= missing then f:receipt(key) end end
        eq(step(f, 2, 20.001).action_one_hold, false, "new board first release")
        eq(step(f, 3, 20.01).action_one_hold, false, "incomplete gate")
        f:receipt(missing)
        eq(step(f, 4, 20.02).action_one_hold, not baseline, "last receipt completes gate without stability delay")
        if not baseline then
            f:consume(f.server_state, 4)
            eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
        end
    end)
end

test("Symbols duplicate target receipts cannot substitute for every stage", function()
    local f = symbols_case()
    f:local_start()
    f:receipt("symbols")
    for _, key in ipairs({ "t1", "t2", "t3", "t1", "t2", "t3", "stage", "clock" }) do f:receipt(key) end
    f:attach()
    for frame, t in ipairs({ 20, 20.01, 20.119 }) do
        eq(step(f, frame, t).action_one_hold, false, "target 4 still missing despite six target receipts")
    end
end)

test("Symbols receipts before set_symbols do not authorize new board", function()
    local f = symbols_case()
    for _, key in ipairs(orders[1]) do f:receipt(key) end
    f:receipt("symbols")
    f:local_start()
    f:attach()
    for frame, t in ipairs({ 20, 20.01, 20.121, 20.13, 24.01 }) do
        eq(step(f, frame, t).action_one_hold, false, "old clock remains stale beyond stable wait")
    end
end)

test("Symbols ambiguous already-open board retains 120ms fallback", function()
    local f = symbols_case()
    f.enabled = false
    f:local_start()
    f:receipt("symbols")
    for _, key in ipairs(orders[1]) do f:receipt(key) end
    f.enabled = true
    f.mod.on_enabled()
    f:attach()
    for frame, t in ipairs({ 20, 20.01, 20.119 }) do
        eq(step(f, frame, t).action_one_hold, false, "no tracked setup receipts")
    end
    eq(step(f, 4, 20.121).action_one_hold, true, "existing session fallback remains usable")
    f:consume(f.server_state, 4)
    eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
end)

for _, boundary in ipairs({ "real stop", "foreign start", "argumentless foreign start" }) do
    test("Symbols early receipts invalidated by " .. boundary, function()
        local f = symbols_case()
        f:receipt("symbols")
        for _, key in ipairs(orders[1]) do f:receipt(key) end
        if boundary == "real stop" then f.client:stop(false)
        elseif boundary == "foreign start" then f.client:start(f.remote)
        else rpc(f, "start") end
        f:local_start()
        f:attach()
        for frame, t in ipairs({ 20, 20.01, 20.121, 20.13, 24.01 }) do
            eq(step(f, frame, t).action_one_hold, false, "retired clock cannot authorize local session")
        end
    end)
end

test("Symbols same-instance reopen requires fresh receipts, numeric clock reuse is allowed", function()
    local f = symbols_case()
    f:local_start()
    f:receipt("symbols")
    for _, key in ipairs(orders[1]) do f:receipt(key) end
    f:attach()
    step(f, 1, 20)
    f.local_state:on_exit(f.player.player_unit, f.t, "walking")
    local mg, old_clock = f.client, f.client:start_time()
    f:local_start()
    f:attach()
    eq(f.client, mg)
    for frame, t in ipairs({ 20.001, 20.01, 20.121, 20.13 }) do
        eq(step(f, frame + 1, t).action_one_hold, false, "retained receipts invalid after real exit")
    end
    f.t = 24
    f:receipt("symbols")
    for _, key in ipairs(orders[1]) do f:receipt(key) end
    near(f.client:start_time(), old_clock, "new receipt can reuse a fixed-frame clock")
    eq(step(f, 6, 24).action_one_hold, false, "new board first release")
    eq(step(f, 7, 24.01).action_one_hold, not baseline, "fresh complete same-instance board")
    if baseline then eq(step(f, 8, 24.121).action_one_hold, true) end
end)

for _, receipt in ipairs({ "start", "stop" }) do
    test("Symbols continuing argumentless " .. receipt .. " preserves complete board gate", function()
        local f = symbols_case()
        f:local_start()
        f:receipt("symbols")
        for _, key in ipairs(orders[1]) do f:receipt(key) end
        f:attach()
        rpc(f, receipt)
        eq(f.client:player_session_id(), nil)
        eq(f.ctx.session_valid(f.client), true, "native CSM still owns continuing session")
        eq(step(f, 1, 20).action_one_hold, false)
        eq(step(f, 2, 20.01).action_one_hold, not baseline)
        if baseline then eq(step(f, 3, 20.121).action_one_hold, true) end
    end)
end

for _, direction in ipairs({ "forward", "reverse" }) do
    test("Symbols retains 30ms hit margin on " .. direction .. " sweep", function()
        local f = symbols_case()
        f:local_start()
        f:receipt("symbols")
        for _, key in ipairs(orders[1]) do f:receipt(key) end
        -- Choose an interior symbol using native setters and RPC receivers.
        for stage = 1, f.server._stage_amount do
            f.server:set_target(stage, 3 + (stage % 2))
            rpc(f, TARGET, stage, f.server._decode_targets[stage])
        end
        f:attach()
        step(f, 1, 20)
        step(f, 2, 20.13)
        local mg = f.client
        local width = mg:sweep_duration() / (mg._decode_symbols_items_per_stage - 1)
        local start = mg:start_time() + 8
        local center = (mg:current_decode_target() - 1) * width
        if direction == "reverse" then center = 2 * mg:sweep_duration() - center end
        local boundary = start + center - width * 0.5
        eq(f.server:is_on_target(boundary + 0.029), true, "inside native window but outside safe margin")
        eq(step(f, 3, boundary + 0.029).action_one_hold, false)
        eq(step(f, 4, boundary + 0.031).action_one_hold, true, "31ms inside native boundary")
        f:consume(f.server_state, 4)
        eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
        eq(step(f, 5, boundary + 0.032).action_one_hold, false, "release")
    end)
end

for _, direction in ipairs({ "forward", "reverse" }) do
    test("Symbols retains trailing 30ms margin on " .. direction .. " sweep", function()
        local f = symbols_case()
        f:local_start()
        f:receipt("symbols")
        for _, key in ipairs(orders[1]) do f:receipt(key) end
        for stage = 1, f.server._stage_amount do
            f.server:set_target(stage, 3 + (stage % 2))
            rpc(f, TARGET, stage, f.server._decode_targets[stage])
        end
        f:attach()
        step(f, 1, 20)
        step(f, 2, 20.13)
        local mg = f.client
        local width = mg:sweep_duration() / (mg._decode_symbols_items_per_stage - 1)
        local center = (mg:current_decode_target() - 1) * width
        if direction == "reverse" then center = 2 * mg:sweep_duration() - center end
        local boundary = mg:start_time() + 8 + center + width * 0.5
        eq(f.server:is_on_target(boundary - 0.029), true, "native hit window is wider")
        eq(step(f, 3, boundary - 0.029).action_one_hold, false, "last 29ms excluded")
        eq(step(f, 4, boundary + 4 - 0.031).action_one_hold, true, "31ms before next matching edge")
        f:consume(f.server_state, 4)
        eq(f.server:current_stage(), 2); eq(f.server._mistakes, 0)
    end)
end

for _, path in ipairs({ "update", "input" }) do
    for _, target_kind in ipairs({ "same", "different" }) do
        test("Scan " .. path .. " abort cooldown, " .. target_kind .. " target", function()
            local f = H.scan_fixture(fixture)
            f:resume(f.a)
            local first = f:sample(1)
            eq(first.action_one_pressed, true); eq(first.action_one_hold, true)
            f:confirm()
            f.t = 10.1
            f:abort()
            if path == "update" then f.mod.update(0.02)
            else eq(f:sample(2).action_one_pressed, false, "aborted component cannot press") end
            local target = target_kind == "same" and f.a or f.b
            f.t = 10.11
            -- Discovering another target while still in confirm is insufficient.
            f.aim = target
            f.scan_action:fixed_update(0.02, f.t, 0)
            f.components.scanning.is_active = true
            eq(f:sample(3).action_one_pressed, false, "must return to native action_scan first")
            f.t = 10.12
            f:resume(target)
            local sample = f:sample(4)
            local immediate = target_kind == "different" and not baseline
            eq(sample.action_one_pressed, immediate, "target-scoped cooldown")
            eq(sample.action_one_hold, immediate)
            f.t = 10.399
            eq(f:sample(5).action_one_pressed, false, "same-target cooldown / no duplicate different-target edge")
            f.t = 10.401
            eq(f:sample(6).action_one_pressed, not immediate, "same failed target can retry after 300ms")
            if path == "update" and target_kind == "different" then
                print("  timing Scan next target after abort: " .. (baseline and "0.301s" or "0.020s"))
            end
        end)
    end
end

test("Scan native bank retains same-target ACK guard and permits another target", function()
    local f = H.scan_fixture(fixture)
    f:resume(f.a)
    eq(f:sample(1).action_one_pressed, true)
    f:confirm()
    f.t = 11.01
    f.confirm_action:finish("action_complete", nil, f.t, 1.01)
    eq(f.components.scanning.scannable_unit, nil, "native bank clears predicted component")
    f.mod.update(0.02)
    f.t = 11.02
    f:resume(f.a)
    eq(f:sample(2).action_one_pressed, false, "predicted bank is not replicated inactivity")
    f.t = 11.04
    f:resume(f.b)
    eq(f:sample(3).action_one_pressed, true, "pending ACK belongs only to first target")
    eq(f.extensions[f.a].mission_objective_zone_scannable_system:is_active(), true)
end)

for _, kind in ipairs({ "frequency", "decode_search", "decode_symbols" }) do
    for _, delay in ipairs({ 0.03, 0.165 }) do
        test("Full native solve: " .. kind .. ", receipt delay=" .. delay, function()
            local f = fixture({ frequency_solve_speed = 5, expedition_solve_speed = 5 })
            f.ping = delay * 2
            f:open(kind, true, delay)
            local origin = f.t
            for frame = 1, 1500 do
                f:tick(frame)
                if f.client:is_completed() then break end
            end
            eq(f.client:is_completed(), true, "client observed completion")
            eq(f.server:is_completed(), true, "native authority completed")
            eq(f.server._mistakes, 0, "zero mistakes through complete solve")
            print(string.format("  simulated %s complete in %.3fs, receipt delay %.3fs", kind, f.t - origin, delay))
        end)
    end
end

test("Symbols early stop retires board proof even when a later clock arrives", function()
    local f = symbols_case()
    f:receipt("symbols")
    for _, key in ipairs(orders[1]) do f:receipt(key) end
    f.client:stop(false)
    f:local_start()
    f:receipt("clock")
    f:attach()
    eq(step(f, 1, 20).action_one_hold, false)
    eq(step(f, 2, 20.01).action_one_hold, false, "a clock alone cannot reuse the stopped board fast path")
    eq(step(f, 3, 20.121).action_one_hold, true, "legacy stability fallback remains")
end)

print(string.format("RESULT %d passed, %d failed, %d BetterBrainer-only skipped", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
