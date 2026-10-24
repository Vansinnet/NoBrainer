-- Run from the repository root with LuaJIT: luajit tests/nobrainer_spec.lua
-- NoBrainer on top of the BetterBrainer submodule, through a minimal DMF stub: the import of BetterBrainer's core,
-- data and localization, and Smart Seed Reroll's decisions through BetterBrainer's Symbols solver. Engine
-- functions are stubs. Boards come from the game's setup_game (tests/darktide_source.lua fetches it), but
-- math.next_random is native to the engine, so a stand-in generator replaces it.
assert(jit and jit.version, "LuaJIT required")
local failures, checks = 0, 0
local function check(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- Deterministic stand-in for the engine's math.next_random.
math.next_random = function(seed, a, b)
    seed = (seed * 1103515245 + 12345) % 2147483648
    local r = seed / 2147483648
    if b then return seed, a + math.floor(r * (b - a + 1)) end
    return seed, 1 + math.floor(r * a)
end

local values, hooks, loaded = {}, {}, {}
local DMFMod = {}
DMFMod.__index = DMFMod
function DMFMod:io_dofile_unsafe(p)
    loaded[#loaded + 1] = p
    -- DMF paths start at the mods folder; this repository is its NoBrainer folder.
    return assert(loadfile(assert(p:match("^NoBrainer/(.+)$"), p) .. ".lua"))()
end
function DMFMod:io_dofile(p) return self:io_dofile_unsafe(p) end
function DMFMod:get(id) return values[id] end
function DMFMod:set(id, v) values[id] = v end
function DMFMod:localize(id) return "loc:" .. id end
function DMFMod:debug() end
function DMFMod:is_enabled() return true end
function DMFMod:hook(obj, name, fn) hooks[tostring(obj) .. "." .. name] = fn end
function DMFMod:hook_safe(obj, name, fn) hooks[tostring(obj) .. "." .. name] = fn end
function DMFMod:hook_require(path, fn) hooks[path] = fn end
local mod = setmetatable({}, DMFMod)
function get_mod(name) return name == "NoBrainer" and mod or nil end
CLASS = { InputService = "InputService" }
Managers = { player = { local_player_safe = function() return PLAYER end }, state = { game_session = { fixed_time_step = 1 / 52 } } }
PLAYER = { player_unit = {} }
function require(p)
    if p:find("scanner_equip") then return { actions = { action_scan_confirm = { scan_settings = { confirm_time = 1 } } } } end
    if p:find("companion_servo_skull_settings") then return { STATES = { hacking = "hacking" } } end
    if p:find("special_rules_settings") then return { special_rules = {} } end
    if p:find("minigame_settings") or p:find("view_settings") or p:find("_settings$") then
        return setmetatable({}, { __index = function() return 4 end })
    end
    return {}
end
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end

-- Capture the core context and the wrapped Symbols module through the seed_reroll load.
local core_ctx, symbols, seed
local real = DMFMod.io_dofile
function DMFMod:io_dofile(p)
    local value = real(self, p)
    if p:match("seed_reroll$") then
        return function(c)
            core_ctx = c
            seed = value(c)
            local wrap = seed.wrap
            seed.wrap = function(m) symbols = wrap(m); return symbols end
            return seed
        end
    end
    return value
end

-- DMF order: localization, data, script.
local localization = mod:io_dofile_unsafe("NoBrainer/scripts/mods/NoBrainer/NoBrainer_localization")
local data = mod:io_dofile_unsafe("NoBrainer/scripts/mods/NoBrainer/NoBrainer_data")
mod:io_dofile_unsafe("NoBrainer/scripts/mods/NoBrainer/NoBrainer")

check(localization.mod_name.en == "No Brainer", "NoBrainer name")
check(localization.decode_reroll_limit ~= nil, "BetterBrainer strings imported")
check(localization.enable_decode_smart_reroll_tooltip ~= nil, "smart reroll strings")
check(localization.servo_skull_group ~= nil, "servo skull strings")
check(data.name == "loc:mod_name", "BetterBrainer data localizes through NoBrainer")
local widgets = data.options.widgets
check(widgets[2].setting_id == "servo_skull_group", "servo skull group after language")
local sym = widgets[3].sub_widgets
check(sym[3].setting_id == "decode_reroll_limit" and sym[4].setting_id == "enable_decode_smart_reroll", "smart reroll after limit")
check(get_mod("BetterBrainer") == nil and rawget(mod, "io_dofile") == nil, "import restored get_mod and io_dofile")
check(core_ctx and symbols and seed, "context and Symbols captured")
check(core_ctx.settings.enable_servo_skull_auto_hack == true, "NoBrainer options read by the core")
check(type(mod.update) == "function" and type(mod.on_setting_changed) == "function", "callbacks")
for _, p in ipairs(loaded) do
    check(not p:match("^BetterBrainer/"), "no load outside NoBrainer: " .. p)
end
check(hooks["MinigameSystem.init"] and hooks["MinigameSystem.on_add_extension"], "seed tracking hooks")
mod.update(0.02)

-- Boards come from the game's own MinigameDecodeSymbols.setup_game, minigame settings and table.shuffle.
local source = dofile("tests/darktide_source.lua")
local SYMBOLS = "scripts/extension_systems/minigame/minigames/minigame_decode_symbols.lua"
local SETTINGS = "scripts/settings/minigame/minigame_settings.lua"
local TABLE = "scripts/foundation/utilities/table.lua"
local root = source.root({ SYMBOLS, SETTINGS, TABLE })
local game = setmetatable({}, { __index = _G })
game.table = setmetatable({ enum = function(...)
    local enum = {}
    for _, name in ipairs({ ... }) do enum[name] = name end
    return enum
end }, { __index = table })
function game.settings(_, values) return values end
game.math = setmetatable({ degrees_to_radians = function(d) return d * math.pi / 180 end }, { __index = math })
local function load_source(file, text)
    local chunk = assert(loadstring(text or source.read(root, file), "@" .. file))
    setfenv(chunk, game)
    return chunk()
end
-- table.lua as a whole needs much of the engine; only table.shuffle is taken from it.
local shuffle = assert(source.read(root, TABLE):match("\n(table%.shuffle = function.-\nend)\n"), "table.shuffle not found")
shuffle = assert(loadstring("local table = ...\n" .. shuffle, "@" .. TABLE))
setfenv(shuffle, game)
shuffle(game.table)
local classes = { MinigameBase = { setup_game = function() end } }
function game.class(name, super)
    local class = { super = classes[super] }
    class.__index = class
    classes[name] = class
    return class
end
local Settings = load_source(SETTINGS)
function game.require(path)
    if path == "scripts/settings/minigame/minigame_settings" then return Settings end
    return {}
end
game.Managers = { state = { game_session = { send_rpc_clients = function() end },
    unit_spawner = { game_object_id_or_level_index = function() return false, 1 end } } }
local DecodeSymbols = load_source(SYMBOLS)

-- One setup_game from seed `s`: the board it deals and the seed it leaves behind.
local function board(s)
    local mg = setmetatable({ _seed = s, _stage_amount = Settings.decode_symbols_stage_amount,
        _decode_symbols_items_per_stage = Settings.decode_symbols_items_per_stage,
        _decode_symbols_total_items = Settings.decode_symbols_total_items,
        _symbols = {}, _decode_targets = {}, _minigame_unit = {} }, DecodeSymbols)
    mg:setup_game()
    return mg._symbols, mg._decode_targets, mg._seed
end

local function minigame(is_server, s, extension)
    local symbols_, targets, post = board(s)
    local mg = { _is_server = is_server, _seed = is_server and post or nil, _symbols = symbols_, _decode_targets = targets,
        _decode_start_time = 10, _current_stage = 1, _stage_amount = Settings.decode_symbols_stage_amount,
        _decode_symbols_items_per_stage = Settings.decode_symbols_items_per_stage,
        _decode_symbols_sweep_duration = Settings.decode_symbols_sweep_duration, _current_state = "gameplay",
        _minigame_extension = extension }
    function mg:is_completed() return false end
    return mg, post
end

local requests = 0
core_ctx.request_reopen = function() requests = requests + 1; return true end
core_ctx.session_valid = function() return true end
core_ctx.active_minigame = nil
core_ctx.settings.decode_reroll_limit = 2

-- Host: over many seeds, some boards are rerolled and some kept, and a reroll predicts the next board exactly.
local rerolled, kept = 0, 0
for s = 1, 200 do
    symbols.reset("enabled")
    local before = requests
    local mg, post = minigame(true, s * 7919)
    symbols.start(mg, PLAYER)
    symbols.observe(mg, 10.3)
    if requests > before then
        rerolled = rerolled + 1
        check(symbols.input("action_one_hold", false, 10.3, "input_service") == false, "presses held while rolling")
        -- Resume into the predicted board: it is recognised from the prediction.
        symbols.resume(mg, 10.6)
        local symbols2, targets2, post2 = board(post)
        mg._symbols, mg._decode_targets, mg._seed, mg._decode_start_time = symbols2, targets2, post2, 10.6
        symbols.start(mg, PLAYER)
        symbols.observe(mg, 10.9)
    else
        kept = kept + 1
    end
end
print(string.format("host: %d rerolled, %d kept of 200", rerolled, kept))
check(rerolled > 0 and kept > 0, "host decides both ways")

-- Client: the board is the third this terminal dealt; its seed is rebuilt from the level seed.
local system, extension = {}, {}
hooks["MinigameSystem.init"](function() end, system, {}, { level_seed = 4242 })
hooks["MinigameSystem.on_add_extension"](function() return {} end, system)
hooks["MinigameSystem.on_add_extension"](function() return extension end, system)
local _, _, s1 = board(4243)
local _, _, s2 = board(s1)
local seen = {}
mod.debug = function(_, fmt, ...) seen[#seen + 1] = string.format(fmt, ...) end
symbols.reset("enabled")
local mg = minigame(false, s2, extension)
hooks["MinigameDecodeSymbols.set_start_time"](mg, 10)
symbols.start(mg, PLAYER)
-- Client sync waits for receipts; skip that by observing a session that already shows a later frame.
symbols.observe(mg, 10.3)
symbols.observe(mg, 10.5)
local rebuilt = false
for _, line in ipairs(seen) do if line:find("rebuilt seed") then rebuilt = true end end
check(rebuilt, "client seed rebuilt: " .. table.concat(seen, " | "))

-- Smart reroll off: BetterBrainer's own reroll gets the limit.
core_ctx.settings.enable_decode_smart_reroll = false
seen = {}
symbols.reset("enabled")
mg = minigame(true, 12345)
symbols.start(mg, PLAYER)
symbols.observe(mg, 10.3)
local average = false
for _, line in ipairs(seen) do if line:find("^Symbols") then average = true end end
check(average, "BetterBrainer reroll decides when smart reroll is off: " .. table.concat(seen, " | "))

print(string.format("%d/%d checks passed", checks - failures, checks))
os.exit(failures == 0 and 0 or 1)
