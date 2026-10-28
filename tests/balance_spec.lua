-- Balance closed loop: the server's update and on_axis_set (minigame_balance.lua:89-187, game settings) against
-- balance.lua over a delayed link. Positions reach the solver quantized; the server may run input up to two ticks
-- later than the solver assumes. Distances are in board radii; the player fails at 1.
-- usage (workspace root): tools\luajit\luajit.exe mods\active\NoBrainer\tests\balance_spec.lua [balance.lua]
local SOURCE = "darktide-source/"
local FILE = arg[1] or "mods/active/NoBrainer/scripts/mods/NoBrainer/balance.lua"
local TICK, SECONDS, SEEDS, QUANTUM = 1 / 52, 30, 4, 0.004

function math.clamp(v, lo, hi) return v < lo and lo or v > hi and hi or v end
function math.degrees_to_radians(d) return d * math.pi / 180 end
function table.clear(t) for k in pairs(t) do t[k] = nil end end
function table.enum(...) local t = {} for _, v in ipairs({ ... }) do t[v] = v end return t end
function Vector3(x, y, z) return { x = x, y = y, z = z } end
Unit = { alive = function() return true end }
local chunk = assert(loadfile(SOURCE .. "scripts/settings/minigame/minigame_settings.lua"))
setfenv(chunk, setmetatable({ settings = function(_, t) return t end }, { __index = _G }))
local S = chunk()
package.loaded["scripts/settings/minigame/minigame_settings"] = S

local function quantize(v) return math.floor(v / QUANTUM + 0.5) * QUANTUM end

