--!nocheck
--!nolint UnknownGlobal

local function findSdkRoot()
	return script.Parent:FindFirstChild("LuauContractSDK") or script.Parent:FindFirstChild("src")
end

local Contracts = require(assert(findSdkRoot(), "Luau Contract SDK module tree must be next to the plugin script"))
local PluginModel = require(
	assert(
		script.Parent:FindFirstChild("LuauContractPluginModel"),
		"Luau Contract plugin model must be next to the plugin script"
	)
)
local PluginView = require(
	assert(
		script.Parent:FindFirstChild("LuauContractStudioPluginView"),
		"Luau Contract plugin view must be next to the plugin script"
	)
)

PluginView.mount({
	plugin = plugin,
	game = game,
	Instance = Instance,
	Color3 = Color3,
	UDim2 = UDim2,
	UDim = UDim,
	Vector2 = Vector2,
	Enum = Enum,
	DockWidgetPluginGuiInfo = DockWidgetPluginGuiInfo,
}, Contracts, PluginModel)
