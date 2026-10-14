-- Run from the workspace root with tools/luajit/luajit.exe (see README.md).
-- Scan highlight markers: kept on through the game's own outline removals while the object is active, released
-- the moment the object is deactivated (the server's banked scan), not at the next one-second refresh.
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

print("NoBrainer scan marker tests | " .. jit.version .. " | source " .. (FIXTURE_SOURCE_VERSION or "darktide-source") .. "")

-- The scan fixture with highlighting on, an outline system that records outlines per unit, and a scanning zone
-- holding both scannables.
local function marker_fixture()
    local f = H.scan_fixture(fixture)
    local outlines = {}
    f.outlines = outlines
    local outline_system = {
        add_outline = function(_, unit, name) outlines[unit] = outlines[unit] or {}; outlines[unit][name] = true end,
        remove_outline = function(_, unit, name) if outlines[unit] then outlines[unit][name] = nil end end,
    }
    local zone = {
        scannable_units = function() return { [f.a] = true, [f.b] = true } end,
        any_active_scanning_zone = function() return true end,
    }
    f.env.Managers.state.extension = {
        has_system = function() return true end,
        system = function(_, name)
            if name == "outline_system" then return outline_system end
            eq(name, "mission_objective_zone_system")
            return zone
        end,
    }
    f:set("enable_scan", true)
    f.mod.update(0.02)
    return f
end

local function lit(f, unit)
    local entry = f.outlines[unit]
    return entry ~= nil and entry.scanning == true and entry.scanning_confirm == true
end

local function extension(f, unit)
    return f.extensions[unit].mission_objective_zone_scannable_system
end

test("Markers survive the game's outline removals while the object is active", function()
    local f = marker_fixture()
    eq(lit(f, f.a), true, "a marked")
    eq(lit(f, f.b), true, "b marked")
    -- Aiming away, or the client's predicted confirm, clears the scanner's outline on the object.
    extension(f, f.a):set_scanning_outline(false)
    extension(f, f.a):set_scanning_highlight(false)
    eq(lit(f, f.a), true, "an active object stays marked")
end)

test("The server's deactivation releases the marker at once", function()
    local f = marker_fixture()
    extension(f, f.a):set_scanning_outline(false)
    extension(f, f.a):set_scanning_highlight(false)
    -- rpc_mission_objective_zone_scannable_set_active (or the host's own set_scanned) deactivates the object.
    extension(f, f.a):set_active(false)
    eq(lit(f, f.a), false, "released without waiting for the refresh")
    eq(f.outlines[f.a].scanning, nil)
    eq(f.outlines[f.a].scanning_confirm, nil)
    eq(lit(f, f.b), true, "other objects stay marked")
    f.t = f.t + 1.5
    f.mod.update(0.02)
    eq(lit(f, f.a), false, "a refresh does not mark the scanned object again")
end)

test("Releasing replays an outline the game still wants", function()
    local f = marker_fixture()
    -- The scanner still outlines the object (requested on) when it is deactivated.
    extension(f, f.a):set_scanning_outline(true)
    extension(f, f.a):set_scanning_highlight(false)
    extension(f, f.a):set_active(false)
    eq(f.outlines[f.a].scanning, true, "the game's own outline is kept")
    eq(f.outlines[f.a].scanning_confirm, nil, "the confirm highlight the game cleared is removed")
end)

test("Reactivation is marked again on the next refresh", function()
    local f = marker_fixture()
    extension(f, f.a):set_active(false)
    eq(lit(f, f.a), false)
    extension(f, f.a):set_active(true)
    f.t = f.t + 1.5
    f.mod.update(0.02)
    eq(lit(f, f.a), true, "an active object is marked again")
end)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
