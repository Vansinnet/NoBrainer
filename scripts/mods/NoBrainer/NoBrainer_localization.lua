---@class NoBrainerMod
local mod = get_mod("NoBrainer")

-- Traditional Chinese translation by SyuanTsai:
-- https://github.com/SyuanTsai/Warhammer-40-000-DARKTIDE-Mods
local localizations = {
	mod_name           = { en = "No Brainer", ["zh-tw"] = "免動腦", ["zh-cn"] = "无脑操作", ru = "Быстрое решение" },
	mod_description    = { en = "Automates and enhances all Darktide minigames: Decode Symbols, Decode Search, Auspex Scan, Train Balance, Tree Drill, and Frequency Matching.", ["zh-tw"] = "自動化並強化 Darktide 所有小遊戲：符號解碼、搜尋解碼、占卜儀掃描、列車平衡、樹狀鑽探與頻率配對。", ["zh-cn"] = "自动化并强化 Darktide 所有小游戏：符号解码、搜索解码、占卜仪扫描、列车平衡、树状钻探与频率配对。", ru = "No Brainer - Автоматизирует и улучшает все мини-игры Darktide: расшифровка символов, поиск, сканирование ауспексом, балансировка на поезде, бурение дерева и подбор частоты." },
	language           = { en = "Language", ["zh-tw"] = "語言", ["zh-cn"] = "语言", ru = "Язык" },
	language_tooltip   = { en = "Select Automatic to follow the game's language. Manual Traditional Chinese requires Darktide's language to also be set to Traditional Chinese so the game loads a font with Chinese characters. Otherwise, the text may appear as squares. Restart the game after changing this setting.", ["zh-tw"] = "選擇自動以跟隨遊戲語言。手動選擇繁體中文時，Darktide 的語言也必須設為繁體中文，遊戲才會載入支援中文字元的字型，否則文字可能顯示為方框。變更此設定後請重新啟動遊戲。", ["zh-cn"] = "选择自动以跟随游戏语言。手动选择简体中文时，Darktide 的语言也必须设为简体中文，游戏才会加载支持中文字符的字体，否则文字可能显示为方框。更改此设置后请重新启动游戏。", ru = "Выберите «Авто», чтобы следовать языку игры. Ручной выбор русского языка требует, чтобы в Darktide также был установлен русский язык, чтобы игра загрузила шрифт с кириллицей. В противном случае текст может отображаться квадратами. После изменения настройки перезапустите игру." },
	language_auto      = { en = "Automatic (Game Language)", ["zh-tw"] = "自動（遊戲語言）", ["zh-cn"] = "自动（游戏语言）", ru = "Авто (язык игры)" },
	language_en        = { en = "English", ["zh-tw"] = "English", ["zh-cn"] = "英语", ru = "Английский" },
	language_zh_cn     = { en = "Simplified Chinese", ["zh-tw"] = "簡體中文", ["zh-cn"] = "简体中文", ru = "Упрощённый китайский" },
	language_zh_tw     = { en = "Traditional Chinese", ["zh-tw"] = "繁體中文", ["zh-cn"] = "繁体中文", ru = "Традиционный китайский" },
	language_ru        = { en = "Russian", ["zh-tw"] = "俄語", ["zh-cn"] = "俄语", ru = "Русский" },
	servo_skull_group = { en = "Servo Skull", ["zh-tw"] = "伺服顱骨", ["zh-cn"] = "伺服颅骨", ru = "Серво-череп" },
	enable_servo_skull_auto_hack = { en = "Auto-Start Hacking", ["zh-tw"] = "自動開始駭入", ["zh-cn"] = "自动开始骇入", ru = "Автозапуск взлома" },
	enable_servo_skull_auto_hack_tooltip = { en = "Automatically orders the Skitarius hacking servo skull to the nearest available minigame within the configured command range.", ["zh-tw"] = "在設定的指令範圍內，自動命令 Skitarius 的駭入伺服顱骨前往最近可用的小遊戲。", ["zh-cn"] = "在设定的指令范围内，自动命令 Skitarius 的骇入伺服颅骨前往最近可用的小游戏。", ru = "Автоматически отправляет взламывающий серво-череп скитария к ближайшей доступной мини-игре в пределах настроенной дальности команды." },
	servo_skull_require_line_of_sight = { en = "Require Line of Sight", ["zh-tw"] = "需要視線", ["zh-cn"] = "需要视线", ru = "Требовать прямую видимость" },
	servo_skull_require_line_of_sight_tooltip = { en = "When enabled, the minigame must be visible before the servo skull is ordered. Disable to allow orders through walls, floors, and ceilings.", ["zh-tw"] = "啟用時，必須能直接看見小遊戲才會對伺服顱骨下達指令。停用後可穿過牆壁、地板與天花板下達指令。", ["zh-cn"] = "启用时，必须能直接看见小游戏才会对伺服颅骨下达指令。禁用后可穿过墙壁、地板与天花板下达指令。", ru = "При включении мини-игра должна быть видна, прежде чем серво-череп получит команду. Отключите, чтобы разрешить команды сквозь стены, полы и потолки." },
	servo_skull_command_range = { en = "Command Range", ["zh-tw"] = "指令範圍", ["zh-cn"] = "指令范围", ru = "Дальность отправки" },
	servo_skull_command_range_tooltip = { en = "Maximum automatic command distance in metres. Defaults to the servo skull ability's normal 25-metre targeting range.", ["zh-tw"] = "自動下達指令的最大距離（公尺）。預設為伺服顱骨能力的一般 25 公尺鎖定範圍。", ["zh-cn"] = "自动下达指令的最大距离（米）。默认为伺服颅骨能力的一般 25 米锁定范围。", ru = "Максимальная автоматическая дальность команды в метрах. По умолчанию - обычная дальность прицеливания способности сервочерепа 25 метров." },

	decode_symbols_group      = { en = "Decode Symbols", ["zh-tw"] = "符號解碼", ["zh-cn"] = "符号解码", ru = "Расшифровка символов" },
	enable_decode_highlight   = { en = "Highlight Solution", ["zh-tw"] = "標示解答", ["zh-cn"] = "标示解答", ru = "Подсветка решения" },
	enable_decode_highlight_tooltip = { en = "Highlights the correct columns for upcoming rows.", ["zh-tw"] = "標示接下來列的正確欄位。", ["zh-cn"] = "标示接下来列的正确栏位。", ru = "Подсвечивает правильные столбцы для предстоящих строк." },
	enable_decode_auto        = { en = "Auto-Solve", ["zh-tw"] = "自動解題", ["zh-cn"] = "自动解题", ru = "Авторешение" },
	enable_decode_auto_tooltip = { en = "Automatically presses interact when the cursor is on target.", ["zh-tw"] = "游標位於目標上時自動按下互動鍵。", ["zh-cn"] = "光标位于目标上时自动按下互动键。", ru = "Автоматически нажимает взаимодействие, когда курсор находится на цели." },
	enable_decode_smart_reroll = { en = "Smart Seed Reroll", ["zh-tw"] = "智慧重抽種子", ["zh-cn"] = "智能重抽种子", ru = "Умное семя перебоса" },
	enable_decode_smart_reroll_tooltip = { en = "With Auto-Solve enabled, cancels and retries up to two slow Decode Symbols layouts when expected to save at least 0.5 seconds. The Auspex may visibly close and reopen up to twice; this is intentional. Verified seed prediction saves about 0.65-0.72 seconds (11-13%%) on average in simulation, with a statistical estimate used when unavailable.", ["zh-tw"] = "啟用自動解題時，若預期可節省至少 0.5 秒，會自動取消並重試最多兩次較慢的符號解碼配置。占卜儀在畫面上可能會關閉並重新開啟最多兩次，這是正常現象。經驗證的種子預測在模擬中平均節省約 0.65-0.72 秒（11-13%%）；無法使用時則採用統計估算。", ["zh-cn"] = "启用自动解题时，若预期可节省至少 0.5 秒，会自动取消并重试最多两次较慢的符号解码配置。占卜仪在画面上可能会关闭并重新开启最多两次，这是正常现象。经验证的种子预测在模拟中平均节省约 0.65-0.72 秒（11-13%%）；无法使用时则采用统计估算。", ru = "При включенном режиме авторешения отменяется и повторяется до двух медленных вариантов раскладки символов декодирования, что позволяет сэкономить не менее 0,5 секунды. Ауспекс может визуально закрываться и открываться до двух раз; это сделано намеренно. Проверенное предсказание начального значения в среднем экономит около 0,65-0,72 секунды (11-13%%) в симуляции, при этом используется статистическая оценка, если она недоступна." },

	matching_group            = { en = "Decode Search (Matching)", ["zh-tw"] = "搜尋解碼（配對）", ["zh-cn"] = "搜索解码（配对）", ru = "Поиск (сопоставление)" },
	enable_matching              = { en = "Highlight Match", ["zh-tw"] = "標示配對", ["zh-cn"] = "标示配对", ru = "Подсветка совпадения" },
	enable_matching_tooltip      = { en = "Highlights the region on the board that matches the target pattern.", ["zh-tw"] = "標示面板上符合目標圖案的區域。", ["zh-cn"] = "标示面板上符合目标图案的区域。", ru = "Подсвечивает область на панели, соответствующую целевому шаблону." },
	enable_expedition_auto_solve       = { en = "Auto-Solve", ["zh-tw"] = "自動解題", ["zh-cn"] = "自动解题", ru = "Авторешение" },
	enable_expedition_auto_solve_tooltip = { en = "Automatically moves the cursor to the target and submits.", ["zh-tw"] = "自動將游標移至目標並提交。", ["zh-cn"] = "自动将光标移至目标并提交。", ru = "Автоматически перемещает курсор к цели и подтверждает." },
	expedition_solve_speed             = { en = "Auto-Solve Speed", ["zh-tw"] = "自動解題速度", ["zh-cn"] = "自动解题速度", ru = "Скорость авторешения" },
	expedition_solve_speed_tooltip     = { en = "Auto-solve pace (1=moderate, 5=fastest). Every speed uses the same precise solver and diagonal movement.", ["zh-tw"] = "自動解題速度（1＝適中，5＝最快）。所有速度都使用相同的精準解題器與對角移動。", ["zh-cn"] = "自动解题速度（1＝适中，5＝最快）。所有速度都使用相同的精准解题器与对角移动。", ru = "Темп авторешения (1=умеренный, 5=самый быстрый). Все скорости используют один и тот же точный решатель и диагональное движение." },

	scan_group                = { en = "Auspex Scan", ["zh-tw"] = "占卜儀掃描", ["zh-cn"] = "占卜仪扫描", ru = "Сканирование ауспексом" },
	enable_scan               = { en = "Mark Scannable Objects", ["zh-tw"] = "標記可掃描物件", ["zh-cn"] = "标记可扫描物件", ru = "Отмечать сканируемые объекты" },
	enable_scan_tooltip       = { en = "Applies outline and highlight to scannable objects during auspex scanning.", ["zh-tw"] = "使用占卜儀掃描時，為可掃描物件套用輪廓與標示。", ["zh-cn"] = "使用占卜仪扫描时，为可扫描物件套用轮廓与标示。", ru = "Показывает контур и подсветку на сканируемых объектах во время сканирования ауспексом." },
	enable_auto_scan          = { en = "Auto-Scan", ["zh-tw"] = "自動掃描", ["zh-cn"] = "自动扫描", ru = "Автосканирование" },
	enable_auto_scan_tooltip  = { en = "Automatically holds the scan action until completion when an active target is in range and line of sight.", ["zh-tw"] = "當啟用中的掃描目標進入範圍且位於視線內時，自動按住掃描動作直到完成。", ["zh-cn"] = "当启用中的扫描目标进入范围且位于视线内时，自动按住扫描动作直到完成。", ru = "Автоматически удерживает сканирование до завершения, когда активная цель находится в пределах досягаемости и прямой видимости." },

	balance_group             = { en = "Train (Balance)", ["zh-tw"] = "列車（平衡）", ["zh-cn"] = "列车（平衡）", ru = "Поезд (баланс)" },
	enable_balance            = { en = "Auto-Balance", ["zh-tw"] = "自動平衡", ["zh-cn"] = "自动平衡", ru = "Автобалансировка" },
	enable_balance_tooltip    = { en = "Automatically steers the dot toward the center.", ["zh-tw"] = "自動將圓點導向中央。", ["zh-cn"] = "自动将圆点导向中央。", ru = "Автоматически направляет точку к центру." },

	frequency_group                       = { en = "Frequency Matching", ["zh-tw"] = "頻率配對", ["zh-cn"] = "频率配对", ru = "Подбор частоты" },
	enable_frequency_highlight            = { en = "Show Directional Arrows", ["zh-tw"] = "顯示方向箭頭", ["zh-cn"] = "显示方向箭头", ru = "Показывать направляющие стрелки" },
	enable_frequency_highlight_tooltip    = { en = "Displays orange arrows indicating which direction to push the waveform toward the target.", ["zh-tw"] = "顯示橘色箭頭，指示應將波形往哪個方向推向目標。", ["zh-cn"] = "显示橙色箭头，指示应将波形往哪个方向推向目标。", ru = "Отображает оранжевые стрелки, указывающие, в каком направлении подводить сигнал к цели." },
	enable_frequency_auto                 = { en = "Auto-Solve", ["zh-tw"] = "自動解題", ["zh-cn"] = "自动解题", ru = "Авторешение" },
	enable_frequency_auto_tooltip         = { en = "Automatically steers the waveform toward the target and submits when aligned.", ["zh-tw"] = "自動將波形導向目標，對齊後提交。", ["zh-cn"] = "自动将波形导向目标，对齐后提交。", ru = "Автоматически направляет сигнал к цели и подтверждает при совпадении." },
	frequency_solve_speed                 = { en = "Auto-Solve Speed", ["zh-tw"] = "自動解題速度", ["zh-cn"] = "自动解题速度", ru = "Скорость авторешения" },
	frequency_solve_speed_tooltip         = { en = "Auto-solve pace (1=normal manual pace, 5=fastest). Every speed uses the same precise deterministic steering.", ["zh-tw"] = "自動解題速度（1＝一般手動速度，5＝最快）。所有速度都使用相同的精準固定導引。", ["zh-cn"] = "自动解题速度（1＝一般手动速度，5＝最快）。所有速度都使用相同的精准固定导引。", ru = "Темп авторешения (1=обычный ручной темп, 5=самый быстрый). Все скорости используют один и тот же точный детерминированный алгоритм." },

	drill_group               = { en = "Tree (Drill)", ["zh-tw"] = "樹狀圖（鑽探）", ["zh-cn"] = "树状图（钻探）", ru = "Дерево (бурение)" },
	enable_drill              = { en = "Highlight Correct Target", ["zh-tw"] = "標示正確目標", ["zh-cn"] = "标示正确目标", ru = "Подсветка правильной цели" },
	enable_drill_tooltip      = { en = "Shows which node is the correct one by highlighting it white.", ["zh-tw"] = "將正確節點標示為白色。", ["zh-cn"] = "将正确节点标示为白色。", ru = "Показывает, какой узел правильный, подсвечивая его белым." },
	enable_drill_auto         = { en = "Auto-Solve", ["zh-tw"] = "自動解題", ["zh-cn"] = "自动解题", ru = "Авторешение" },
	enable_drill_auto_tooltip = { en = "Automatically moves to the correct node and submits.", ["zh-tw"] = "自動移至正確節點並提交。", ["zh-cn"] = "自动移至正确节点并提交。", ru = "Автоматически переходит к правильному узлу и подтверждает." },
	drill_solve_speed         = { en = "Auto-Solve Speed", ["zh-tw"] = "自動解題速度", ["zh-cn"] = "自动解题速度", ru = "Скорость авторешения" },
	drill_solve_speed_tooltip = { en = "Auto-solve pace (1=normal manual pace, 5=fastest). Every speed uses the same precise solver.", ["zh-tw"] = "自動解題速度（1＝一般手動速度，5＝最快）。所有速度都使用相同的精準解題器。", ["zh-cn"] = "自动解题速度（1＝一般手动速度，5＝最快）。所有速度都使用相同的精准解题器。", ru = "Темп авторешения (1=обычный ручной темп, 5=самый быстрый). Все скорости используют один и тот же точный решатель." },

}

local language = mod:get("language")
if language == "en" or language == "zh-tw" or language == "zh-cn" or language == "ru" then
	for _, translations in pairs(localizations) do
		translations.en = translations[language] or translations.en
		translations["zh-tw"] = nil
		translations["zh-cn"] = nil
		translations.ru = nil
	end
end

return localizations
