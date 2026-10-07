-- NoBrainer-only integration checks on the shared fixture (Smart Seed Reroll with the frame Symbols solver,
-- Frequency opening receipts). Run from the workspace root with tools/luajit/luajit.exe (see README.md).
assert(jit and jit.version, "LuaJIT required")
local H = dofile("mods/active/NoBrainer/tests/fixture.lua")
local fixture = H.factory()
local eq = H.eq
local passed, failed = 0, 0
local function test(name, body)
    local ok, err = xpcall(body, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end

print("NoBrainer integration tests | " .. jit.version .. " | source " .. (FIXTURE_SOURCE_VERSION or "darktide-source") .. "")

local function symbols(seed, values, delay, before)
    local f = fixture(values)
    if before then before(f) end
    local Symbols = f.env.MinigameDecodeSymbols
    local init = Symbols.init
    Symbols.init = function(self, unit, is_server, _, context) return init(self, unit, is_server, seed, context) end
    f:open("decode_symbols", true, delay or 0.05)
    Symbols.init = init
    return f
end

test("Smart Seed Reroll owns stage 1: no press while it decides, accepted boards solve with zero mistakes", function()
    local accepted, cancelled = 0, 0
    for seed = 1, 40 do
        local evaluations, synced_seen = 0, false
        local f = symbols(seed * 7919, { enable_decode_smart_reroll = true }, nil, function(f)
            local evaluate = f.mod._ds_reroll_evaluate
            f.mod._ds_reroll_evaluate = function(mg, t, synced)
                evaluations = evaluations + 1
                synced_seen = synced_seen or synced == true
                return evaluate(mg, t, synced)
            end
        end)
        local mod = f.mod
        local cancel_frame
        for frame = 1, 1500 do
            local blocked = mod._ds_reroll_blocks_solver()
            local sample = f:tick(frame)
            if blocked then
                eq(sample.action_one_hold, false, "seed " .. seed .. ": press while Smart Seed Reroll owns the board")
            end
            if sample.action_two_pressed then cancel_frame = frame; break end
            if f.client:is_completed() then break end
        end
        assert(evaluations > 0 and synced_seen, "seed " .. seed .. ": the reroll never valued a synchronized board")
        if cancel_frame then
            local phase = mod._ds_reroll_phase()
            eq(phase, "cancel_sent", "seed " .. seed .. ": cancel without a reroll decision")
            eq(f.server._current_stage, 1, "seed " .. seed .. ": the cancelled board was never pressed")
            cancelled = cancelled + 1
        else
            eq(f.client:is_completed(), true, "seed " .. seed .. ": accepted board solved")
            eq(f.server._mistakes, 0, "seed " .. seed .. ": zero mistakes")
            accepted = accepted + 1
        end
    end
    assert(accepted > 0, "no accepted board exercised")
    print(string.format("  %d boards accepted and solved, %d cancelled for a reroll", accepted, cancelled))
end)

test("Smart Seed Reroll off: the solver presses as soon as the board is synchronized", function()
    local calls = 0
    local f = symbols(4242, { enable_decode_smart_reroll = false }, nil, function(f)
        local evaluate = f.mod._ds_reroll_evaluate
        f.mod._ds_reroll_evaluate = function(...) calls = calls + 1; return evaluate(...) end
    end)
    for frame = 1, 1500 do
        f:tick(frame)
        if f.client:is_completed() then break end
    end
    eq(f.client:is_completed(), true, "solved")
    eq(f.server._mistakes, 0, "zero mistakes")
    eq(calls, 0, "no reroll valuation while the setting is off")
end)

test("Smart Seed Reroll stage-ready delay follows the frame solver", function()
    local f = symbols(99, {})
    local frames = 2 * 0.02
    assert(math.abs(f.mod._ds_stage_ready_delay(true) - frames) < 1e-9, "host: one release and one press frame")
    assert(math.abs(f.mod._ds_stage_ready_delay(false) - frames) < 1e-9, "client presses ahead of receipts")
end)

-- Frequency (NoBrainer's own solver) samples from its view hook.
local VIEW = "scripts/ui/views/scanner_display_view/minigame_frequency_view"
local function frequency(values)
    local f = fixture(values)
    local View = { draw_widgets = function() end, init = function() end, destroy = function() end }
    f.deferred[VIEW](View)
    f:open("frequency", true, 0.05)
    f.view = { _minigame_extension = { minigame = function() return f.client end } }
    function f:draw() View.draw_widgets(self.view, 0.02, self.t, nil, nil) end
    return f
end

test("Frequency waits for a fresh opening: own start plus stage and target receipts", function()
    local f = frequency({ frequency_solve_speed = 5, enable_frequency_highlight = false })
    local mod = f.mod
    f:draw()
    eq(mod._freq.fresh, true, "opening receipts delivered with the start")
    eq(mod._freq_startup_delay, 0, "speed 5 starts without an opening delay")
    -- A later session on the same terminal: the retained board is not fresh until new receipts arrive.
    f.client:stop(f.player)
    f.t = f.t + 2
    f.client:start(f.player)
    f:draw()
    eq(mod._freq.session_active, true, "new session armed")
    eq(mod._freq.fresh, false, "retained stage and target are not receipts")
    eq(mod._freq_move_vec(), nil, "no steering from a retained board")
    eq(mod._freq_try_submit(f.t), false, "no submission from a retained board")
    f.client:set_current_stage(1)
    f:draw()
    eq(mod._freq.fresh, false, "stage receipt alone is not enough")
    local target = f.client:target_frequency()
    f.client:set_target_frequency(target.x, target.y)
    f:draw()
    eq(mod._freq.fresh, true, "stage and target receipts complete the opening")
end)

test("Frequency opening delay scales from 0.75 s at speed 1 to zero at speed 5", function()
    for speed, expected in pairs({ [1] = 0.75, [3] = 0.375, [5] = 0 }) do
        local f = frequency({ frequency_solve_speed = speed, enable_frequency_highlight = false })
        assert(math.abs(f.mod._freq_startup_delay - expected) < 1e-9,
            "speed " .. speed .. ": " .. tostring(f.mod._freq_startup_delay))
    end
end)

test("Frequency quick restart: the server's stop receipt keeps the new opening", function()
    local f = frequency({ frequency_solve_speed = 5, enable_frequency_highlight = false })
    local mod = f.mod
    f:draw()
    -- Leave, then re-interact before the server's argumentless stop of the old session arrives.
    f.client:stop(f.player)
    f.t = f.t + 0.3
    f.client:start(f.player)
    f.client:stop()
    f.client:generate_board(12345)
    f.client:set_current_stage(1)
    local target = f.client:target_frequency()
    f.client:set_target_frequency(target.x + 0.5, target.y + 0.5)
    mod._freq_rearm_from_state({ _minigame = f.client, _player = f.player }, f.t)
    f:draw()
    eq(mod._freq.session_active, true, "recovered session armed")
    eq(mod._freq.fresh, true, "own restart plus the new receipts")
    assert(mod._freq_move_vec() ~= nil, "steers the recovered session")
end)

test("A foreign start retires the opening", function()
    local f = frequency({ frequency_solve_speed = 5, enable_frequency_highlight = false })
    f:draw()
    eq(f.mod._freq.fresh, true)
    f.client:start(f.remote)
    f.t = f.t + 2
    f.client:start(f.player)
    f:draw()
    eq(f.mod._freq.fresh, false, "receipts from before another player's session are not fresh")
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
