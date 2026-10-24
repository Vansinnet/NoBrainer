local mod = get_mod("NoBrainer")
local path = "NoBrainer/scripts/mods/NoBrainer/"
local import = mod:io_dofile(path .. "import")

-- Settings saved by NoBrainer 3.1 and earlier used a 1-10 speed scale or "human"/"inhuman" strings; migrate once.
-- BetterBrainer's read_setting clamps every later value to its range.
if mod:get("_speed_schema_v2") ~= true then
    for id, old_default in pairs({ expedition_solve_speed = 5, drill_solve_speed = 5, frequency_solve_speed = 2 }) do
        local raw, speed = mod:get(id), 1
        local legacy = type(raw) == "string" and string.lower(raw):match("^%s*(.-)%s*$")
        local old = tonumber(raw)
        if legacy == "inhuman" then
            speed = 5
        elseif old and old == old and old ~= math.huge and old ~= -math.huge then
            old = math.max(1, math.min(10, math.floor(old + 0.5)))
            if old > old_default then
                speed = math.min(5, 1 + math.floor((old - old_default) * 4 / (10 - old_default) + 0.5))
            end
        end
        mod:set(id, speed, false)
    end
    mod:set("_speed_schema_v2", true, false)
end

-- BetterBrainer's core, running as NoBrainer: it reads NoBrainer's options, and its Symbols solver gets the
-- Smart Seed Reroll. Its context comes along with Symbols, the first solver it builds.
local ctx, seed_reroll
import("BetterBrainer", function(name, load)
    if name == "BetterBrainer_data" then return mod:io_dofile(path .. "NoBrainer_data") end
    local value = load()
    if name ~= "symbols" then return value end
    return function(core_ctx)
        ctx = core_ctx
        seed_reroll = mod:io_dofile(path .. "seed_reroll")(core_ctx)
        return seed_reroll.wrap(value(seed_reroll.ctx))
    end
end)

local servo_skull = mod:io_dofile(path .. "servo_skull")(ctx)

local update, on_setting_changed = mod.update, mod.on_setting_changed
local on_enabled, on_disabled = mod.on_enabled, mod.on_disabled
local on_game_state_changed, on_unload = mod.on_game_state_changed, mod.on_unload

mod.update = function(dt)
    update(dt)
    if mod:is_enabled() then servo_skull.update(dt, ctx.time()) end
end

mod.on_setting_changed = function(id)
    on_setting_changed(id)
    servo_skull.settings_changed(id)
end

mod.on_enabled = function()
    on_enabled()
    servo_skull.reset("enabled")
end

mod.on_disabled = function()
    on_disabled()
    servo_skull.reset("disabled")
end

mod.on_game_state_changed = function(status, name)
    on_game_state_changed(status, name)
    if status == "exit" and name == "StateGameplay" then servo_skull.reset("gameplay_exit") end
end

mod.on_unload = function(exit_game)
    on_unload(exit_game)
    servo_skull.reset("unload")
end
