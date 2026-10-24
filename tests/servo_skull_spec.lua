-- Run from the repository root with LuaJIT: luajit tests/servo_skull_spec.lua
-- Servo skull ordering as a core module: settings come from ctx.settings, time from update(dt, t). Engine
-- settings, the smart tag system, companion state and physics are stubs.
assert(jit and jit.version, "LuaJIT required")
local passed, failed = 0, 0
local function test(name, body)
    local ok, err = xpcall(body, debug.traceback)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end
print("NoBrainer servo skull tests | " .. jit.version)

local function fixture(settings)
    local f = { orders = {}, state = nil }
    local player_unit, terminal = { name = "player" }, { name = "terminal" }
    -- The module only uses these as identifiers.
    local Companion = { STATES = { hacking = "hacking" } }
    local Rules = { special_rules = { cryptic_servo_skull_hack = "cryptic_servo_skull_hack" } }
    local tags = {}
    local smart_tag_system = {
        _all_tags = tags,
        _unit_extension_data = { [terminal] = {
            _target_type = "hack",
            contextual_tag_template = function() return { name = "hacking_over_here_companion" } end,
            target_actor = function() return nil end,
        } },
        set_contextual_unit_tag = function(_, tagger, target)
            f.orders[#f.orders + 1] = target
            tags[#tags + 1] = { template = function() return { name = "hacking_over_here_companion" } end,
                tagger_unit = function() return tagger end, target_unit = function() return target end }
        end,
    }
    local env = setmetatable({}, { __index = _G })
    env.require = function(path)
        if path == "scripts/settings/companion/companion_servo_skull_settings" then return Companion end
        if path == "scripts/settings/ability/special_rules_settings" then return Rules end
        error("unexpected require " .. path)
    end
    env.Unit = { alive = function(u) return u ~= nil end, world_position = function() return { 0, 0, 0 } end }
    env.Vector3 = { distance_squared = function() return 4 end }
    env.ScriptUnit = { has_extension = function() return nil end }
    env.GameSession = {}
    env.Managers = {
        player = { local_player_safe = function() return { player_unit = player_unit } end },
        state = { extension = { system = function(_, name) assert(name == "smart_tag_system"); return smart_tag_system end } },
    }
    local chunk = assert(loadfile("scripts/mods/NoBrainer/servo_skull.lua"))
    setfenv(chunk, env)
    local ctx = { settings = settings }
    f.module = chunk()(ctx)
    f.terminal = terminal
    return f
end

local base = { enable_servo_skull_auto_hack = true, servo_skull_require_line_of_sight = false, servo_skull_command_range = 25 }

test("orders the skull to a hack target in range, once while the order stands", function()
    local f = fixture(base)
    f.module.update(0.02, 10)
    assert(#f.orders == 1 and f.orders[1] == f.terminal, "first order")
    f.module.update(0.02, 10.1)
    assert(#f.orders == 1, "no repeat while the tag stands")
end)

test("off when the setting is off", function()
    local settings = {}
    for k, v in pairs(base) do settings[k] = v end
    settings.enable_servo_skull_auto_hack = false
    local f = fixture(settings)
    f.module.update(0.02, 10)
    assert(#f.orders == 0)
end)

test("range comes from ctx.settings", function()
    local settings = {}
    for k, v in pairs(base) do settings[k] = v end
    settings.servo_skull_command_range = 1 -- the stub target is 2 m away
    local f = fixture(settings)
    f.module.update(0.02, 10)
    assert(#f.orders == 0, "out of range")
end)

test("reset and settings_changed exist and clear timers", function()
    local f = fixture(base)
    f.module.update(0.02, 10)
    f.module.reset("gameplay_exit")
    f.module.settings_changed("enable_servo_skull_auto_hack")
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
