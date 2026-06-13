--!strict

local Theme = {}

function Theme.colors(Color3: any): any
	return {
		background = Color3.fromRGB(31, 34, 39),
		panel = Color3.fromRGB(41, 45, 52),
		panelAlt = Color3.fromRGB(50, 55, 63),
		text = Color3.fromRGB(235, 239, 244),
		muted = Color3.fromRGB(166, 173, 184),
		line = Color3.fromRGB(70, 76, 86),
		accent = Color3.fromRGB(72, 142, 255),
		error = Color3.fromRGB(255, 105, 97),
		warn = Color3.fromRGB(245, 192, 85),
		ok = Color3.fromRGB(102, 214, 163),
	}
end

function Theme.toneColor(colors: any, tone: any): any
	return colors[tone] or colors.text
end

return Theme
