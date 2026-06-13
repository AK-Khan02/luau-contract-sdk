--!strict

local OverlayFeed = require("../Core/OverlayFeed")

local OverlayState = {}

function OverlayState.bind(diagnostics: any, config: any): any
	local feed = OverlayFeed.new(diagnostics, config)

	return {
		rows = function()
			return feed:rows()
		end,
		latest = function()
			return feed:latest()
		end,
		text = function()
			return feed:text()
		end,
		clear = function()
			feed:clear()
		end,
		destroy = function()
			feed:destroy()
		end,
	}
end

return OverlayState
