--!nocheck
--!nolint UnknownGlobal

local function findSdkRoot()
	return script.Parent:FindFirstChild("LuauContractSDK") or script.Parent:FindFirstChild("src")
end

local Contracts = require(assert(findSdkRoot(), "Luau Contract SDK module tree must be next to the plugin script"))
local PluginModel = require(assert(script.Parent:FindFirstChild("LuauContractPluginModel"), "Luau Contract plugin model must be next to the plugin script"))
local StudioReport = Contracts.Studio.StudioReport

local COLORS = {
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

local function toneColor(tone)
	return COLORS[tone] or COLORS.text
end

local toolbar = plugin:CreateToolbar("Luau Contracts")
local button = toolbar:CreateButton("Contracts", "Open Luau Contracts", "")
button.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,
	false,
	460,
	620,
	340,
	360
)

local widget = plugin:CreateDockWidgetPluginGuiAsync("LuauContractSDKPanel", widgetInfo)
widget.Title = "Luau Contracts"

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = COLORS.background
root.BorderSizePixel = 0
root.Parent = widget

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)
layout.Parent = root

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingRight = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 10)
padding.Parent = root

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 42)
header.BackgroundTransparency = 1
header.LayoutOrder = 1
header.Parent = root

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -120, 1, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.text
title.Text = "Luau Contracts"
title.Parent = header

local scanButton = Instance.new("TextButton")
scanButton.Name = "ScanButton"
scanButton.AnchorPoint = Vector2.new(1, 0.5)
scanButton.Position = UDim2.new(1, 0, 0.5, 0)
scanButton.Size = UDim2.new(0, 106, 0, 32)
scanButton.BackgroundColor3 = COLORS.accent
scanButton.BorderSizePixel = 0
scanButton.Font = Enum.Font.GothamBold
scanButton.TextSize = 13
scanButton.TextColor3 = Color3.fromRGB(255, 255, 255)
scanButton.Text = "Scan"
scanButton.Parent = header

local summary = Instance.new("Frame")
summary.Name = "Summary"
summary.Size = UDim2.new(1, 0, 0, 92)
summary.BackgroundColor3 = COLORS.panel
summary.BorderSizePixel = 0
summary.LayoutOrder = 2
summary.Parent = root

local summaryGrid = Instance.new("UIGridLayout")
summaryGrid.CellSize = UDim2.new(0.5, -6, 0, 38)
summaryGrid.CellPadding = UDim2.new(0, 8, 0, 8)
summaryGrid.SortOrder = Enum.SortOrder.LayoutOrder
summaryGrid.Parent = summary

local summaryPadding = Instance.new("UIPadding")
summaryPadding.PaddingTop = UDim.new(0, 8)
summaryPadding.PaddingRight = UDim.new(0, 8)
summaryPadding.PaddingBottom = UDim.new(0, 8)
summaryPadding.PaddingLeft = UDim.new(0, 8)
summaryPadding.Parent = summary

local content = Instance.new("ScrollingFrame")
content.Name = "Content"
content.Size = UDim2.new(1, 0, 1, -152)
content.BackgroundColor3 = COLORS.panel
content.BorderSizePixel = 0
content.LayoutOrder = 3
content.CanvasSize = UDim2.new()
content.AutomaticCanvasSize = Enum.AutomaticSize.Y
content.ScrollBarThickness = 8
content.Parent = root

local contentLayout = Instance.new("UIListLayout")
contentLayout.FillDirection = Enum.FillDirection.Vertical
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Padding = UDim.new(0, 8)
contentLayout.Parent = content

local contentPadding = Instance.new("UIPadding")
contentPadding.PaddingTop = UDim.new(0, 8)
contentPadding.PaddingRight = UDim.new(0, 8)
contentPadding.PaddingBottom = UDim.new(0, 8)
contentPadding.PaddingLeft = UDim.new(0, 8)
contentPadding.Parent = content

local function clear(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function makeLabel(parent, text, height, color, bold)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, height or 22)
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = bold and 14 or 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextColor3 = color or COLORS.text
	label.TextWrapped = true
	label.Text = text
	label.Parent = parent
	return label
end

local function makeSummaryCard(label, value, color)
	local card = Instance.new("Frame")
	card.BackgroundColor3 = COLORS.panelAlt
	card.BorderSizePixel = 0
	card.Parent = summary

	makeLabel(card, label, 14, COLORS.muted, false).Position = UDim2.new(0, 8, 0, 5)
	local valueLabel = makeLabel(card, tostring(value), 20, color or COLORS.text, true)
	valueLabel.Position = UDim2.new(0, 8, 0, 18)
	return card
end

local function makeSection(titleText)
	local section = Instance.new("Frame")
	section.BackgroundColor3 = COLORS.panelAlt
	section.BorderSizePixel = 0
	section.Size = UDim2.new(1, 0, 0, 28)
	section.AutomaticSize = Enum.AutomaticSize.Y
	section.Parent = content

	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Vertical
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 5)
	list.Parent = section

	local sectionPadding = Instance.new("UIPadding")
	sectionPadding.PaddingTop = UDim.new(0, 8)
	sectionPadding.PaddingRight = UDim.new(0, 8)
	sectionPadding.PaddingBottom = UDim.new(0, 8)
	sectionPadding.PaddingLeft = UDim.new(0, 8)
	sectionPadding.Parent = section

	makeLabel(section, titleText, 22, COLORS.text, true)
	return section
end

local function collectScripts()
	return PluginModel.collectScripts(game)
end

local function renderSummary(report)
	clear(summary)
	for _, card in ipairs(PluginModel.summaryCards(report)) do
		makeSummaryCard(card.label, card.value, toneColor(card.tone))
	end
end

local function renderSystems(report)
	local section = makeSection("Systems")
	if #report.systems == 0 then
		makeLabel(section, "No contract systems found.", 22, COLORS.muted, false)
		return
	end

	for _, row in ipairs(PluginModel.systemRows(report, StudioReport.formatSystem)) do
		makeLabel(section, row.summary, 24, COLORS.text, false)
		makeLabel(section, row.path, 20, COLORS.muted, false)
	end
end

local function renderFindings(report)
	local section = makeSection("Static Findings")
	if #report.scanner.findings == 0 then
		makeLabel(section, "No static findings.", 22, COLORS.ok, false)
		return
	end

	for _, row in ipairs(PluginModel.findingRows(report)) do
		makeLabel(section, row.title, 28, toneColor(row.tone), true)
		makeLabel(section, row.message, 34, COLORS.text, false)
	end
end

local function renderDiagnostics(report)
	local section = makeSection("Recent Diagnostics")
	if #report.diagnostics == 0 then
		makeLabel(section, "No diagnostics report attached.", 22, COLORS.muted, false)
		return
	end

	for _, row in ipairs(PluginModel.diagnosticRows(report, StudioReport.formatDiagnostic)) do
		makeLabel(section, row.text, 28, COLORS.text, false)
	end
end

local function render(report)
	renderSummary(report)
	clear(content)
	renderSystems(report)
	renderFindings(report)
	renderDiagnostics(report)
end

local function scan()
	scanButton.Text = "Scanning..."
	local scripts = collectScripts()
	local report = StudioReport.fromScripts(scripts)
	render(report)
	scanButton.Text = "Scan"
end

scanButton.Activated:Connect(scan)
button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	if widget.Enabled then
		scan()
	end
end)

render(StudioReport.fromScripts({}))
