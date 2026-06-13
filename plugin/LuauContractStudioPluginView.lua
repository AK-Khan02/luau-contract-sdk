--!strict

local Live = require("./LuauContractStudioPluginLive")
local Theme = require("./LuauContractStudioPluginTheme")
local Widgets = require("./LuauContractStudioPluginWidgets")

local PluginView = {}

local function addPadding(platform: any, parent: any, all: number)
	local padding = platform.Instance.new("UIPadding")
	padding.PaddingTop = platform.UDim.new(0, all)
	padding.PaddingRight = platform.UDim.new(0, all)
	padding.PaddingBottom = platform.UDim.new(0, all)
	padding.PaddingLeft = platform.UDim.new(0, all)
	padding.Parent = parent
	return padding
end

local function addVerticalList(platform: any, parent: any, paddingPixels: number)
	local layout = platform.Instance.new("UIListLayout")
	layout.FillDirection = platform.Enum.FillDirection.Vertical
	layout.SortOrder = platform.Enum.SortOrder.LayoutOrder
	layout.Padding = platform.UDim.new(0, paddingPixels)
	layout.Parent = parent
	return layout
end

local function createMainPanel(platform: any, colors: any, widget: any): any
	local Instance = platform.Instance
	local UDim2 = platform.UDim2
	local Vector2 = platform.Vector2
	local Enum = platform.Enum

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = colors.background
	root.BorderSizePixel = 0
	root.Parent = widget

	addVerticalList(platform, root, 8)
	addPadding(platform, root, 10)

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
	title.TextColor3 = colors.text
	title.Text = "Luau Contracts"
	title.Parent = header

	local scanButton = Instance.new("TextButton")
	scanButton.Name = "ScanButton"
	scanButton.AnchorPoint = Vector2.new(1, 0.5)
	scanButton.Position = UDim2.new(1, 0, 0.5, 0)
	scanButton.Size = UDim2.new(0, 106, 0, 32)
	scanButton.BackgroundColor3 = colors.accent
	scanButton.BorderSizePixel = 0
	scanButton.Font = Enum.Font.GothamBold
	scanButton.TextSize = 13
	scanButton.TextColor3 = platform.Color3.fromRGB(255, 255, 255)
	scanButton.Text = "Scan"
	scanButton.Parent = header

	local summary = Instance.new("Frame")
	summary.Name = "Summary"
	summary.Size = UDim2.new(1, 0, 0, 92)
	summary.BackgroundColor3 = colors.panel
	summary.BorderSizePixel = 0
	summary.LayoutOrder = 2
	summary.Parent = root

	local summaryGrid = Instance.new("UIGridLayout")
	summaryGrid.CellSize = UDim2.new(0.5, -6, 0, 38)
	summaryGrid.CellPadding = UDim2.new(0, 8, 0, 8)
	summaryGrid.SortOrder = Enum.SortOrder.LayoutOrder
	summaryGrid.Parent = summary
	addPadding(platform, summary, 8)

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, -152)
	content.BackgroundColor3 = colors.panel
	content.BorderSizePixel = 0
	content.LayoutOrder = 3
	content.CanvasSize = UDim2.new()
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.ScrollBarThickness = 8
	content.Parent = root

	addVerticalList(platform, content, 8)
	addPadding(platform, content, 8)

	return {
		root = root,
		scanButton = scanButton,
		summary = summary,
		content = content,
		contentSizeWithLive = UDim2.new(1, 0, 1, -388),
	}
end

function PluginView.mount(platform: any, Contracts: any, PluginModel: any): any
	local StudioReport = Contracts.Studio.StudioReport
	local colors = Theme.colors(platform.Color3)

	local toolbar = platform.plugin:CreateToolbar("Luau Contracts")
	local button = toolbar:CreateButton("Contracts", "Open Luau Contracts", "")
	button.ClickableWhenViewportHidden = true

	local widgetInfo =
		platform.DockWidgetPluginGuiInfo.new(platform.Enum.InitialDockState.Right, false, false, 460, 620, 340, 360)
	local widget = platform.plugin:CreateDockWidgetPluginGui("LuauContractSDKPanel", widgetInfo)
	widget.Title = "Luau Contracts"

	local panel = createMainPanel(platform, colors, widget)

	local function collectScripts(): any
		return PluginModel.collectScripts(platform.game)
	end

	local function renderSummary(report: any)
		Widgets.clear(panel.summary)
		for _, card in ipairs(PluginModel.summaryCards(report)) do
			Widgets.makeSummaryCard(
				platform,
				colors,
				panel.summary,
				card.label,
				card.value,
				Theme.toneColor(colors, card.tone)
			)
		end
	end

	local function renderSystems(report: any)
		local section = Widgets.makeSection(platform, colors, panel.content, "Systems")
		if #report.systems == 0 then
			Widgets.makeLabel(platform, colors, section, "No contract systems found.", 22, colors.muted, false)
			return
		end

		for _, row in ipairs(PluginModel.systemRows(report, StudioReport.formatSystem)) do
			Widgets.makeLabel(platform, colors, section, row.summary, 24, colors.text, false)
			Widgets.makeLabel(platform, colors, section, row.path, 20, colors.muted, false)
		end
	end

	local function renderFindings(report: any)
		local section = Widgets.makeSection(platform, colors, panel.content, "Static Findings")
		if #report.scanner.findings == 0 then
			Widgets.makeLabel(platform, colors, section, "No static findings.", 22, colors.ok, false)
			return
		end

		for _, row in ipairs(PluginModel.findingRows(report)) do
			Widgets.makeLabel(platform, colors, section, row.title, 28, Theme.toneColor(colors, row.tone), true)
			Widgets.makeLabel(platform, colors, section, row.message, 34, colors.text, false)
		end
	end

	local function renderDiagnostics(report: any)
		local section = Widgets.makeSection(platform, colors, panel.content, "Recent Diagnostics")
		if #report.diagnostics == 0 then
			Widgets.makeLabel(platform, colors, section, "No diagnostics report attached.", 22, colors.muted, false)
			return
		end

		for _, row in ipairs(PluginModel.diagnosticRows(report, StudioReport.formatDiagnostic)) do
			Widgets.makeLabel(platform, colors, section, row.text, 28, colors.text, false)
		end
	end

	local function render(report: any)
		renderSummary(report)
		Widgets.clear(panel.content)
		renderSystems(report)
		renderFindings(report)
		renderDiagnostics(report)
	end

	local function scan()
		panel.scanButton.Text = "Scanning..."
		render(StudioReport.fromScripts(collectScripts()))
		panel.scanButton.Text = "Scan"
	end

	Live.mount(platform, colors, PluginModel, panel.root, panel.content, panel.contentSizeWithLive)

	panel.scanButton.Activated:Connect(scan)
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
		if widget.Enabled then
			scan()
		end
	end)

	render(StudioReport.fromScripts({}))

	return {
		widget = widget,
		scan = scan,
	}
end

return PluginView
