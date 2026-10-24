-- Run from the repository root with LuaJIT: luajit tests/betterbrainer_suites.lua [suite ...]
-- BetterBrainer's own suites (BetterBrainer/tests/<suite>_spec.lua, unchanged) run through NoBrainer: each loads
-- tests/fixture.lua instead of BetterBrainer's, so the solvers run under NoBrainer's core, import and Symbols
-- wrapper. Each suite runs in its own process, as the suites end with os.exit. Without arguments, all run.
assert(jit and jit.version, "LuaJIT required")
local SUITES = { "speed", "search", "drill", "scan_marker", "reopen" }

if arg[1] == "--run" then
    local name = assert(arg[2], "usage: betterbrainer_suites.lua --run <suite> [suite arguments]")
    local path = "BetterBrainer/tests/" .. name .. "_spec.lua"
    local file = assert(io.open(path, "rb"), "no BetterBrainer suite " .. path)
    local text = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    local fixture = 'dofile("mods/active/BetterBrainer/tests/fixture.lua")'
    local first, last = text:find(fixture, 1, true)
    assert(first, path .. " no longer loads BetterBrainer's fixture")
    text = text:sub(1, first - 1) .. 'dofile("tests/fixture.lua")' .. text:sub(last + 1)
    local chunk = assert(loadstring(text, "@" .. path))
    arg = { select(3, unpack(arg)) }
    io.write("[NoBrainer] ")
    return chunk(unpack(arg))
end

local luajit = arg[-1] or "luajit"
local suites = #arg > 0 and arg or SUITES
local failed = {}
for _, name in ipairs(suites) do
    local code = os.execute('"' .. luajit .. '" tests/betterbrainer_suites.lua --run ' .. name)
    if code ~= 0 and code ~= true then failed[#failed + 1] = name end
end
print(#failed == 0 and "ALL SUITES PASSED" or "FAILED SUITES: " .. table.concat(failed, ", "))
os.exit(#failed == 0 and 0 or 1)
