local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	return
end

local function bootstrap()
	local coreGuiContainer = nil
	pcall(function()
		coreGuiContainer = game:GetService("CoreGui")
	end)

	for _, container in ipairs({coreGuiContainer, localPlayer:FindFirstChildOfClass("PlayerGui")}) do
		if container then
			local existingGui = container:FindFirstChild("StandaloneMovementGui")
			if existingGui then
				existingGui:Destroy()
			end
		end
	end

	local guiParent = coreGuiContainer or localPlayer:FindFirstChildOfClass("PlayerGui")
	if not guiParent then
		return
	end

	local isTouchDevice = UserInputService.TouchEnabled
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local attackRemote = remotes and remotes:FindFirstChild("RequestAttack")
	local flySpeed = 64
	local flySmoothing = 0.18
	local altitudeAdjustSpeed = 42
	local altitudeResponse = 7
	local maxVerticalSpeed = 56
	local defaultLockHeightOffset = 25
	local terrainProbeDistance = 512
	local analogDeadzone = 0.18
	local panelWidth = isTouchDevice and 336 or 320
	local panelHeight = isTouchDevice and 356 or 404

	local connections = {}
	local destroyed = false
	local savedCoordinates = {}
	local espEntries = {}
	local movementState = {
		forward = 0,
		backward = 0,
		left = 0,
		right = 0,
		up = 0,
		down = 0,
	}
	local flyState = {
		enabled = false,
		velocity = Vector3.zero,
		targetHeight = nil,
		lockHeightEnabled = false,
		diveBelowEnabled = false,
		lockHeightOffset = defaultLockHeightOffset,
	}
	local utilityState = {
		noclipEnabled = false,
		espEnabled = false,
		autoCollectEnabled = false,
		autoFarmEnabled = false,
		autoKillEnabled = false,
		lastCollectAt = 0,
		lastAttackAt = 0,
	}

	local flyKeys = {
		[Enum.KeyCode.W] = "forward",
		[Enum.KeyCode.S] = "backward",
		[Enum.KeyCode.A] = "left",
		[Enum.KeyCode.D] = "right",
		[Enum.KeyCode.Space] = "up",
		[Enum.KeyCode.LeftControl] = "down",
	}

	local function connect(signal, callback)
		local connection = signal:Connect(callback)
		table.insert(connections, connection)
		return connection
	end

	local function getCharacter()
		return localPlayer.Character or localPlayer.CharacterAdded:Wait()
	end

	local function getRootPart()
		local character = getCharacter()
		return character and character:FindFirstChild("HumanoidRootPart")
	end

	local function getHumanoid()
		local character = getCharacter()
		return character and character:FindFirstChildOfClass("Humanoid")
	end

	local function getCharacterParts()
		local character = localPlayer.Character
		if not character then
			return {}
		end

		local parts = {}
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(parts, descendant)
			end
		end

		return parts
	end

	local function sanitizeNumber(text)
		local value = tonumber(text)
		if not value then
			return nil
		end

		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end

		return value
	end

	local function clampToViewport(position, size, viewportSize)
		local minX = 8
		local minY = 8
		local maxX = math.max(minX, viewportSize.X - size.X.Offset - 8)
		local maxY = math.max(minY, viewportSize.Y - size.Y.Offset - 8)

		return UDim2.fromOffset(
			math.clamp(position.X.Offset, minX, maxX),
			math.clamp(position.Y.Offset, minY, maxY)
		)
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StandaloneMovementGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = guiParent

	pcall(function()
		if gethui then
			screenGui.Parent = gethui()
		elseif syn and syn.protect_gui then
			syn.protect_gui(screenGui)
		end
	end)

	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "OpenCloseButton"
	toggleButton.Size = UDim2.fromOffset(isTouchDevice and 120 or 112, isTouchDevice and 38 or 32)
	toggleButton.Position = UDim2.new(1, -(isTouchDevice and 136 or 132), 0.5, -16)
	toggleButton.BackgroundColor3 = Color3.fromRGB(18, 24, 34)
	toggleButton.BackgroundTransparency = 0.2
	toggleButton.BorderSizePixel = 0
	toggleButton.Text = "Open Panel"
	toggleButton.TextColor3 = Color3.fromRGB(235, 240, 245)
	toggleButton.TextSize = isTouchDevice and 15 or 14
	toggleButton.Font = Enum.Font.GothamMedium
	toggleButton.Parent = screenGui

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 10)
	toggleCorner.Parent = toggleButton

	local panel = Instance.new("Frame")
	panel.Name = "MainPanel"
	panel.Size = UDim2.fromOffset(panelWidth, panelHeight)
	panel.Position = UDim2.new(1, -(panelWidth + 20), 0.5, -(panelHeight / 2))
	panel.BackgroundColor3 = Color3.fromRGB(15, 20, 28)
	panel.BackgroundTransparency = 0.16
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Visible = false
	panel.Parent = screenGui

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 12)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(82, 164, 255)
	panelStroke.Transparency = 0.45
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 38)
	titleBar.BackgroundTransparency = 1
	titleBar.Parent = panel

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -84, 1, 0)
	titleLabel.Position = UDim2.fromOffset(14, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "Movement Panel"
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	titleLabel.TextSize = isTouchDevice and 17 or 16
	titleLabel.Font = Enum.Font.GothamSemibold
	titleLabel.Parent = titleBar

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Size = UDim2.fromOffset(60, 26)
	closeButton.Position = UDim2.new(1, -70, 0.5, -13)
	closeButton.BackgroundColor3 = Color3.fromRGB(31, 40, 53)
	closeButton.BackgroundTransparency = 0.15
	closeButton.BorderSizePixel = 0
	closeButton.Text = "Close"
	closeButton.TextColor3 = Color3.fromRGB(235, 240, 245)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamMedium
	closeButton.Parent = titleBar

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeButton

	local contentScroll = Instance.new("ScrollingFrame")
	contentScroll.Name = "ContentScroll"
	contentScroll.Size = UDim2.new(1, -20, 1, -48)
	contentScroll.Position = UDim2.fromOffset(10, 40)
	contentScroll.Active = true
	contentScroll.BackgroundTransparency = 1
	contentScroll.BorderSizePixel = 0
	contentScroll.ScrollingDirection = Enum.ScrollingDirection.Y
	contentScroll.ScrollingEnabled = true
	contentScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	contentScroll.CanvasSize = UDim2.fromOffset(0, 0)
	contentScroll.ScrollBarImageColor3 = Color3.fromRGB(82, 164, 255)
	contentScroll.ScrollBarThickness = isTouchDevice and 6 or 4
	contentScroll.Parent = panel

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -6, 0, 0)
	content.BackgroundTransparency = 1
	content.Parent = contentScroll

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 10)
	listLayout.Parent = content

	local function createSection(height)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, 0, 0, height)
		frame.BackgroundColor3 = Color3.fromRGB(24, 31, 44)
		frame.BackgroundTransparency = 0.1
		frame.BorderSizePixel = 0

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = frame

		return frame
	end

	local function createActionButton(name, text, color)
		local button = Instance.new("TextButton")
		button.Name = name
		button.BackgroundColor3 = color
		button.BorderSizePixel = 0
		button.Text = text
		button.TextColor3 = Color3.fromRGB(245, 248, 250)
		button.TextSize = 13
		button.Font = Enum.Font.GothamMedium

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button

		return button
	end

	local function setButtonState(button, enabled, onColor, offColor)
		button.Text = enabled and "ON" or "OFF"
		button.BackgroundColor3 = enabled and onColor or offColor
	end

	local function createInputBox(name, placeholder)
		local box = Instance.new("TextBox")
		box.Name = name
		box.BackgroundColor3 = Color3.fromRGB(12, 17, 24)
		box.BackgroundTransparency = 0.08
		box.BorderSizePixel = 0
		box.PlaceholderText = placeholder
		box.Text = ""
		box.TextColor3 = Color3.fromRGB(240, 244, 248)
		box.PlaceholderColor3 = Color3.fromRGB(140, 149, 162)
		box.TextSize = 14
		box.Font = Enum.Font.Gotham
		box.ClearTextOnFocus = false

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = box

		return box
	end

	local function setPanelVisible(visible)
		if destroyed then
			return
		end

		panel.Visible = visible
		toggleButton.Text = visible and "Hide Panel" or "Open Panel"
	end

	local flySection = createSection(isTouchDevice and 126 or 118)
	flySection.LayoutOrder = 1
	flySection.Parent = content

	local flyLabel = Instance.new("TextLabel")
	flyLabel.Size = UDim2.new(0.5, 0, 0, 20)
	flyLabel.Position = UDim2.fromOffset(12, 10)
	flyLabel.BackgroundTransparency = 1
	flyLabel.Text = "Fly"
	flyLabel.TextXAlignment = Enum.TextXAlignment.Left
	flyLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	flyLabel.TextSize = 15
	flyLabel.Font = Enum.Font.GothamSemibold
	flyLabel.Parent = flySection

	local flyButton = createActionButton("FlyToggle", "OFF", Color3.fromRGB(120, 52, 52))
	flyButton.Size = UDim2.fromOffset(82, 32)
	flyButton.Position = UDim2.new(1, -94, 0, 10)
	flyButton.TextSize = 14
	flyButton.Font = Enum.Font.GothamBold
	flyButton.Parent = flySection

	local lockHeightLabel = Instance.new("TextLabel")
	lockHeightLabel.Size = UDim2.new(0, 100, 0, 18)
	lockHeightLabel.Position = UDim2.fromOffset(12, 52)
	lockHeightLabel.BackgroundTransparency = 1
	lockHeightLabel.Text = "Lock Height"
	lockHeightLabel.TextXAlignment = Enum.TextXAlignment.Left
	lockHeightLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	lockHeightLabel.TextSize = 13
	lockHeightLabel.Font = Enum.Font.GothamMedium
	lockHeightLabel.Parent = flySection

	local lockHeightBox = createInputBox("LockHeightBox", "25")
	lockHeightBox.Size = UDim2.fromOffset(70, 28)
	lockHeightBox.Position = UDim2.fromOffset(114, 48)
	lockHeightBox.Text = tostring(defaultLockHeightOffset)
	lockHeightBox.TextSize = 13
	lockHeightBox.Parent = flySection

	local lockHeightButton = createActionButton("LockHeightToggle", "OFF", Color3.fromRGB(120, 52, 52))
	lockHeightButton.Size = UDim2.fromOffset(82, 28)
	lockHeightButton.Position = UDim2.new(1, -94, 0, 48)
	lockHeightButton.TextSize = 13
	lockHeightButton.Font = Enum.Font.GothamBold
	lockHeightButton.Parent = flySection

	local diveBelowLabel = Instance.new("TextLabel")
	diveBelowLabel.Size = UDim2.new(0, 100, 0, 18)
	diveBelowLabel.Position = UDim2.fromOffset(12, 86)
	diveBelowLabel.BackgroundTransparency = 1
	diveBelowLabel.Text = "Dive Below"
	diveBelowLabel.TextXAlignment = Enum.TextXAlignment.Left
	diveBelowLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	diveBelowLabel.TextSize = 13
	diveBelowLabel.Font = Enum.Font.GothamMedium
	diveBelowLabel.Parent = flySection

	local diveBelowButton = createActionButton("DiveBelowToggle", "OFF", Color3.fromRGB(120, 52, 52))
	diveBelowButton.Size = UDim2.fromOffset(82, 28)
	diveBelowButton.Position = UDim2.new(1, -94, 0, 82)
	diveBelowButton.TextSize = 13
	diveBelowButton.Font = Enum.Font.GothamBold
	diveBelowButton.Parent = flySection

	local teleportSection = createSection(148)
	teleportSection.LayoutOrder = 2
	teleportSection.Parent = content

	local teleportLabel = Instance.new("TextLabel")
	teleportLabel.Size = UDim2.new(1, -24, 0, 20)
	teleportLabel.Position = UDim2.fromOffset(12, 10)
	teleportLabel.BackgroundTransparency = 1
	teleportLabel.Text = "Teleport"
	teleportLabel.TextXAlignment = Enum.TextXAlignment.Left
	teleportLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	teleportLabel.TextSize = 15
	teleportLabel.Font = Enum.Font.GothamSemibold
	teleportLabel.Parent = teleportSection

	local inputRow = Instance.new("Frame")
	inputRow.Size = UDim2.new(1, -24, 0, 38)
	inputRow.Position = UDim2.fromOffset(12, 38)
	inputRow.BackgroundTransparency = 1
	inputRow.Parent = teleportSection

	local inputLayout = Instance.new("UIListLayout")
	inputLayout.FillDirection = Enum.FillDirection.Horizontal
	inputLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	inputLayout.SortOrder = Enum.SortOrder.LayoutOrder
	inputLayout.Padding = UDim.new(0, 6)
	inputLayout.Parent = inputRow

	local function createCoordinateBox(name, placeholder)
		local box = createInputBox(name, placeholder)
		box.Size = UDim2.new(1 / 3, -4, 1, 0)
		return box
	end

	local xBox = createCoordinateBox("XBox", "X")
	xBox.Parent = inputRow

	local yBox = createCoordinateBox("YBox", "Y")
	yBox.Parent = inputRow

	local zBox = createCoordinateBox("ZBox", "Z")
	zBox.Parent = inputRow

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -24, 0, 18)
	statusLabel.Position = UDim2.fromOffset(12, 82)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "Masukkan koordinat atau ambil posisi saat ini."
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextColor3 = Color3.fromRGB(172, 182, 196)
	statusLabel.TextSize = 12
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.Parent = teleportSection

	local actionRow = Instance.new("Frame")
	actionRow.Size = UDim2.new(1, -24, 0, 54)
	actionRow.Position = UDim2.fromOffset(12, 102)
	actionRow.BackgroundTransparency = 1
	actionRow.Parent = teleportSection

	local actionGrid = Instance.new("UIGridLayout")
	actionGrid.CellSize = UDim2.new(0.5, -4, 0, 24)
	actionGrid.CellPadding = UDim2.new(0, 8, 0, 6)
	actionGrid.FillDirectionMaxCells = 2
	actionGrid.Parent = actionRow

	local getCoordinateButton = createActionButton("GetCoordinateButton", "Get Coordinate", Color3.fromRGB(44, 95, 155))
	getCoordinateButton.Parent = actionRow

	local teleportButton = createActionButton("TeleportButton", "Teleport", Color3.fromRGB(46, 138, 90))
	teleportButton.Parent = actionRow

	local saveInputButton = createActionButton("SaveInputButton", "Save Input", Color3.fromRGB(168, 118, 40))
	saveInputButton.Parent = actionRow

	local saveCurrentButton = createActionButton("SaveCurrentButton", "Save Current", Color3.fromRGB(109, 77, 166))
	saveCurrentButton.Parent = actionRow

	local savedSection = createSection(74)
	savedSection.LayoutOrder = 3
	savedSection.Parent = content

	local savedLabel = Instance.new("TextLabel")
	savedLabel.Size = UDim2.new(1, -24, 0, 20)
	savedLabel.Position = UDim2.fromOffset(12, 10)
	savedLabel.BackgroundTransparency = 1
	savedLabel.Text = "Saved Coordinates"
	savedLabel.TextXAlignment = Enum.TextXAlignment.Left
	savedLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	savedLabel.TextSize = 15
	savedLabel.Font = Enum.Font.GothamSemibold
	savedLabel.Parent = savedSection

	local savedContainer = Instance.new("Frame")
	savedContainer.Size = UDim2.new(1, -24, 0, 0)
	savedContainer.Position = UDim2.fromOffset(12, 30)
	savedContainer.BackgroundTransparency = 1
	savedContainer.Parent = savedSection

	local savedList = Instance.new("UIListLayout")
	savedList.Padding = UDim.new(0, 6)
	savedList.SortOrder = Enum.SortOrder.LayoutOrder
	savedList.Parent = savedContainer

	local utilitySection = createSection(124)
	utilitySection.LayoutOrder = 4
	utilitySection.Parent = content

	local utilityLabel = Instance.new("TextLabel")
	utilityLabel.Size = UDim2.new(1, -24, 0, 18)
	utilityLabel.Position = UDim2.fromOffset(12, 10)
	utilityLabel.BackgroundTransparency = 1
	utilityLabel.Text = "Utility"
	utilityLabel.TextXAlignment = Enum.TextXAlignment.Left
	utilityLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	utilityLabel.TextSize = 15
	utilityLabel.Font = Enum.Font.GothamSemibold
	utilityLabel.Parent = utilitySection

	local utilityRow = Instance.new("Frame")
	utilityRow.Size = UDim2.new(1, -24, 0, 90)
	utilityRow.Position = UDim2.fromOffset(12, 28)
	utilityRow.BackgroundTransparency = 1
	utilityRow.Parent = utilitySection

	local utilityGrid = Instance.new("UIGridLayout")
	utilityGrid.CellSize = UDim2.new(0.5, -4, 0, 24)
	utilityGrid.CellPadding = UDim2.new(0, 8, 0, 8)
	utilityGrid.FillDirectionMaxCells = 2
	utilityGrid.Parent = utilityRow

	local noclipButton = createActionButton("NoclipToggle", "OFF", Color3.fromRGB(120, 52, 52))
	noclipButton.Parent = utilityRow

	local espButton = createActionButton("EspToggle", "OFF", Color3.fromRGB(120, 52, 52))
	espButton.Parent = utilityRow

	local autoCollectButton = createActionButton("AutoCollectToggle", "OFF", Color3.fromRGB(120, 52, 52))
	autoCollectButton.Parent = utilityRow

	local autoFarmButton = createActionButton("AutoFarmToggle", "OFF", Color3.fromRGB(120, 52, 52))
	autoFarmButton.Parent = utilityRow

	local autoKillButton = createActionButton("AutoKillToggle", "OFF", Color3.fromRGB(120, 52, 52))
	autoKillButton.Parent = utilityRow

	local utilityHint = Instance.new("TextLabel")
	utilityHint.Size = UDim2.new(1, -24, 0, 16)
	utilityHint.Position = UDim2.fromOffset(12, 104)
	utilityHint.BackgroundTransparency = 1
	utilityHint.Text = "ESP menandai humanoid dan prompt collectible."
	utilityHint.TextXAlignment = Enum.TextXAlignment.Left
	utilityHint.TextColor3 = Color3.fromRGB(172, 182, 196)
	utilityHint.TextSize = 11
	utilityHint.Font = Enum.Font.Gotham
	utilityHint.Parent = utilitySection

	local executeSection = createSection(96)
	executeSection.LayoutOrder = 5
	executeSection.Parent = content

	local executeLabel = Instance.new("TextLabel")
	executeLabel.Size = UDim2.new(1, -24, 0, 18)
	executeLabel.Position = UDim2.fromOffset(12, 10)
	executeLabel.BackgroundTransparency = 1
	executeLabel.Text = "Execution"
	executeLabel.TextXAlignment = Enum.TextXAlignment.Left
	executeLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	executeLabel.TextSize = 15
	executeLabel.Font = Enum.Font.GothamSemibold
	executeLabel.Parent = executeSection

	local executeRow = Instance.new("Frame")
	executeRow.Size = UDim2.new(1, -24, 0, 52)
	executeRow.Position = UDim2.fromOffset(12, 28)
	executeRow.BackgroundTransparency = 1
	executeRow.Parent = executeSection

	local executeLayout = Instance.new("UIListLayout")
	executeLayout.FillDirection = Enum.FillDirection.Vertical
	executeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	executeLayout.Padding = UDim.new(0, 8)
	executeLayout.Parent = executeRow

	local restartButton = createActionButton("RestartButton", "Restart Execute", Color3.fromRGB(52, 108, 173))
	restartButton.Size = UDim2.new(1, 0, 0, 22)
	restartButton.Parent = executeRow

	local closeExecuteButton = createActionButton("CloseExecuteButton", "Close Execute", Color3.fromRGB(148, 58, 58))
	closeExecuteButton.Size = UDim2.new(1, 0, 0, 22)
	closeExecuteButton.Parent = executeRow

	local touchControls = Instance.new("Frame")
	touchControls.Name = "TouchControls"
	touchControls.Size = UDim2.fromOffset(58, 174)
	touchControls.Position = UDim2.new(1, -138, 1, -250)
	touchControls.BackgroundTransparency = 1
	touchControls.Visible = false
	touchControls.Parent = screenGui

	local function createTouchButton(name, text, position)
		local button = Instance.new("TextButton")
		button.Name = name
		button.Size = UDim2.fromOffset(58, 58)
		button.Position = position
		button.BackgroundColor3 = Color3.fromRGB(18, 24, 34)
		button.BackgroundTransparency = 0.22
		button.BorderSizePixel = 0
		button.Text = text
		button.TextColor3 = Color3.fromRGB(245, 248, 250)
		button.TextSize = 20
		button.Font = Enum.Font.GothamBold
		button.Parent = touchControls

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = button

		return button
	end

	local touchDive = createTouchButton("TouchDive", "D", UDim2.fromOffset(0, 0))
	local touchUp = createTouchButton("TouchUp", "+", UDim2.fromOffset(0, 58))
	local touchDown = createTouchButton("TouchDown", "-", UDim2.fromOffset(0, 116))

	local function updateContentCanvas()
		content.Size = UDim2.new(1, -6, 0, listLayout.AbsoluteContentSize.Y)
		contentScroll.CanvasSize = UDim2.fromOffset(0, listLayout.AbsoluteContentSize.Y + 8)
	end

	local function updateSavedSectionHeight()
		local height = math.max(74, 36 + savedList.AbsoluteContentSize.Y + 8)
		savedContainer.Size = UDim2.new(1, -24, 0, savedList.AbsoluteContentSize.Y)
		savedSection.Size = UDim2.new(1, 0, 0, height)
		updateContentCanvas()
	end

	local function updateFlyButton()
		setButtonState(flyButton, flyState.enabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		touchControls.Visible = isTouchDevice and flyState.enabled and not destroyed
	end

	local function updateLockHeightButton()
		setButtonState(lockHeightButton, flyState.lockHeightEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
	end

	local function updateDiveBelowButton()
		setButtonState(diveBelowButton, flyState.diveBelowEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		touchDive.Text = flyState.diveBelowEnabled and "ON" or "D"
		touchDive.BackgroundColor3 = flyState.diveBelowEnabled and Color3.fromRGB(44, 150, 97) or Color3.fromRGB(18, 24, 34)
	end

	local function updateUtilityButtons()
		setButtonState(noclipButton, utilityState.noclipEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		setButtonState(espButton, utilityState.espEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		setButtonState(autoCollectButton, utilityState.autoCollectEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		setButtonState(autoFarmButton, utilityState.autoFarmEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		setButtonState(autoKillButton, utilityState.autoKillEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
	end

	local function setStatus(text, isError)
		statusLabel.Text = text
		statusLabel.TextColor3 = isError and Color3.fromRGB(255, 122, 122) or Color3.fromRGB(172, 182, 196)
	end

	local function fillCoordinateBoxes(position)
		xBox.Text = string.format("%.2f", position.X)
		yBox.Text = string.format("%.2f", position.Y)
		zBox.Text = string.format("%.2f", position.Z)
	end

	local function teleportToPosition(position)
		local rootPart = getRootPart()
		if not rootPart then
			setStatus("Karakter belum siap.", true)
			return false
		end

		rootPart.CFrame = CFrame.new(position)
		rootPart.AssemblyLinearVelocity = Vector3.zero
		if flyState.enabled then
			flyState.targetHeight = position.Y
		end

		setStatus("Teleport berhasil.", false)
		return true
	end

	local function resizeResponsive()
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
		local compact = viewport.X <= 820 or viewport.Y <= 620 or isTouchDevice
		local targetWidth = compact and 336 or 320
		local targetHeight = compact and 356 or 404
		local safeHeight = math.min(targetHeight, math.max(280, viewport.Y - 42))

		panel.Size = UDim2.fromOffset(targetWidth, safeHeight)
		panel.Position = clampToViewport(panel.Position, panel.Size, viewport)
		toggleButton.Position = clampToViewport(toggleButton.Position, toggleButton.Size, viewport)
		touchControls.Position = compact and UDim2.new(1, -138, 1, -250) or UDim2.new(1, -144, 1, -256)
	end

	local function getActiveLockHeightOffset()
		local parsed = sanitizeNumber(lockHeightBox.Text)
		if parsed and parsed > 0 then
			flyState.lockHeightOffset = parsed
			return parsed
		end

		lockHeightBox.Text = string.format("%.0f", flyState.lockHeightOffset)
		return flyState.lockHeightOffset
	end

	local function setFlyEnabled(enabled)
		flyState.enabled = enabled
		flyState.velocity = Vector3.zero

		local humanoid = getHumanoid()
		local rootPart = getRootPart()
		if humanoid then
			humanoid.PlatformStand = enabled
		end

		if enabled and rootPart then
			flyState.targetHeight = rootPart.Position.Y
		else
			flyState.targetHeight = nil
			flyState.lockHeightEnabled = false
			flyState.diveBelowEnabled = false
		end

		if not enabled and rootPart then
			rootPart.AssemblyLinearVelocity = Vector3.zero
		end

		updateFlyButton()
		updateLockHeightButton()
		updateDiveBelowButton()
	end

	local function clearEsp()
		for instance, gui in pairs(espEntries) do
			if gui then
				gui:Destroy()
			end
			espEntries[instance] = nil
		end
	end

	local function getCollectPromptRoot(prompt)
		local parent = prompt.Parent
		if not parent then
			return nil
		end

		if parent:IsA("BasePart") then
			return parent
		end

		if parent:IsA("Attachment") and parent.Parent and parent.Parent:IsA("BasePart") then
			return parent.Parent
		end

		return nil
	end

	local function getPromptWorldPosition(prompt)
		local root = getCollectPromptRoot(prompt)
		return root and root.Position or nil
	end

	local function getNearestCollectPrompt(maxDistance)
		local rootPart = getRootPart()
		if not rootPart then
			return nil
		end

		local nearestPrompt
		local nearestDistance = maxDistance or math.huge
		for _, prompt in ipairs(workspace:GetDescendants()) do
			if prompt:IsA("ProximityPrompt") and prompt.Enabled and prompt.MaxActivationDistance > 0 then
				local promptPosition = getPromptWorldPosition(prompt)
				if promptPosition and not prompt:IsDescendantOf(localPlayer.Character) then
					local distance = (promptPosition - rootPart.Position).Magnitude
					if distance < nearestDistance then
						nearestDistance = distance
						nearestPrompt = prompt
					end
				end
			end
		end

		return nearestPrompt, nearestDistance
	end

	local function getNearestHumanoidTarget(maxDistance)
		local rootPart = getRootPart()
		local character = localPlayer.Character
		if not rootPart then
			return nil
		end

		local nearestModel
		local nearestDistance = maxDistance or math.huge
		for _, model in ipairs(workspace:GetChildren()) do
			if model:IsA("Model") and model ~= character then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local targetRoot = model:FindFirstChild("HumanoidRootPart")
				if humanoid and humanoid.Health > 0 and targetRoot then
					local distance = (targetRoot.Position - rootPart.Position).Magnitude
					if distance < nearestDistance then
						nearestDistance = distance
						nearestModel = model
					end
				end
			end
		end

		return nearestModel, nearestDistance
	end

	local function updateEsp()
		if not utilityState.espEnabled then
			clearEsp()
			return
		end

		local tracked = {}
		for _, model in ipairs(workspace:GetChildren()) do
			if model:IsA("Model") and model ~= localPlayer.Character then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local targetRoot = model:FindFirstChild("HumanoidRootPart")
				if humanoid and targetRoot then
					tracked[model] = {
						adornee = targetRoot,
						color = Color3.fromRGB(120, 255, 180),
						text = model.Name,
					}
				end
			end
		end

		for _, prompt in ipairs(workspace:GetDescendants()) do
			if prompt:IsA("ProximityPrompt") and prompt.Enabled then
				local promptRoot = getCollectPromptRoot(prompt)
				if promptRoot then
					tracked[prompt] = {
						adornee = promptRoot,
						color = Color3.fromRGB(255, 213, 102),
						text = prompt.ObjectText ~= "" and prompt.ObjectText or "Collect",
					}
				end
			end
		end

		for instance, gui in pairs(espEntries) do
			if not tracked[instance] then
				gui:Destroy()
				espEntries[instance] = nil
			end
		end

		for instance, data in pairs(tracked) do
			local gui = espEntries[instance]
			if not gui then
				gui = Instance.new("BillboardGui")
				gui.Name = "UtilityEsp"
				gui.Size = UDim2.fromOffset(150, 34)
				gui.StudsOffset = Vector3.new(0, 3.5, 0)
				gui.AlwaysOnTop = true

				local label = Instance.new("TextLabel")
				label.Name = "Label"
				label.Size = UDim2.fromScale(1, 1)
				label.BackgroundTransparency = 1
				label.TextScaled = true
				label.TextStrokeTransparency = 0.3
				label.Font = Enum.Font.GothamBold
				label.Parent = gui

				gui.Parent = data.adornee
				espEntries[instance] = gui
			end

			gui.Adornee = data.adornee
			gui.Parent = data.adornee
			local label = gui:FindFirstChild("Label")
			if label then
				label.Text = data.text
				label.TextColor3 = data.color
			end
		end
	end

	local function setNoclipEnabled(enabled)
		utilityState.noclipEnabled = enabled
		if not enabled then
			for _, part in ipairs(getCharacterParts()) do
				if part.Name ~= "HumanoidRootPart" then
					part.CanCollide = true
				end
			end
		end
		updateUtilityButtons()
	end

	local function setEspEnabled(enabled)
		utilityState.espEnabled = enabled
		updateEsp()
		updateUtilityButtons()
	end

	local function setAutoCollectEnabled(enabled)
		utilityState.autoCollectEnabled = enabled
		if enabled then
			utilityState.autoFarmEnabled = false
		end
		updateUtilityButtons()
	end

	local function setAutoFarmEnabled(enabled)
		utilityState.autoFarmEnabled = enabled
		if enabled then
			utilityState.autoCollectEnabled = false
			utilityState.autoKillEnabled = false
		end
		updateUtilityButtons()
	end

	local function setAutoKillEnabled(enabled)
		utilityState.autoKillEnabled = enabled
		updateUtilityButtons()
	end

	local function getGroundLockHeight(rootPart, character)
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = {character}
		raycastParams.IgnoreWater = false

		local rayOrigin = rootPart.Position + Vector3.new(0, 6, 0)
		local rayDirection = Vector3.new(0, -terrainProbeDistance, 0)
		local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
		if not result then
			return nil
		end

		return result.Position.Y + getActiveLockHeightOffset(), result.Position.Y - getActiveLockHeightOffset()
	end

	local function resetUtility()
		savedCoordinates = {}
		for _, child in ipairs(savedContainer:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		for key in pairs(movementState) do
			movementState[key] = 0
		end

		xBox.Text = ""
		yBox.Text = ""
		zBox.Text = ""
		setFlyEnabled(false)
		setNoclipEnabled(false)
		setEspEnabled(false)
		setAutoCollectEnabled(false)
		setAutoFarmEnabled(false)
		setAutoKillEnabled(false)
		setStatus("Execute di-reset.", false)
		updateSavedSectionHeight()
	end

	local function destroyUtility()
		if destroyed then
			return
		end

		destroyed = true
		setFlyEnabled(false)

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end

		screenGui:Destroy()
	end

	local dragging = false
	local dragStart
	local panelStart

	connect(titleBar.InputBegan, function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		dragging = true
		dragStart = input.Position
		panelStart = panel.Position

		local connection
		connection = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
				connection:Disconnect()
			end
		end)
	end)

	connect(UserInputService.InputChanged, function(input)
		if destroyed or not dragging then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
		local delta = input.Position - dragStart
		panel.Position = clampToViewport(
			UDim2.fromOffset(panelStart.X.Offset + delta.X, panelStart.Y.Offset + delta.Y),
			panel.Size,
			viewport
		)
	end)

	connect(toggleButton.MouseButton1Click, function()
		setPanelVisible(not panel.Visible)
	end)

	connect(closeButton.MouseButton1Click, function()
		setPanelVisible(false)
	end)

	connect(flyButton.MouseButton1Click, function()
		setFlyEnabled(not flyState.enabled)
		setStatus(flyState.enabled and "Fly aktif." or "Fly dimatikan.", false)
	end)

	connect(noclipButton.MouseButton1Click, function()
		setNoclipEnabled(not utilityState.noclipEnabled)
		setStatus(utilityState.noclipEnabled and "Noclip aktif." or "Noclip dimatikan.", false)
	end)

	connect(espButton.MouseButton1Click, function()
		setEspEnabled(not utilityState.espEnabled)
		setStatus(utilityState.espEnabled and "ESP aktif." or "ESP dimatikan.", false)
	end)

	connect(autoCollectButton.MouseButton1Click, function()
		setAutoCollectEnabled(not utilityState.autoCollectEnabled)
		setStatus(utilityState.autoCollectEnabled and "Auto collect aktif." or "Auto collect dimatikan.", false)
	end)

	connect(autoFarmButton.MouseButton1Click, function()
		setAutoFarmEnabled(not utilityState.autoFarmEnabled)
		setStatus(utilityState.autoFarmEnabled and "Auto farm aktif." or "Auto farm dimatikan.", false)
	end)

	connect(autoKillButton.MouseButton1Click, function()
		setAutoKillEnabled(not utilityState.autoKillEnabled)
		setStatus(utilityState.autoKillEnabled and "Auto kill aktif." or "Auto kill dimatikan.", false)
	end)

	connect(lockHeightButton.MouseButton1Click, function()
		if not flyState.enabled then
			setStatus("Aktifkan fly dulu untuk memakai lock height.", true)
			return
		end

		getActiveLockHeightOffset()
		flyState.lockHeightEnabled = not flyState.lockHeightEnabled
		if flyState.lockHeightEnabled then
			local character = localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local lockHeight = rootPart and select(1, getGroundLockHeight(rootPart, character))
			flyState.targetHeight = lockHeight or (rootPart and rootPart.Position.Y) or flyState.targetHeight
		end

		updateLockHeightButton()
		setStatus(
			flyState.lockHeightEnabled and string.format("Lock height aktif di %.1f stud dari permukaan.", flyState.lockHeightOffset) or "Lock height dimatikan.",
			false
		)
	end)

	connect(diveBelowButton.MouseButton1Click, function()
		if not flyState.enabled then
			setStatus("Aktifkan fly dulu untuk memakai dive below.", true)
			return
		end

		getActiveLockHeightOffset()
		flyState.diveBelowEnabled = not flyState.diveBelowEnabled
		if flyState.diveBelowEnabled then
			local character = localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local diveHeight = rootPart and select(2, getGroundLockHeight(rootPart, character))
			flyState.targetHeight = diveHeight or (rootPart and rootPart.Position.Y) or flyState.targetHeight
		end

		updateDiveBelowButton()
		setStatus(
			flyState.diveBelowEnabled and string.format("Dive below aktif di %.1f stud di bawah permukaan.", flyState.lockHeightOffset) or "Dive below dimatikan.",
			false
		)
	end)

	connect(getCoordinateButton.MouseButton1Click, function()
		local rootPart = getRootPart()
		if not rootPart then
			setStatus("Karakter belum siap.", true)
			return
		end

		fillCoordinateBoxes(rootPart.Position)
		setStatus("Koordinat saat ini berhasil diambil.", false)
	end)

	connect(teleportButton.MouseButton1Click, function()
		local x = sanitizeNumber(xBox.Text)
		local y = sanitizeNumber(yBox.Text)
		local z = sanitizeNumber(zBox.Text)
		if not x or not y or not z then
			setStatus("Koordinat tidak valid. Isi X, Y, Z dengan angka.", true)
			return
		end

		teleportToPosition(Vector3.new(x, y, z))
	end)

	local function addSavedCoordinate(position)
		table.insert(savedCoordinates, position)
		local index = #savedCoordinates

		local row = Instance.new("Frame")
		row.Name = "Coord" .. index
		row.Size = UDim2.new(1, 0, 0, 34)
		row.BackgroundTransparency = 1
		row.LayoutOrder = index
		row.Parent = savedContainer

		local rowLabel = Instance.new("TextLabel")
		rowLabel.Size = UDim2.new(1, -92, 1, 0)
		rowLabel.BackgroundTransparency = 1
		rowLabel.Text = string.format("Coordinate %d  |  %.1f, %.1f, %.1f", index, position.X, position.Y, position.Z)
		rowLabel.TextXAlignment = Enum.TextXAlignment.Left
		rowLabel.TextColor3 = Color3.fromRGB(232, 236, 240)
		rowLabel.TextSize = 12
		rowLabel.Font = Enum.Font.Gotham
		rowLabel.Parent = row

		local useButton = createActionButton("Use", "Go", Color3.fromRGB(46, 138, 90))
		useButton.Size = UDim2.fromOffset(64, 28)
		useButton.Position = UDim2.new(1, -68, 0.5, -14)
		useButton.Parent = row

		connect(useButton.MouseButton1Click, function()
			fillCoordinateBoxes(position)
			teleportToPosition(position)
		end)

		setStatus(string.format("Coordinate %d tersimpan.", index), false)
		updateSavedSectionHeight()
	end

	connect(saveInputButton.MouseButton1Click, function()
		local x = sanitizeNumber(xBox.Text)
		local y = sanitizeNumber(yBox.Text)
		local z = sanitizeNumber(zBox.Text)
		if not x or not y or not z then
			setStatus("Koordinat input belum valid untuk disimpan.", true)
			return
		end

		addSavedCoordinate(Vector3.new(x, y, z))
	end)

	connect(saveCurrentButton.MouseButton1Click, function()
		local rootPart = getRootPart()
		if not rootPart then
			setStatus("Karakter belum siap.", true)
			return
		end

		fillCoordinateBoxes(rootPart.Position)
		addSavedCoordinate(rootPart.Position)
	end)

	connect(restartButton.MouseButton1Click, function()
		resetUtility()
	end)

	connect(closeExecuteButton.MouseButton1Click, function()
		destroyUtility()
	end)

	local function bindTouchDirection(button, stateName)
		local function press()
			movementState[stateName] = 1
		end

		local function release()
			movementState[stateName] = 0
		end

		connect(button.MouseButton1Down, press)
		connect(button.MouseButton1Up, release)
		connect(button.InputBegan, function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				press()
			end
		end)
		connect(button.InputEnded, function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				release()
			end
		end)
		connect(button.MouseLeave, function()
			if not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
				release()
			end
		end)
	end

	bindTouchDirection(touchUp, "up")
	bindTouchDirection(touchDown, "down")

	connect(localPlayer.CharacterAdded, function(character)
		character:WaitForChild("HumanoidRootPart")

		if flyState.enabled then
			task.defer(function()
				if not destroyed then
					setFlyEnabled(true)
				end
			end)
		end
	end)

	connect(touchDive.MouseButton1Click, function()
		if not flyState.enabled then
			setStatus("Aktifkan fly dulu untuk memakai dive below.", true)
			return
		end

		getActiveLockHeightOffset()
		flyState.diveBelowEnabled = not flyState.diveBelowEnabled
		if flyState.diveBelowEnabled then
			local character = localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local diveHeight = rootPart and select(2, getGroundLockHeight(rootPart, character))
			flyState.targetHeight = diveHeight or (rootPart and rootPart.Position.Y) or flyState.targetHeight
		end

		updateDiveBelowButton()
		setStatus(
			flyState.diveBelowEnabled and string.format("Dive below aktif di %.1f stud di bawah permukaan.", flyState.lockHeightOffset) or "Dive below dimatikan.",
			false
		)
	end)

	connect(UserInputService.InputBegan, function(input, processed)
		if processed or destroyed then
			return
		end

		local movementKey = flyKeys[input.KeyCode]
		if movementKey then
			movementState[movementKey] = 1
		end
	end)

	connect(UserInputService.InputEnded, function(input)
		local movementKey = flyKeys[input.KeyCode]
		if movementKey then
			movementState[movementKey] = 0
		end
	end)

	connect(workspace:GetPropertyChangedSignal("CurrentCamera"), resizeResponsive)
	connect(savedList:GetPropertyChangedSignal("AbsoluteContentSize"), updateSavedSectionHeight)
	connect(listLayout:GetPropertyChangedSignal("AbsoluteContentSize"), updateContentCanvas)

	connect(RunService.RenderStepped, function(deltaTime)
		if utilityState.noclipEnabled then
			for _, part in ipairs(getCharacterParts()) do
				if part.Name ~= "HumanoidRootPart" then
					part.CanCollide = false
				end
			end
		end

		if utilityState.espEnabled then
			updateEsp()
		end

		if destroyed or not flyState.enabled then
			-- utility features still continue below
		else
			local character = localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local camera = workspace.CurrentCamera
			if rootPart and humanoid and camera then
				humanoid.PlatformStand = true
				flyState.targetHeight = flyState.targetHeight or rootPart.Position.Y

				local verticalInput = movementState.up - movementState.down
				if flyState.diveBelowEnabled then
					local _, diveHeight = getGroundLockHeight(rootPart, character)
					if diveHeight then
						flyState.targetHeight = diveHeight
					end
				elseif flyState.lockHeightEnabled then
					local lockHeight = select(1, getGroundLockHeight(rootPart, character))
					if lockHeight then
						flyState.targetHeight = lockHeight
					end
				elseif verticalInput ~= 0 then
					flyState.targetHeight += verticalInput * altitudeAdjustSpeed * deltaTime
				end

				local moveDirection = humanoid.MoveDirection
				local horizontalMoveVector
				if moveDirection.Magnitude > analogDeadzone then
					horizontalMoveVector = Vector3.new(moveDirection.X, 0, moveDirection.Z)
				else
					horizontalMoveVector = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
						* (movementState.forward - movementState.backward)
						+ Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
						* (movementState.right - movementState.left)
				end

				if horizontalMoveVector.Magnitude > 0 then
					horizontalMoveVector = horizontalMoveVector.Unit
				else
					horizontalMoveVector = Vector3.zero
				end

				local altitudeError = flyState.targetHeight - rootPart.Position.Y
				local verticalVelocity = math.clamp(altitudeError * altitudeResponse, -maxVerticalSpeed, maxVerticalSpeed)
				local targetVelocity = horizontalMoveVector * flySpeed + Vector3.yAxis * verticalVelocity
				flyState.velocity = flyState.velocity:Lerp(targetVelocity, flySmoothing)
				if horizontalMoveVector == Vector3.zero and math.abs(flyState.velocity.X) < 0.15 and math.abs(flyState.velocity.Z) < 0.15 then
					flyState.velocity = Vector3.new(0, flyState.velocity.Y, 0)
				end
				rootPart.AssemblyLinearVelocity = flyState.velocity

				local lookVector = camera.CFrame.LookVector
				local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
				if flatLook.Magnitude > 0 then
					rootPart.CFrame = CFrame.new(rootPart.Position, rootPart.Position + flatLook.Unit)
				end
			end
		end

		local now = os.clock()
		if (utilityState.autoKillEnabled or utilityState.autoFarmEnabled) and attackRemote and now - utilityState.lastAttackAt >= 0.55 then
			local target = getNearestHumanoidTarget(10)
			if target then
				utilityState.lastAttackAt = now
				attackRemote:FireServer()
			end
		end

		if (utilityState.autoCollectEnabled or utilityState.autoFarmEnabled) and now - utilityState.lastCollectAt >= 0.2 then
			local rootPart = getRootPart()
			local prompt, distance = getNearestCollectPrompt(150)
			if rootPart and prompt then
				local promptPosition = getPromptWorldPosition(prompt)
				if promptPosition then
					utilityState.lastCollectAt = now
					if distance > math.max(prompt.MaxActivationDistance - 1, 4) then
						rootPart.CFrame = CFrame.new(promptPosition + Vector3.new(0, 3, 0))
					end
					if fireproximityprompt then
						pcall(function()
							fireproximityprompt(prompt)
						end)
					end
				end
			end
		end

		if utilityState.autoFarmEnabled then
			local rootPart = getRootPart()
			local target = getNearestHumanoidTarget(120)
			if rootPart and target then
				local targetRoot = target:FindFirstChild("HumanoidRootPart")
				if targetRoot then
					rootPart.CFrame = CFrame.new(targetRoot.Position + Vector3.new(0, 3, 0))
				end
			end
		end
	end)

	updateSavedSectionHeight()
	updateContentCanvas()
	resizeResponsive()
	updateFlyButton()
	updateLockHeightButton()
	updateDiveBelowButton()
	updateUtilityButtons()
	setPanelVisible(false)
end

bootstrap()
