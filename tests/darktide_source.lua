-- Darktide's decompiled scripts for the offline tests, fetched on demand; the mod itself never needs them.
-- The first run clones the pinned commit into tests/.darktide-source (git-ignored), sparse and without other
-- blobs, and later runs add any further files a suite asks for. Set DARKTIDE_SOURCE to an existing checkout to
-- use it instead; it is then read as is, at whatever version it is.
local REPO = "https://github.com/Aussiemon/Darktide-Source-Code.git"
local COMMIT = "e46b8926cfa3fa35503e4b80b15aab7a804314e4" -- "Added Version 1.13.4 10-22-26"
local DIR = "tests/.darktide-source"

local M = {}

local function exists(path)
    local file = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil
end

local function git(args)
    local command = 'git -C "' .. DIR .. '" ' .. args
    assert(os.execute(command) == 0, "failed: " .. command)
end

-- Makes `files` (paths inside the source, such as "scripts/foundation/utilities/table.lua") available and
-- returns the source root, ending in "/".
function M.root(files)
    local override = os.getenv("DARKTIDE_SOURCE")
    local root = override and override:gsub("\\", "/"):gsub("/?$", "/") or DIR .. "/"
    local missing = {}
    for _, file in ipairs(files) do
        if not exists(root .. file) then missing[#missing + 1] = file end
    end
    if #missing == 0 then return root end
    assert(not override, "DARKTIDE_SOURCE lacks " .. table.concat(missing, ", "))
    local patterns = {}
    for i, file in ipairs(missing) do patterns[i] = '"/' .. file .. '"' end
    print("Fetching Darktide source " .. COMMIT:sub(1, 12) .. ": " .. table.concat(missing, ", "))
    if not exists(DIR .. "/.git/HEAD") then
        assert(os.execute('git init -q "' .. DIR .. '"') == 0, "git init failed")
        git("remote add origin " .. REPO)
        git("sparse-checkout set --no-cone " .. table.concat(patterns, " "))
        git("fetch -q --depth 1 --filter=blob:none origin " .. COMMIT)
        git("checkout -q " .. COMMIT)
    else
        -- A partial clone fetches the newly checked-out blobs from origin.
        git("sparse-checkout add " .. table.concat(patterns, " "))
    end
    for _, file in ipairs(missing) do assert(exists(root .. file), "not in the source: " .. file) end
    return root
end

-- The text of a source file, without its byte-order mark and with LF line ends.
function M.read(root, file)
    local handle = assert(io.open(root .. file, "rb"))
    local text = handle:read("*a"):gsub("^\239\187\191", ""):gsub("\r\n", "\n")
    handle:close()
    return text
end

return M
