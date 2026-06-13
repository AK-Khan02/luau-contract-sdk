--!strict

local Widgets = {}

function Widgets.clear(container: any)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy() -- contracts-scan: ignore unowned-destroy
		end
	end
end

function Widgets.makeLabel(
	platform: any,
	colors: any,
	parent: any,
	text: string,
	height: number?,
	color: any?,
	bold: boolean?
): any
	local Instance = platform.Instance
	local UDim2 = platform.UDim2
	local Enum = platform.Enum

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, height or 22)
	label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = bold and 14 or 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextColor3 = color or colors.text
	label.TextWrapped = true
	label.Text = text
	label.Parent = parent
	return label
end

function Widgets.makeSummaryCard(platform: any, colors: any, summary: any, label: string, value: any, color: any?): any
	local Instance = platform.Instance
	local UDim2 = platform.UDim2

	local card = Instance.new("Frame")
	card.BackgroundColor3 = colors.panelAlt
	card.BorderSizePixel = 0
	card.Parent = summary

	Widgets.makeLabel(platform, colors, card, label, 14, colors.muted, false).Position = UDim2.new(0, 8, 0, 5)
	local valueLabel = Widgets.makeLabel(platform, colors, card, tostring(value), 20, color or colors.text, true)
	valueLabel.Position = UDim2.new(0, 8, 0, 18)
	return card
end

function Widgets.makeSection(platform: any, colors: any, content: any, titleText: string): any
	local Instance = platform.Instance
	local UDim2 = platform.UDim2
	local UDim = platform.UDim
	local Enum = platform.Enum

	local section = Instance.new("Frame")
	section.BackgroundColor3 = colors.panelAlt
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

	Widgets.makeLabel(platform, colors, section, titleText, 22, colors.text, true)
	return section
end

function Widgets.makeLiveButton(platform: any, colors: any, parent: any, text: string, offset: number): any
	local Instance = platform.Instance
	local UDim2 = platform.UDim2
	local Vector2 = platform.Vector2
	local Enum = platform.Enum

	local liveButton = Instance.new("TextButton")
	liveButton.AnchorPoint = Vector2.new(1, 0.5)
	liveButton.Position = UDim2.new(1, offset, 0.5, 0)
	liveButton.Size = UDim2.new(0, 64, 0, 26)
	liveButton.BackgroundColor3 = colors.panelAlt
	liveButton.BorderSizePixel = 0
	liveButton.Font = Enum.Font.GothamBold
	liveButton.TextSize = 12
	liveButton.TextColor3 = colors.text
	liveButton.Text = text
	liveButton.Parent = parent
	return liveButton
end

return Widgets