local function run(rtt, host, seed, lag, kicks)
    local now = 0
    Managers = {
        connection = {
            is_client = function() return not host end,
            is_host = function() return host end,
            tick_rate = function() return 1 / TICK end,
            host = function() return "server" end,
        },
        ui = { view_active = function() return true end },
    }
    Network = { ping = function() return rtt end }
    local mg = {
        _is_server = host, _minigame_unit = {}, _position = { x = 0, y = 0 },
        is_completed = function() return false end,
        state = function() return S.game_states.gameplay end,
        position = function(self) return self._position end,
    }
    local class = {}
    local ctx = {
        settings = { enable_balance = true },
        active_minigame = mg,
        time = function() return now end,
        is_local_player = function() return true end,
        session_valid = function() return true end,
        mod = {
            hook_require = function(_, _, callback) callback(class) end,
            hook_safe = function(_, target, name, fn) target[name] = fn end,
        },
    }
    local solver = assert(loadfile(FILE))()(ctx)
    class.start(mg, "local")

    math.randomseed(seed)
    local pos, speed = { x = 0, y = 0 }, { x = 0, y = 0 }
    local disrupt, last_axis, input_x, input_y = 0, 0, 0, 0
    local inbox, outbox = {}, {}
    local worst, sum, n, fails, hold = 0, 0, 0, 0, 0
    local next_client, next_server = (seed % 4) / 4 * TICK, 0
    while now < SECONDS do
        if next_server <= next_client then
            now = next_server
            while inbox[1] and inbox[1].at <= now + 1e-9 do
                local m = table.remove(inbox, 1)
                input_x, input_y = m.x, m.y
            end
            local dt = now - last_axis
            last_axis = now
            speed.x = speed.x + input_x * S.balance_move_ratio * dt
            speed.y = speed.y - input_y * S.balance_move_ratio * dt
            pos.x, pos.y = pos.x + speed.x * TICK, pos.y + speed.y * TICK
            local aim = math.atan2(-pos.y, pos.x)
            local d = math.sqrt(pos.x * pos.x + pos.y * pos.y)
            if d > 1.02 then
                pos.x, pos.y, speed.x, speed.y = math.cos(aim) * 1.01, -math.sin(aim) * 1.01, 0, 0
            elseif d < 1 then
                local power = (1 - d) * S.balance_push_ratio * TICK
                speed.x, speed.y = speed.x + math.cos(aim) * power, speed.y - math.sin(aim) * power
            end
            disrupt = disrupt - TICK
            if d >= 1 then
                disrupt, fails = S.balance_disrupt_interval, fails + 1
            elseif disrupt <= 0 then
                disrupt = disrupt + S.balance_disrupt_interval
                local angle = math.random(0, math.pi * 2)
                if kicks then
                    speed.x = speed.x + math.cos(angle) * S.balance_disrupt_power
                    speed.y = speed.y - math.sin(angle) * S.balance_disrupt_power
                end
            end
            speed.x = math.clamp(speed.x, -S.balance_max_speed, S.balance_max_speed)
            speed.y = math.clamp(speed.y, -S.balance_max_speed, S.balance_max_speed)
            if now > 3 then
                worst, sum, n = math.max(worst, d), sum + d * d, n + 1
                if disrupt < S.balance_disrupt_interval - 1.2 then hold = math.max(hold, d) end
            end
            if host then
                mg._position.x, mg._position.y = pos.x, pos.y
            else
                outbox[#outbox + 1] = { at = now + rtt * 0.5, x = quantize(pos.x), y = quantize(pos.y) }
            end
            next_server = next_server + TICK
        else
            now = next_client
            while outbox[1] and outbox[1].at <= now + 1e-9 do
                local m = table.remove(outbox, 1)
                mg._position.x, mg._position.y = m.x, m.y
                class.set_position(mg, m.x, m.y)
            end
            solver.observe(mg, now)
            local right = solver.input("move_right", 0, now, "input_service")
            local left = solver.input("move_left", 0, now, "input_service")
            local forward = solver.input("move_forward", 0, now, "input_service")
            local backward = solver.input("move_backward", 0, now, "input_service")
            if host then
                input_x, input_y = right - left, forward - backward
            else
                inbox[#inbox + 1] = { at = now + rtt * 0.5 + (1 + lag) * TICK, x = right - left, y = forward - backward }
            end
            next_client = next_client + TICK
        end
    end
    return worst, math.sqrt(sum / n), fails, hold
end

local function measure(rtt, host, lag)
    local worst, rms, fails, hold = 0, 0, 0, 0
    for seed = 1, SEEDS do
        local w, r, f = run(rtt, host, seed, lag, true)
        local _, _, _, h = run(rtt, host, seed, lag, false)
        worst, rms, fails, hold = math.max(worst, w), rms + r / SEEDS, fails + f, math.max(hold, h)
    end
    return worst, rms, fails, hold
end

-- Limits: { label, rtt, host, lag, max, rms, hold without kicks }.
local cases = {
    { "host", 0, true, 0, 0.10, 0.04, 0.01 },
    { "rtt 30 ms", 0.03, false, 0, 0.18, 0.06, 0.04 },
    { "rtt 30 ms, lag +2", 0.03, false, 2, 0.22, 0.07, 0.05 },
    { "rtt 80 ms", 0.08, false, 0, 0.25, 0.08, 0.05 },
    { "rtt 80 ms, lag +2", 0.08, false, 2, 0.30, 0.09, 0.06 },
    { "rtt 150 ms", 0.15, false, 0, 0.35, 0.12, 0.10 },
    { "rtt 250 ms", 0.25, false, 0, 0.50, 0.18, 0.25 },
}
local passed, failed = 0, 0
for _, c in ipairs(cases) do
    local worst, rms, fails, hold = measure(c[2], c[3], c[4])
    local ok = fails == 0 and worst <= c[5] and rms <= c[6] and hold <= c[7]
    print(string.format("%s %-18s max %.3f rms %.3f hold %.3f fails %d", ok and "PASS" or "FAIL", c[1], worst, rms,
        hold, fails))
    if ok then passed = passed + 1 else failed = failed + 1 end
end
print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
