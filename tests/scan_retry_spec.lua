-- Auto-scan retry after an interrupted confirm: only the failed target waits (BetterBrainer 1.0.2).
-- Loads the real NoBrainer_input.lua and NoBrainer_minigame_scan.lua against a mocked DMF mod, player and
-- scanner components. Offline evidence, not an in-game test. Run from the workspace root:
--   tools/luajit/luajit.exe mods/active/NoBrainer/tests/scan_retry_spec.lua
local ROOT = "mods/active/NoBrainer/scripts/mods/NoBrainer/"
local passed, failed = 0, 0
local function test(name, body)
    local ok, err = xpcall(body, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end
local function eq(actual, expected, why)
    assert(actual == expected, (why or "equality") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function world()
    local w = { t = 100, regs = {}, settings = { enable_scan = false, enable_auto_scan = true } }
    w.weapon_action = { current_action_name = "action_scan" }
    w.scanning = { is_active = true, line_of_sight = true, scannable_unit = nil }
    w.a, w.b = { name = "A" }, { name = "B" }
    local player = { player_unit = {} }
    local unit_data = { read_component = function(_, name)
        return name == "weapon_action" and w.weapon_action or name == "scanning" and w.scanning or nil
    end }
    local scannable = { is_active = function() return true end }
    local mod = {}
    w.mod = mod
    function mod:is_enabled() return true end
    function mod:hook() end
    function mod:hook_safe(_, method, callback) if method == "_bank_scannable_unit" then w.bank = callback end end
    function mod:hook_require(path, callback) if path:find("action_scan_confirm", 1, true) then w.bank_hook = callback end end
    mod._S = function(id) return w.settings[id] end
    mod._time = function() return w.t end
    mod._reg = function(event, callback) w.regs[event] = w.regs[event] or {}; table.insert(w.regs[event], callback) end
    local env = setmetatable({
        get_mod = function() return mod end,
        CLASS = { InputService = {} },
        Managers = { ui = { view_active = function() return false end },
            player = { local_player_safe = function() return player end } },
        ScriptUnit = { has_extension = function(unit, name)
            if unit == player.player_unit and name == "unit_data_system" then return unit_data end
            if (unit == w.a or unit == w.b) and name == "mission_objective_zone_scannable_system" then return scannable end
        end },
        Unit = { alive = function(unit) return unit ~= nil end },
        require = function(path)
            assert(path == "scripts/settings/equipment/weapon_templates/devices/scanner_equip", path)
            return { actions = { action_scan_confirm = { scan_settings = { confirm_time = 1 } } } }
        end,
        table = setmetatable({ clear = function(t) for k in pairs(t) do t[k] = nil end end }, { __index = table }),
    }, { __index = _G })
    for _, name in ipairs({ "NoBrainer_minigame_scan", "NoBrainer_input" }) do
        local chunk = assert(loadfile(ROOT .. name .. ".lua"))
        setfenv(chunk, env)
        assert(chunk())
    end
    mod._scan_auto_pending, mod._scan_holding, mod._scan_hold_until = false, false, 0
    mod._scan_retry_until = 0
    function w:update() for _, callback in ipairs(self.regs.update) do callback(0.02) end end
    function w:press() return mod._route_input("action_one_pressed", false, "input_service") end
    function w:aim(target) self.scanning.scannable_unit = target end
    return w
end

local function start_hold(w, target)
    w:aim(target)
    w:update()
    eq(w.mod._scan_auto_pending, true, "target acquired")
    eq(w:press(), true, "automatic press")
    eq(w.mod._scan_hold_target, target)
    w.weapon_action.current_action_name = "action_scan_confirm"
    w:update()
end

test("Interrupted confirm: a different target is acquired at once", function()
    local w = world()
    start_hold(w, w.a)
    w.t = w.t + 0.1
    w.weapon_action.current_action_name = "action_scan"
    w:aim(w.b)
    w:update()
    eq(w.mod._scan_auto_pending, true, "another target does not wait for the failed one's retry delay")
end)

test("Interrupted confirm: the same target waits 0.3 s from the interruption", function()
    local w = world()
    start_hold(w, w.a)
    w.t = w.t + 0.5
    w.weapon_action.current_action_name = "action_scan"
    w:update()
    eq(w.mod._scan_auto_pending, false, "same target right after the interruption")
    w.t = w.t + 0.29
    w:update()
    eq(w.mod._scan_auto_pending, false, "still inside the retry delay")
    w.t = w.t + 0.02
    w:update()
    eq(w.mod._scan_auto_pending, true, "retry after the delay")
end)

test("Completed confirm: the banked target is not scanned again, another one is", function()
    local w = world()
    start_hold(w, w.a)
    w.bank_hook({})
    w.bank()
    w.t = w.t + 1.2
    w.weapon_action.current_action_name = "action_scan"
    w:update()
    w.t = w.t + 1
    w:update()
    eq(w.mod._scan_auto_pending, false, "banked target")
    w:aim(w.b)
    w:update()
    eq(w.mod._scan_auto_pending, true, "next target")
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
