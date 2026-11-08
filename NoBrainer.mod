return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`NoBrainer` failed loading DMF.")
        new_mod("NoBrainer", {
            mod_script = "NoBrainer/scripts/mods/NoBrainer/NoBrainer",
            mod_data = "NoBrainer/scripts/mods/NoBrainer/NoBrainer_data",
            mod_localization = "NoBrainer/scripts/mods/NoBrainer/NoBrainer_localization",
        })
    end,
    packages = {},
}
