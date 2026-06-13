--!strict

local Theme = require("./LuauContractStudioPluginTheme")
local Widgets = require("./LuauContractStudioPluginWidgets")

local Live = {}

local LIVE_SECTION_HEIGHT = 228
local LIVE_MAX_ROWS = 100

function Live.mount(
	platform: any,
	colors: any,
	PluginModel: any,
	root: any,
	content: any,
	contentSizeWithLive: any
): any
	local game = platform.game
	local Instance = platform.Instance
	local UDim2 = platform.UDim2
	local UDim = platform.UDim
	local Vector2 = platform.Vector2
	local Enum = platform.Enum

	local liveSection = Instance.new("Frame")
	liveSection.Name = "LiveSection"
	liveSection.Size = UDim2.new(1, 0, 0, LIVE_SECTION_HEIGHT)
	liveSection.BackgroundColor3 = colors.panel
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

	local liveTitle = Widgets.makeLabel(platform, colors, liveHeader, "Live Diagnostics", 34, colors.text, true)
	liveTitle.Size = UDim2.new(1, -160, 1, 0)

	local pauseButton = Widgets.makeLiveButton(platform, colors, liveHeader, "Pause", -72)
	local clearButton = Widgets.makeLiveButton(platform, colors, liveHeader, "Clear", 0)

	local liveList = Instance.new("ScrollingFrame")
	liveList.Name = "LiveList"
	liveList.Size = UDim2.new(1, -16, 1, -46)
	liveList.Position = UDim2.new(0, 8, 0, 40)
	liveList.BackgroundColor3 = colors.panelAlt
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

	local liveState: any = {
		rows = {},
		paused = false,
		seenSeq = {},
		attachedFolder = nil,
	}

	local function renderLive()
		Widgets.clear(liveList)
		if #liveState.rows == 0 then
			Widgets.makeLabel(platform, colors, liveList, "Waiting for diagnostics...", 20, colors.muted, false)
			return
		end

		for index, row in ipairs(liveState.rows) do
			local label =
				Widgets.makeLabel(platform, colors, liveList, row.text, 20, Theme.toneColor(colors, row.tone), false)
			label.LayoutOrder = index
			label.TextSize = 12
		end

		liveList.CanvasPosition = Vector2.new(0, math.max(0, liveList.AbsoluteCanvasSize.Y))
	end

	local function showLiveSection()
		if not liveSection.Visible then
			liveSection.Visible = true
			content.Size = contentSizeWithLive
			renderLive()
		end
	end

	local function onBatchValue(child: any)
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

		local batch: any = PluginModel.batchFromDecoded(decoded)
		local seenSeq: any = liveState.seenSeq
		if batch == nil or seenSeq[batch.seq] then
			return
		end
		seenSeq[batch.seq] = true

		PluginModel.appendLive(liveState.rows, PluginModel.liveRows(batch), LIVE_MAX_ROWS)
		renderLive()
	end

	local function attachLiveFolder(folder: any)
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

		replicatedStorage.ChildAdded:Connect(function(child: any)
			if child.Name == "__LuauContractDiagnostics" then
				attachLiveFolder(child)
			end
		end)
	end

	pauseButton.Activated:Connect(function()
		liveState.paused = not liveState.paused
		pauseButton.Text = liveState.paused and "Resume" or "Pause"
		pauseButton.BackgroundColor3 = liveState.paused and colors.accent or colors.panelAlt
	end)

	clearButton.Activated:Connect(function()
		liveState.rows = {}
		renderLive()
	end)

	watchForLiveFolder()

	return {
		render = renderLive,
	}
end

return Live
