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

local CONTENT_SIZE = UDim2.new(1, 0, 1, -152)
local CONTENT_SIZE_WITH_LIVE = UDim2.new(1, 0, 1, -388)
local LIVE_SECTION_HEIGHT = 228
local LIVE_MAX_ROWS = 100

local content = Instance.new("ScrollingFrame")
content.Name = "Content"
content.Size = CONTENT_SIZE
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
			child:Destroy() -- contracts-scan: ignore unowned-destroy
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

local liveSection = Instance.new("Frame")
liveSection.Name = "LiveSection"
liveSection.Size = UDim2.new(1, 0, 0, LIVE_SECTION_HEIGHT)
liveSection.BackgroundColor3 = COLORS.panel
liveSection.BorderSizePixel = 0
liveSection.LayoutOrder = 4
liveSection.Visible = false
liveSection.Parent = root

local liveHeader = Instance.new("Frame")
liveHeader.Name = "LiveHeader"
liveHeader.Size = UDim2.new(1, -16, 0, 34)
liveHeader.Position = UDim2.new(0, 8, 0, 4)
liveHeader.BackgroundTransparency = 1
liveHeader.Parent = liveSection

local liveTitle = makeLabel(liveHeader, "Live Diagnostics", 34, COLORS.text, true)
liveTitle.Size = UDim2.new(1, -160, 1, 0)

local function makeLiveButton(text, offset)
	local liveButton = Instance.new("TextButton")
	liveButton.AnchorPoint = Vector2.new(1, 0.5)
	liveButton.Position = UDim2.new(1, offset, 0.5, 0)
	liveButton.Size = UDim2.new(0, 64, 0, 26)
	liveButton.BackgroundColor3 = COLORS.panelAlt
	liveButton.BorderSizePixel = 0
	liveButton.Font = Enum.Font.GothamBold
	liveButton.TextSize = 12
	liveButton.TextColor3 = COLORS.text
	liveButton.Text = text
	liveButton.Parent = liveHeader
	return liveButton
end

local pauseButton = makeLiveButton("Pause", -72)
local clearButton = makeLiveButton("Clear", 0)

local liveList = Instance.new("ScrollingFrame")
liveList.Name = "LiveList"
liveList.Size = UDim2.new(1, -16, 1, -46)
liveList.Position = UDim2.new(0, 8, 0, 40)
liveList.BackgroundColor3 = COLORS.panelAlt
liveList.BorderSizePixel = 0
liveList.CanvasSize = UDim2.new()
liveList.AutomaticCanvasSize = Enum.AutomaticSize.Y
liveList.ScrollBarThickness = 6
liveList.Parent = liveSection

local liveListLayout = Instance.new("UIListLayout")
liveListLayout.FillDirection = Enum.FillDirection.Vertical
liveListLayout.SortOrder = Enum.SortOrder.LayoutOrder
liveListLayout.Padding = UDim.new(0, 2)
liveListLayout.Parent = liveList

local liveListPadding = Instance.new("UIPadding")
liveListPadding.PaddingTop = UDim.new(0, 6)
liveListPadding.PaddingRight = UDim.new(0, 6)
liveListPadding.PaddingBottom = UDim.new(0, 6)
liveListPadding.PaddingLeft = UDim.new(0, 6)
liveListPadding.Parent = liveList

local liveState = {
	rows = {},
	paused = false,
	seenSeq = {},
	attachedFolder = nil,
}

local function renderLive()
	clear(liveList)
	if #liveState.rows == 0 then
		makeLabel(liveList, "Waiting for diagnostics...", 20, COLORS.muted, false)
		return
	end

	for index, row in ipairs(liveState.rows) do
		local label = makeLabel(liveList, row.text, 20, toneColor(row.tone), false)
		label.LayoutOrder = index
		label.TextSize = 12
	end

	liveList.CanvasPosition = Vector2.new(0, math.max(0, liveList.AbsoluteCanvasSize.Y))
end

local function showLiveSection()
	if not liveSection.Visible then
		liveSection.Visible = true
		content.Size = CONTENT_SIZE_WITH_LIVE
		renderLive()
	end
end

local function onBatchValue(child)
	if liveState.paused then
		return
	end
	if not child:IsA("StringValue") then
		return
	end

	local ok, decoded = pcall(function()
		return game:GetService("HttpService"):JSONDecode(child.Value)
	end)
	if not ok then
		return
	end

	local batch = PluginModel.batchFromDecoded(decoded)
	if batch == nil or liveState.seenSeq[batch.seq] then
		return
	end
	liveState.seenSeq[batch.seq] = true

	PluginModel.appendLive(liveState.rows, PluginModel.liveRows(batch), LIVE_MAX_ROWS)
	renderLive()
end

local function attachLiveFolder(folder)
	if liveState.attachedFolder == folder then
		return
	end
	liveState.attachedFolder = folder
	liveState.seenSeq = {}
	showLiveSection()

	for _, child in ipairs(folder:GetChildren()) do
		onBatchValue(child)
	end
	folder.ChildAdded:Connect(onBatchValue)
end

local function watchForLiveFolder()
	local replicatedStorage = game:GetService("ReplicatedStorage")
	local existing = replicatedStorage:FindFirstChild("__LuauContractDiagnostics")
	if existing then
		attachLiveFolder(existing)
	end

	replicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == "__LuauContractDiagnostics" then
			attachLiveFolder(child)
		end
	end)
end

pauseButton.Activated:Connect(function()
	liveState.paused = not liveState.paused
	pauseButton.Text = liveState.paused and "Resume" or "Pause"
	pauseButton.BackgroundColor3 = liveState.paused and COLORS.accent or COLORS.panelAlt
end)

clearButton.Activated:Connect(function()
	liveState.rows = {}
	renderLive()
end)

watchForLiveFolder()

scanButton.Activated:Connect(scan)
button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	if widget.Enabled then
		scan()
	end
end)

render(StudioReport.fromScripts({}))
