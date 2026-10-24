local mod = get_mod("NoBrainer")
local import = mod:io_dofile("NoBrainer/scripts/mods/NoBrainer/import")

-- BetterBrainer's strings, already narrowed to the chosen language, plus NoBrainer's own.
local localizations = import("BetterBrainer_localization")

local own = {
    mod_name = { en = "No Brainer", ["zh-tw"] = "免動腦", ["zh-cn"] = "无脑操作", ru = "Быстрое решение" },
    mod_description = { en = "Automates and enhances all Darktide minigames: Decode Symbols, Decode Search, Auspex Scan, Train Balance, Tree Drill, and Frequency Matching.", ["zh-tw"] = "自動化並強化 Darktide 所有小遊戲：符號解碼、搜尋解碼、占卜儀掃描、列車平衡、樹狀鑽探與頻率配對。", ["zh-cn"] = "自动化并强化 Darktide 所有小游戏：符号解码、搜索解码、占卜仪扫描、列车平衡、树状钻探与频率配对。", ru = "No Brainer - Автоматизирует и улучшает все мини-игры Darktide: расшифровка символов, поиск, сканирование ауспексом, балансировка на поезде, бурение дерева и подбор частоты." },

    enable_decode_smart_reroll = { en = "Smart Seed Reroll", ["zh-tw"] = "智慧重抽種子", ["zh-cn"] = "智能重抽种子", ru = "Умный переброс по семени" },
    enable_decode_smart_reroll_tooltip = { en = "Rerolls with Reroll Slow Boards decide from the exact upcoming boards: each board follows from the terminal's seed, which is read on the host or rebuilt from the boards seen. A board is rerolled only when the known next boards are expected to be faster. Without a known seed, the average board is used as before.", ["zh-tw"] = "「重抽慢速盤面」的重抽改依實際的後續盤面決定：每個盤面都由終端的種子推得，主機直接讀取，其他情況則由已見盤面重建。只有在已知的後續盤面預計更快時才會重抽。無法得知種子時，仍照舊以平均盤面判斷。", ["zh-cn"] = "“重抽慢速盘面”的重抽改依实际的后续盘面决定：每个盘面都由终端的种子推得，主机直接读取，其他情况则由已见盘面重建。只有在已知的后续盘面预计更快时才会重抽。无法得知种子时，仍照旧以平均盘面判断。", ru = "Перебросы «Перебрасывать медленные поля» решаются по точным следующим полям: каждое поле следует из семени терминала, которое читается на хосте или восстанавливается по увиденным полям. Поле перебрасывается, только если известные следующие поля ожидаются быстрее. Без известного семени, как и раньше, используется среднее поле." },

    servo_skull_group = { en = "Servo Skull", ["zh-tw"] = "伺服顱骨", ["zh-cn"] = "伺服颅骨", ru = "Серво-череп" },
    enable_servo_skull_auto_hack = { en = "Auto-Start Hacking", ["zh-tw"] = "自動開始駭入", ["zh-cn"] = "自动开始骇入", ru = "Автозапуск взлома" },
    enable_servo_skull_auto_hack_tooltip = { en = "Automatically orders the Skitarius hacking servo skull to the nearest available minigame within the configured command range.", ["zh-tw"] = "在設定的指令範圍內，自動命令 Skitarius 的駭入伺服顱骨前往最近可用的小遊戲。", ["zh-cn"] = "在设定的指令范围内，自动命令 Skitarius 的骇入伺服颅骨前往最近可用的小游戏。", ru = "Автоматически отправляет взламывающий серво-череп скитария к ближайшей доступной мини-игре в пределах настроенной дальности команды." },
    servo_skull_require_line_of_sight = { en = "Require Line of Sight", ["zh-tw"] = "需要視線", ["zh-cn"] = "需要视线", ru = "Требовать прямую видимость" },
    servo_skull_require_line_of_sight_tooltip = { en = "When enabled, the minigame must be visible before the servo skull is ordered. Disable to allow orders through walls, floors, and ceilings.", ["zh-tw"] = "啟用時，必須能直接看見小遊戲才會對伺服顱骨下達指令。停用後可穿過牆壁、地板與天花板下達指令。", ["zh-cn"] = "启用时，必须能直接看见小游戏才会对伺服颅骨下达指令。禁用后可穿过墙壁、地板与天花板下达指令。", ru = "При включении мини-игра должна быть видна, прежде чем серво-череп получит команду. Отключите, чтобы разрешить команды сквозь стены, полы и потолки." },
    servo_skull_command_range = { en = "Command Range", ["zh-tw"] = "指令範圍", ["zh-cn"] = "指令范围", ru = "Дальность отправки" },
    servo_skull_command_range_tooltip = { en = "Maximum automatic command distance in metres. Defaults to the servo skull ability's normal 25-metre targeting range.", ["zh-tw"] = "自動下達指令的最大距離（公尺）。預設為伺服顱骨能力的一般 25 公尺鎖定範圍。", ["zh-cn"] = "自动下达指令的最大距离（米）。默认为伺服颅骨能力的一般 25 米锁定范围。", ru = "Максимальная автоматическая дальность команды в метрах. По умолчанию - обычная дальность прицеливания способности сервочерепа 25 метров." },
}

local language = mod:get("language")
for id, translations in pairs(own) do
    if language == "en" or language == "zh-tw" or language == "zh-cn" or language == "ru" then
        translations.en = translations[language] or translations.en
        translations["zh-tw"] = nil
        translations["zh-cn"] = nil
        translations.ru = nil
    end
    localizations[id] = translations
end

return localizations
