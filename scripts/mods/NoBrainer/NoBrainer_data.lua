local mod = get_mod("NoBrainer")
local import = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/import")

-- BetterBrainer's options (its name and description come from NoBrainer's localization), plus NoBrainer's own.
local data = import("BetterBrainer_data")
local widgets = data.options.widgets

local function checkbox(id, default)
    return {
        setting_id = id,
        type = "checkbox",
        default_value = default,
        tooltip = id .. "_tooltip",
    }
end

local function numeric(id, default, minimum, maximum)
    return {
        setting_id = id,
        type = "numeric",
        default_value = default,
        range = { minimum, maximum },
        decimals_number = 0,
        tooltip = id .. "_tooltip",
    }
end

local function find(list, id)
    for i = 1, #list do
        if list[i].setting_id == id then return list[i], i end
    end
    error("BetterBrainer option missing: " .. id)
end

local symbols = find(widgets, "decode_symbols_group").sub_widgets
local _, reroll = find(symbols, "decode_reroll_limit")
table.insert(symbols, reroll + 1, checkbox("enable_decode_smart_reroll", true))

local _, language = find(widgets, "language")
table.insert(widgets, language + 1, {
    setting_id = "servo_skull_group",
    type = "group",
    title = "servo_skull_group",
    sub_widgets = {
        checkbox("enable_servo_skull_auto_hack", true),
        checkbox("servo_skull_require_line_of_sight", true),
        numeric("servo_skull_command_range", 25, 5, 100),
    },
})

return data
