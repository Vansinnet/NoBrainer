local mod = get_mod("NoBrainer")
-- The BetterBrainer git submodule, as installed inside NoBrainer's own folder.
local ROOT = "NoBrainer/BetterBrainer/scripts/mods/BetterBrainer/"
local PREFIX = "BetterBrainer/scripts/mods/BetterBrainer/"

-- Runs one BetterBrainer file as part of NoBrainer: get_mod("BetterBrainer") yields NoBrainer, and the file's own
-- `mod:io_dofile(path .. name)` loads resolve inside the submodule. `nested(name, load)` may take over such a load:
-- `load()` runs the BetterBrainer file, and nested returns the value the importing file receives. Imports nest
-- (BetterBrainer.lua loads NoBrainer_data, which imports BetterBrainer_data), so each restores what it replaced.
return function(name, nested)
    local real_get_mod, previous = get_mod, rawget(mod, "io_dofile")
    mod.io_dofile = nil
    local io_dofile = mod.io_dofile
    mod.io_dofile = function(self, file_path)
        local inner = file_path:sub(1, #PREFIX) == PREFIX and file_path:sub(#PREFIX + 1)
        if not inner then return io_dofile(self, file_path) end
        local function load() return io_dofile(self, ROOT .. inner) end
        if nested then return nested(inner, load) end
        return load()
    end
    get_mod = function(mod_name)
        return real_get_mod(mod_name == "BetterBrainer" and "NoBrainer" or mod_name)
    end
    local ok, result = pcall(mod.io_dofile_unsafe, mod, ROOT .. name)
    get_mod, mod.io_dofile = real_get_mod, previous
    if not ok then error(result, 0) end
    return result
end
