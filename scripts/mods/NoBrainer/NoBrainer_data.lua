---@class NoBrainerMod
local mod = get_mod("NoBrainer")

return {
	name        = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable    = true,
	allow_rehooking = true,
	options = {
		widgets = {
			{
				setting_id    = "language",
				type          = "dropdown",
				default_value = "auto",
				require_restart = true,
				tooltip       = "language_tooltip",
				options       = {
					{ text = "language_auto",  value = "auto" },
					{ text = "language_en",    value = "en" },
					{ text = "language_zh_cn", value = "zh-cn" },
					{ text = "language_zh_tw", value = "zh-tw" },
					{ text = "language_ru",    value = "ru" },
				},
			},
			{
				setting_id  = "servo_skull_group",
				type        = "group",
				title       = "servo_skull_group",
				sub_widgets = {
					{
						setting_id    = "enable_servo_skull_auto_hack",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_servo_skull_auto_hack_tooltip",
					},
					{
						setting_id    = "servo_skull_require_line_of_sight",
						type          = "checkbox",
						default_value = true,
						tooltip       = "servo_skull_require_line_of_sight_tooltip",
					},
					{
						setting_id      = "servo_skull_command_range",
						type            = "numeric",
						default_value   = 25,
						range           = { 5, 100 },
						decimals_number = 0,
						tooltip         = "servo_skull_command_range_tooltip",
					},
				},
			},

			{
				setting_id  = "decode_symbols_group",
				type        = "group",
				title       = "decode_symbols_group",
				sub_widgets = {
					{
						setting_id    = "enable_decode_highlight",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_decode_highlight_tooltip",
					},
					{
						setting_id    = "enable_decode_auto",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_decode_auto_tooltip",
					},
					{
						setting_id    = "enable_decode_smart_reroll",
						type          = "checkbox",
						default_value = false,
						tooltip       = "enable_decode_smart_reroll_tooltip",
					},
				},
			},
			{
				setting_id  = "matching_group",
				type        = "group",
				title       = "matching_group",
				sub_widgets = {
					{
						setting_id    = "enable_matching",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_matching_tooltip",
					},
					{
						setting_id    = "enable_expedition_auto_solve",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_expedition_auto_solve_tooltip",
					},
					{
						setting_id    = "expedition_solve_speed",
						type          = "numeric",
						default_value = 1,
						range         = { 1, 5 },
						decimals_number = 0,
						tooltip       = "expedition_solve_speed_tooltip",
					},
				},
			},

			{
				setting_id  = "scan_group",
				type        = "group",
				title       = "scan_group",
				sub_widgets = {
					{
						setting_id    = "enable_scan",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_scan_tooltip",
					},
					{
						setting_id    = "enable_auto_scan",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_auto_scan_tooltip",
					},
				},
			},

			{
				setting_id  = "balance_group",
				type        = "group",
				title       = "balance_group",
				sub_widgets = {
					{
						setting_id    = "enable_balance",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_balance_tooltip",
					},
				},
			},

			{
				setting_id  = "drill_group",
				type        = "group",
				title       = "drill_group",
				sub_widgets = {
					{
						setting_id    = "enable_drill",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_drill_tooltip",
					},
					{
						setting_id    = "enable_drill_auto",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_drill_auto_tooltip",
					},
					{
						setting_id    = "drill_solve_speed",
						type          = "numeric",
						default_value = 1,
						range         = { 1, 5 },
						decimals_number = 0,
						tooltip       = "drill_solve_speed_tooltip",
					},

				},
			},

			{
				setting_id  = "frequency_group",
				type        = "group",
				title       = "frequency_group",
				sub_widgets = {
					{
						setting_id    = "enable_frequency_highlight",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_frequency_highlight_tooltip",
					},
					{
						setting_id    = "enable_frequency_auto",
						type          = "checkbox",
						default_value = true,
						tooltip       = "enable_frequency_auto_tooltip",
					},
					{
						setting_id    = "frequency_solve_speed",
						type          = "numeric",
						default_value = 1,
						range         = { 1, 5 },
						decimals_number = 0,
						tooltip       = "frequency_solve_speed_tooltip",
					},
				},
			},

		},
	},
}
