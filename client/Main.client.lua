local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

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
	local playerModule = nil
	local playerControls = nil
	local attackRemote = nil
	local defaultFlySpeed = 64
	local defaultWalkSpeed = 16
	local defaultForwardRunSpeed = 28
	local defaultPlayerSafeRadius = 22
	local altitudeAdjustSpeed = 42
	local altitudeResponse = 5.5
	local maxVerticalSpeed = 42
	local defaultLockHeightOffset = 25
	local terrainProbeDistance = 512
	local analogDeadzone = 0.12
	local groundProbeInterval = 0.08
	local noclipRefreshInterval = 0.12
	local hudRefreshInterval = 0.1
	local playerDistanceProbeInterval = 0.2
	local panelWidth = isTouchDevice and 336 or 320
	local panelHeight = isTouchDevice and 392 or 440

	local connections = {}
	local destroyed = false
	local savedCoordinates = {}
	local originCoordinate = nil
	local characterPartsCache = {}
	local raycastParams = RaycastParams.new()
	local probeState = {
		expiresAt = 0,
		lockHeight = nil,
		diveHeight = nil,
	}
	local loopState = {
		nextHudRefreshAt = 0,
		nextNoclipRefreshAt = 0,
		nextPlayerDistanceProbeAt = 0,
	}
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
		noclipEnabled = false,
		speed = defaultFlySpeed,
		lockHeightOffset = defaultLockHeightOffset,
		playerSafeRadius = defaultPlayerSafeRadius,
		nearbyPlayerDistance = math.huge,
		suppressedByNearbyPlayer = false,
		lastVerticalInput = 0,
	}
	local utilityState = {
		antiAfkEnabled = true,
		autoClickEnabled = false,
		autoClickInterval = 9.5 * 60,
		autoClickToken = 0,
		nextAutoClickAt = 0,
		baseWalkSpeed = defaultWalkSpeed,
		forwardRunSpeed = defaultForwardRunSpeed,
		lastGroundSpeed = nil,
	}
	_G.NightsForestInputLog = _G.NightsForestInputLog or {
		lastAutoClickAt = 0,
		lastAutoClickSource = nil,
		lastMessage = "Belum ada log klik.",
	}

	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = false

	pcall(function()
		local remotes = ReplicatedStorage:WaitForChild("Remotes", 3)
		attackRemote = remotes and remotes:FindFirstChild("RequestAttack")
	end)

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
		return localPlayer.Character
	end

	local function getRootPart()
		local character = getCharacter()
		return character and character:FindFirstChild("HumanoidRootPart")
	end

	local function getHumanoid()
		local character = getCharacter()
		return character and character:FindFirstChildOfClass("Humanoid")
	end

	local function rebuildCharacterPartsCache(character)
		table.clear(characterPartsCache)
		if not character then
			return
		end

		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(characterPartsCache, descendant)
			end
		end
	end

	local function applyNoclipState()
		local canCollide = not (flyState.noclipEnabled and flyState.enabled and not flyState.suppressedByNearbyPlayer)
		for _, part in ipairs(characterPartsCache) do
			if part.Parent and part.Name ~= "HumanoidRootPart" then
				part.CanCollide = canCollide
			end
		end
	end

	local function refreshGroundProbe(rootPart, character)
		local now = os.clock()
		if now < probeState.expiresAt then
			return probeState.lockHeight, probeState.diveHeight
		end

		raycastParams.FilterDescendantsInstances = {character}

		local rayOrigin = rootPart.Position + Vector3.new(0, 6, 0)
		local rayDirection = Vector3.new(0, -terrainProbeDistance, 0)
		local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
		local offset = flyState.lockHeightOffset
		if result then
			probeState.lockHeight = result.Position.Y + offset
			probeState.diveHeight = result.Position.Y - offset
		else
			probeState.lockHeight = nil
			probeState.diveHeight = nil
		end

		probeState.expiresAt = now + groundProbeInterval
		return probeState.lockHeight, probeState.diveHeight
	end

	local function invalidateGroundProbe()
		probeState.expiresAt = 0
		probeState.lockHeight = nil
		probeState.diveHeight = nil
	end

	local function getPlayerMoveVector()
		if not playerControls then
			local playerScripts = localPlayer:FindFirstChildOfClass("PlayerScripts")
			local playerModuleScript = playerScripts and playerScripts:FindFirstChild("PlayerModule")
			if playerModuleScript then
				local ok, module = pcall(require, playerModuleScript)
				if ok and module and module.GetControls then
					playerModule = module
					playerControls = module:GetControls()
				end
			end
		end

		if playerControls and playerControls.GetMoveVector then
			local ok, moveVector = pcall(function()
				return playerControls:GetMoveVector()
			end)
			if ok and typeof(moveVector) == "Vector3" then
				return moveVector
			end
		end

		return Vector3.zero
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

	local function sendNotification(text)
		pcall(function()
			game:GetService("StarterGui"):SetCore("SendNotification", {
				Title = "Movement Panel",
				Text = text,
				Duration = 3,
			})
		end)
	end

	local flySection = createSection(isTouchDevice and 238 or 226)
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

	local noclipLabel = Instance.new("TextLabel")
	noclipLabel.Size = UDim2.new(0, 100, 0, 18)
	noclipLabel.Position = UDim2.fromOffset(12, 52)
	noclipLabel.BackgroundTransparency = 1
	noclipLabel.Text = "Noclip"
	noclipLabel.TextXAlignment = Enum.TextXAlignment.Left
	noclipLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	noclipLabel.TextSize = 13
	noclipLabel.Font = Enum.Font.GothamMedium
	noclipLabel.Parent = flySection

	local noclipButton = createActionButton("NoclipToggle", "OFF", Color3.fromRGB(120, 52, 52))
	noclipButton.Size = UDim2.fromOffset(82, 28)
	noclipButton.Position = UDim2.new(1, -94, 0, 48)
	noclipButton.TextSize = 13
	noclipButton.Font = Enum.Font.GothamBold
	noclipButton.Parent = flySection

	local flySpeedLabel = Instance.new("TextLabel")
	flySpeedLabel.Size = UDim2.new(0, 100, 0, 18)
	flySpeedLabel.Position = UDim2.fromOffset(12, 86)
	flySpeedLabel.BackgroundTransparency = 1
	flySpeedLabel.Text = "Fly Speed"
	flySpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
	flySpeedLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	flySpeedLabel.TextSize = 13
	flySpeedLabel.Font = Enum.Font.GothamMedium
	flySpeedLabel.Parent = flySection

	local flySpeedBox = createInputBox("FlySpeedBox", "64")
	flySpeedBox.Size = UDim2.fromOffset(70, 28)
	flySpeedBox.Position = UDim2.fromOffset(114, 82)
	flySpeedBox.Text = tostring(defaultFlySpeed)
	flySpeedBox.TextSize = 13
	flySpeedBox.Parent = flySection

	local lockHeightLabel = Instance.new("TextLabel")
	lockHeightLabel.Size = UDim2.new(0, 100, 0, 18)
	lockHeightLabel.Position = UDim2.fromOffset(12, 120)
	lockHeightLabel.BackgroundTransparency = 1
	lockHeightLabel.Text = "Height Offset"
	lockHeightLabel.TextXAlignment = Enum.TextXAlignment.Left
	lockHeightLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	lockHeightLabel.TextSize = 13
	lockHeightLabel.Font = Enum.Font.GothamMedium
	lockHeightLabel.Parent = flySection

	local lockHeightBox = createInputBox("LockHeightBox", "25")
	lockHeightBox.Size = UDim2.fromOffset(70, 28)
	lockHeightBox.Position = UDim2.fromOffset(114, 116)
	lockHeightBox.Text = tostring(defaultLockHeightOffset)
	lockHeightBox.TextSize = 13
	lockHeightBox.Parent = flySection

	local lockHeightButton = createActionButton("LockHeightToggle", "OFF", Color3.fromRGB(120, 52, 52))
	lockHeightButton.Size = UDim2.fromOffset(82, 28)
	lockHeightButton.Position = UDim2.new(1, -94, 0, 116)
	lockHeightButton.TextSize = 13
	lockHeightButton.Font = Enum.Font.GothamBold
	lockHeightButton.Parent = flySection

	local playerRadiusLabel = Instance.new("TextLabel")
	playerRadiusLabel.Size = UDim2.new(0, 100, 0, 18)
	playerRadiusLabel.Position = UDim2.fromOffset(12, 154)
	playerRadiusLabel.BackgroundTransparency = 1
	playerRadiusLabel.Text = "Player Radius"
	playerRadiusLabel.TextXAlignment = Enum.TextXAlignment.Left
	playerRadiusLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	playerRadiusLabel.TextSize = 13
	playerRadiusLabel.Font = Enum.Font.GothamMedium
	playerRadiusLabel.Parent = flySection

	local playerRadiusBox = createInputBox("PlayerRadiusBox", "22")
	playerRadiusBox.Size = UDim2.fromOffset(70, 28)
	playerRadiusBox.Position = UDim2.fromOffset(114, 150)
	playerRadiusBox.Text = tostring(defaultPlayerSafeRadius)
	playerRadiusBox.TextSize = 13
	playerRadiusBox.Parent = flySection

	local diveBelowLabel = Instance.new("TextLabel")
	diveBelowLabel.Size = UDim2.new(0, 100, 0, 18)
	diveBelowLabel.Position = UDim2.fromOffset(12, 188)
	diveBelowLabel.BackgroundTransparency = 1
	diveBelowLabel.Text = "Dive Below"
	diveBelowLabel.TextXAlignment = Enum.TextXAlignment.Left
	diveBelowLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	diveBelowLabel.TextSize = 13
	diveBelowLabel.Font = Enum.Font.GothamMedium
	diveBelowLabel.Parent = flySection

	local diveBelowButton = createActionButton("DiveBelowToggle", "OFF", Color3.fromRGB(120, 52, 52))
	diveBelowButton.Size = UDim2.fromOffset(82, 28)
	diveBelowButton.Position = UDim2.new(1, -94, 0, 184)
	diveBelowButton.TextSize = 13
	diveBelowButton.Font = Enum.Font.GothamBold
	diveBelowButton.Parent = flySection

	local flyInfoLabel = Instance.new("TextLabel")
	flyInfoLabel.Size = UDim2.new(1, -24, 0, 18)
	flyInfoLabel.Position = UDim2.fromOffset(12, 216)
	flyInfoLabel.BackgroundTransparency = 1
	flyInfoLabel.Text = "Status fly: normal"
	flyInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
	flyInfoLabel.TextColor3 = Color3.fromRGB(172, 182, 196)
	flyInfoLabel.TextSize = 12
	flyInfoLabel.Font = Enum.Font.Gotham
	flyInfoLabel.Parent = flySection

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

	local utilitySection = createSection(272)
	utilitySection.LayoutOrder = 4
	utilitySection.Parent = content

	local utilityLabel = Instance.new("TextLabel")
	utilityLabel.Size = UDim2.new(1, -24, 0, 20)
	utilityLabel.Position = UDim2.fromOffset(12, 10)
	utilityLabel.BackgroundTransparency = 1
	utilityLabel.Text = "AFK / Auto Click"
	utilityLabel.TextXAlignment = Enum.TextXAlignment.Left
	utilityLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	utilityLabel.TextSize = 15
	utilityLabel.Font = Enum.Font.GothamSemibold
	utilityLabel.Parent = utilitySection

	local antiAfkLabel = Instance.new("TextLabel")
	antiAfkLabel.Size = UDim2.new(0, 120, 0, 18)
	antiAfkLabel.Position = UDim2.fromOffset(12, 42)
	antiAfkLabel.BackgroundTransparency = 1
	antiAfkLabel.Text = "Anti AFK"
	antiAfkLabel.TextXAlignment = Enum.TextXAlignment.Left
	antiAfkLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	antiAfkLabel.TextSize = 13
	antiAfkLabel.Font = Enum.Font.GothamMedium
	antiAfkLabel.Parent = utilitySection

	local antiAfkButton = createActionButton("AntiAfkToggle", "OFF", Color3.fromRGB(120, 52, 52))
	antiAfkButton.Size = UDim2.fromOffset(82, 28)
	antiAfkButton.Position = UDim2.new(1, -94, 0, 38)
	antiAfkButton.TextSize = 13
	antiAfkButton.Font = Enum.Font.GothamBold
	antiAfkButton.Parent = utilitySection

	local autoClickLabel = Instance.new("TextLabel")
	autoClickLabel.Size = UDim2.new(0, 120, 0, 18)
	autoClickLabel.Position = UDim2.fromOffset(12, 76)
	autoClickLabel.BackgroundTransparency = 1
	autoClickLabel.Text = "Auto Click"
	autoClickLabel.TextXAlignment = Enum.TextXAlignment.Left
	autoClickLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	autoClickLabel.TextSize = 13
	autoClickLabel.Font = Enum.Font.GothamMedium
	autoClickLabel.Parent = utilitySection

	local autoClickButton = createActionButton("AutoClickToggle", "OFF", Color3.fromRGB(120, 52, 52))
	autoClickButton.Size = UDim2.fromOffset(82, 28)
	autoClickButton.Position = UDim2.new(1, -94, 0, 72)
	autoClickButton.TextSize = 13
	autoClickButton.Font = Enum.Font.GothamBold
	autoClickButton.Parent = utilitySection

	local autoClickBox = createInputBox("AutoClickIntervalBox", "Interval detik")
	autoClickBox.Size = UDim2.new(1, -24, 0, 30)
	autoClickBox.Position = UDim2.fromOffset(12, 106)
	autoClickBox.Text = tostring(utilityState.autoClickInterval)
	autoClickBox.TextSize = 13
	autoClickBox.Parent = utilitySection

	local walkSpeedLabel = Instance.new("TextLabel")
	walkSpeedLabel.Size = UDim2.new(0, 120, 0, 18)
	walkSpeedLabel.Position = UDim2.fromOffset(12, 142)
	walkSpeedLabel.BackgroundTransparency = 1
	walkSpeedLabel.Text = "Walk Speed"
	walkSpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
	walkSpeedLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	walkSpeedLabel.TextSize = 13
	walkSpeedLabel.Font = Enum.Font.GothamMedium
	walkSpeedLabel.Parent = utilitySection

	local walkSpeedBox = createInputBox("WalkSpeedBox", "16")
	walkSpeedBox.Size = UDim2.fromOffset(70, 28)
	walkSpeedBox.Position = UDim2.fromOffset(114, 138)
	walkSpeedBox.Text = tostring(defaultWalkSpeed)
	walkSpeedBox.TextSize = 13
	walkSpeedBox.Parent = utilitySection

	local runSpeedLabel = Instance.new("TextLabel")
	runSpeedLabel.Size = UDim2.new(0, 120, 0, 18)
	runSpeedLabel.Position = UDim2.fromOffset(12, 176)
	runSpeedLabel.BackgroundTransparency = 1
	runSpeedLabel.Text = "Forward Run"
	runSpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
	runSpeedLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
	runSpeedLabel.TextSize = 13
	runSpeedLabel.Font = Enum.Font.GothamMedium
	runSpeedLabel.Parent = utilitySection

	local runSpeedBox = createInputBox("ForwardRunSpeedBox", "28")
	runSpeedBox.Size = UDim2.fromOffset(70, 28)
	runSpeedBox.Position = UDim2.fromOffset(114, 172)
	runSpeedBox.Text = tostring(defaultForwardRunSpeed)
	runSpeedBox.TextSize = 13
	runSpeedBox.Parent = utilitySection

	local autoClickCooldownLabel = Instance.new("TextLabel")
	autoClickCooldownLabel.Size = UDim2.new(1, -24, 0, 18)
	autoClickCooldownLabel.Position = UDim2.fromOffset(12, 210)
	autoClickCooldownLabel.BackgroundTransparency = 1
	autoClickCooldownLabel.Text = "Cooldown: siap"
	autoClickCooldownLabel.TextXAlignment = Enum.TextXAlignment.Left
	autoClickCooldownLabel.TextColor3 = Color3.fromRGB(172, 182, 196)
	autoClickCooldownLabel.TextSize = 12
	autoClickCooldownLabel.Font = Enum.Font.Gotham
	autoClickCooldownLabel.Parent = utilitySection

	local inputLogLabel = Instance.new("TextLabel")
	inputLogLabel.Size = UDim2.new(1, -24, 0, 28)
	inputLogLabel.Position = UDim2.fromOffset(12, 230)
	inputLogLabel.BackgroundTransparency = 1
	inputLogLabel.Text = "Log klik: belum ada."
	inputLogLabel.TextWrapped = true
	inputLogLabel.TextXAlignment = Enum.TextXAlignment.Left
	inputLogLabel.TextYAlignment = Enum.TextYAlignment.Top
	inputLogLabel.TextColor3 = Color3.fromRGB(172, 182, 196)
	inputLogLabel.TextSize = 11
	inputLogLabel.Font = Enum.Font.Gotham
	inputLogLabel.Parent = utilitySection

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
	touchControls.Position = UDim2.new(1, -138, 0.5, -160)
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

	local function updateAutoClickCooldownLabel()
		if not utilityState.autoClickEnabled then
			autoClickCooldownLabel.Text = "Cooldown: mati"
			return
		end

		local remaining = math.max(0, utilityState.nextAutoClickAt - os.clock())
		if remaining <= 0.05 then
			autoClickCooldownLabel.Text = "Cooldown: klik sekarang"
			return
		end

		autoClickCooldownLabel.Text = string.format("Cooldown: %.1f detik", remaining)
	end

	local function updateInputLogLabel()
		local inputLog = _G.NightsForestInputLog
		local message = inputLog and inputLog.lastMessage or "Belum ada log klik."
		inputLogLabel.Text = "Log klik: " .. tostring(message)
	end

	local function updateFlyInfoLabel()
		if not flyState.enabled then
			flyInfoLabel.Text = "Status fly: mati"
			return
		end

		if flyState.suppressedByNearbyPlayer then
			flyInfoLabel.Text = string.format("Status fly: normal, player %.1f stud", flyState.nearbyPlayerDistance)
			return
		end

		flyInfoLabel.Text = string.format("Status fly: aktif, radius %.0f", flyState.playerSafeRadius)
	end

	local function getBaseWalkSpeed()
		return utilityState.baseWalkSpeed
	end

	local function getForwardRunSpeed()
		return utilityState.forwardRunSpeed
	end

	local function getPlayerSafeRadius()
		return flyState.playerSafeRadius
	end

	local function applyHumanoidFlightState(humanoid, enabled)
		if not humanoid then
			return
		end

		humanoid.AutoRotate = not enabled
		humanoid.PlatformStand = false
		if enabled then
			if humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
				humanoid:ChangeState(Enum.HumanoidStateType.Physics)
			end
		elseif humanoid:GetState() == Enum.HumanoidStateType.Physics then
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
	end

	local function applyGroundMovementSpeed(moveInput)
		local humanoid = getHumanoid()
		if not humanoid then
			return
		end

		if flyState.enabled and not flyState.suppressedByNearbyPlayer then
			utilityState.lastGroundSpeed = nil
			return
		end

		local baseSpeed = getBaseWalkSpeed()
		local runSpeed = getForwardRunSpeed()
		local forwardAmount = math.clamp(-moveInput.Z, 0, 1)
		local targetSpeed = baseSpeed + ((runSpeed - baseSpeed) * forwardAmount)

		if utilityState.lastGroundSpeed and math.abs(utilityState.lastGroundSpeed - targetSpeed) < 0.05 then
			return
		end

		humanoid.WalkSpeed = targetSpeed
		utilityState.lastGroundSpeed = targetSpeed
	end

	local function updateFlyButton()
		setButtonState(flyButton, flyState.enabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		touchControls.Visible = isTouchDevice and flyState.enabled and not destroyed
		updateFlyInfoLabel()
	end

	local function updateLockHeightButton()
		setButtonState(lockHeightButton, flyState.lockHeightEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
	end

	local function updateDiveBelowButton()
		setButtonState(diveBelowButton, flyState.diveBelowEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
		touchDive.Text = flyState.diveBelowEnabled and "ON" or "D"
		touchDive.BackgroundColor3 = flyState.diveBelowEnabled and Color3.fromRGB(44, 150, 97) or Color3.fromRGB(18, 24, 34)
		updateFlyInfoLabel()
	end

	local function updateNoclipButton()
		setButtonState(noclipButton, flyState.noclipEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
	end

	local function updateAntiAfkButton()
		setButtonState(antiAfkButton, utilityState.antiAfkEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
	end

	local function updateAutoClickButton()
		setButtonState(autoClickButton, utilityState.autoClickEnabled, Color3.fromRGB(44, 150, 97), Color3.fromRGB(120, 52, 52))
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

	local function captureOriginCoordinate()
		if originCoordinate then
			return originCoordinate
		end

		local rootPart = getRootPart()
		if not rootPart then
			return nil
		end

		originCoordinate = rootPart.Position
		return originCoordinate
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

	local function performAntiAfkMovement()
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local camera = workspace.CurrentCamera
		if not humanoid or not rootPart or not camera then
			return
		end

		local forward = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		local right = Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z)
		if forward.Magnitude <= 0 then
			forward = Vector3.zAxis
		else
			forward = forward.Unit
		end
		if right.Magnitude <= 0 then
			right = Vector3.xAxis
		else
			right = right.Unit
		end

		-- Gerakan pendek 4 arah untuk meniru stick analog.
		for _, direction in ipairs({forward, right, -forward, -right}) do
			humanoid:Move(direction, false)
			task.wait(0.12)
		end
		humanoid:Move(Vector3.zero, false)
	end

	local function refreshSavedCoordinateRows()
		for _, child in ipairs(savedContainer:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		local startPoint = captureOriginCoordinate()
		if startPoint then
			local originRow = Instance.new("Frame")
			originRow.Name = "OriginCoordinate"
			originRow.Size = UDim2.new(1, 0, 0, 34)
			originRow.BackgroundTransparency = 1
			originRow.LayoutOrder = 0
			originRow.Parent = savedContainer

			local originLabel = Instance.new("TextLabel")
			originLabel.Size = UDim2.new(1, -64, 1, 0)
			originLabel.BackgroundTransparency = 1
			originLabel.Text = string.format("Start Point  |  %.1f, %.1f, %.1f", startPoint.X, startPoint.Y, startPoint.Z)
			originLabel.TextXAlignment = Enum.TextXAlignment.Left
			originLabel.TextColor3 = Color3.fromRGB(255, 225, 150)
			originLabel.TextSize = 12
			originLabel.Font = Enum.Font.GothamMedium
			originLabel.Parent = originRow

			local backButton = createActionButton("BackToStart", "Back", Color3.fromRGB(188, 132, 42))
			backButton.Size = UDim2.fromOffset(54, 28)
			backButton.Position = UDim2.new(1, -54, 0.5, -14)
			backButton.Parent = originRow

			connect(backButton.MouseButton1Click, function()
				fillCoordinateBoxes(startPoint)
				teleportToPosition(startPoint)
				setStatus("Kembali ke Start Point.", false)
			end)
		end

		for index, position in ipairs(savedCoordinates) do
			local row = Instance.new("Frame")
			row.Name = "Coord" .. index
			row.Size = UDim2.new(1, 0, 0, 34)
			row.BackgroundTransparency = 1
			row.LayoutOrder = index + 1
			row.Parent = savedContainer

			local rowLabel = Instance.new("TextLabel")
			rowLabel.Size = UDim2.new(1, -126, 1, 0)
			rowLabel.BackgroundTransparency = 1
			rowLabel.Text = string.format("Coordinate %d  |  %.1f, %.1f, %.1f", index, position.X, position.Y, position.Z)
			rowLabel.TextXAlignment = Enum.TextXAlignment.Left
			rowLabel.TextColor3 = Color3.fromRGB(232, 236, 240)
			rowLabel.TextSize = 12
			rowLabel.Font = Enum.Font.Gotham
			rowLabel.Parent = row

			local useButton = createActionButton("Use", "Go", Color3.fromRGB(46, 138, 90))
			useButton.Size = UDim2.fromOffset(54, 28)
			useButton.Position = UDim2.new(1, -112, 0.5, -14)
			useButton.Parent = row

			local deleteButton = createActionButton("Delete", "Del", Color3.fromRGB(148, 58, 58))
			deleteButton.Size = UDim2.fromOffset(46, 28)
			deleteButton.Position = UDim2.new(1, -50, 0.5, -14)
			deleteButton.Parent = row

			connect(useButton.MouseButton1Click, function()
				fillCoordinateBoxes(position)
				teleportToPosition(position)
			end)

			connect(deleteButton.MouseButton1Click, function()
				table.remove(savedCoordinates, index)
				refreshSavedCoordinateRows()
				setStatus(string.format("Coordinate %d dihapus.", index), false)
				updateSavedSectionHeight()
			end)
		end

		updateSavedSectionHeight()
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
		touchControls.Position = compact and UDim2.new(1, -138, 0.5, -160) or UDim2.new(1, -144, 0.5, -168)
	end

	local function getActiveLockHeightOffset()
		return flyState.lockHeightOffset
	end

	local function getFlySpeed()
		return flyState.speed
	end

	local function getAutoClickInterval()
		local parsed = sanitizeNumber(autoClickBox.Text)
		if parsed and parsed > 0 then
			utilityState.autoClickInterval = parsed
			return parsed
		end

		autoClickBox.Text = tostring(utilityState.autoClickInterval)
		return utilityState.autoClickInterval
	end

	local function commitNumericBox(box, currentValue, minValue, integerOnly)
		local parsed = sanitizeNumber(box.Text)
		if parsed and parsed >= minValue then
			currentValue = integerOnly and math.floor(parsed + 0.5) or parsed
			box.Text = integerOnly and string.format("%.0f", currentValue) or string.format("%.2f", currentValue)
			return currentValue
		end

		box.Text = integerOnly and string.format("%.0f", currentValue) or string.format("%.2f", currentValue)
		return currentValue
	end

	local function getNearestOtherPlayerDistance(rootPart)
		local nearestDistance = math.huge
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= localPlayer then
				local character = player.Character
				local otherRoot = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if otherRoot and humanoid and humanoid.Health > 0 then
					local distance = (otherRoot.Position - rootPart.Position).Magnitude
					if distance < nearestDistance then
						nearestDistance = distance
					end
				end
			end
		end

		return nearestDistance
	end

	local function updateFlySuppression(rootPart)
		local now = os.clock()
		if now >= loopState.nextPlayerDistanceProbeAt then
			loopState.nextPlayerDistanceProbeAt = now + playerDistanceProbeInterval
			flyState.nearbyPlayerDistance = getNearestOtherPlayerDistance(rootPart)
		end

		local shouldSuppress = flyState.enabled and flyState.nearbyPlayerDistance <= getPlayerSafeRadius()
		if shouldSuppress == flyState.suppressedByNearbyPlayer then
			return
		end

		flyState.suppressedByNearbyPlayer = shouldSuppress

		local humanoid = getHumanoid()
		local currentRootPart = rootPart or getRootPart()
		applyHumanoidFlightState(humanoid, flyState.enabled and not shouldSuppress)
		if currentRootPart then
			currentRootPart.AssemblyLinearVelocity = Vector3.zero
			currentRootPart.AssemblyAngularVelocity = Vector3.zero
			if not shouldSuppress then
				flyState.targetHeight = currentRootPart.Position.Y
			end
		end

		applyNoclipState()
		setStatus(
			shouldSuppress and string.format("Fly kembali normal karena player dekat (%.1f stud).", flyState.nearbyPlayerDistance)
				or "Player lain sudah jauh, fly kembali aktif.",
			false
		)
		updateFlyInfoLabel()
	end

	local function performAutoClick()
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(0, 0)
		local clickPosition = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
		local inputLog = _G.NightsForestInputLog

		if inputLog then
			inputLog.lastAutoClickAt = os.clock()
			inputLog.lastAutoClickSource = "Main.client.lua:auto_click"
			inputLog.lastMessage = "auto click men-trigger RequestAttack"
		end
		print("[Main] Auto click men-trigger RequestAttack.")

		if attackRemote then
			attackRemote:FireServer()
		end

		VirtualUser:CaptureController()
		VirtualUser:Button1Down(clickPosition, camera and camera.CFrame or CFrame.new())
		task.wait()
		VirtualUser:Button1Up(clickPosition, camera and camera.CFrame or CFrame.new())
	end

	local function stopAutoClick()
		utilityState.autoClickEnabled = false
		utilityState.autoClickToken += 1
		utilityState.nextAutoClickAt = 0
		updateAutoClickButton()
		updateAutoClickCooldownLabel()
	end

	local function startAutoClick()
		local token = utilityState.autoClickToken + 1
		utilityState.autoClickToken = token
		utilityState.autoClickEnabled = true
		local waitTime = getAutoClickInterval()
		utilityState.nextAutoClickAt = os.clock() + waitTime
		updateAutoClickButton()
		updateAutoClickCooldownLabel()

		task.spawn(function()
			while not destroyed and utilityState.autoClickEnabled and utilityState.autoClickToken == token do
				local elapsed = 0
				while elapsed < waitTime and not destroyed and utilityState.autoClickEnabled and utilityState.autoClickToken == token do
					local step = math.min(0.25, waitTime - elapsed)
					task.wait(step)
					elapsed += step
				end

				if destroyed or not utilityState.autoClickEnabled or utilityState.autoClickToken ~= token then
					break
				end

				performAutoClick()
				waitTime = getAutoClickInterval()
				utilityState.nextAutoClickAt = os.clock() + waitTime
				updateAutoClickCooldownLabel()
			end
		end)
	end

	local function setFlyEnabled(enabled)
		flyState.enabled = enabled
		flyState.velocity = Vector3.zero
		invalidateGroundProbe()
		loopState.nextPlayerDistanceProbeAt = 0

		local humanoid = getHumanoid()
		local rootPart = getRootPart()
		applyHumanoidFlightState(humanoid, enabled and not flyState.suppressedByNearbyPlayer)

		if enabled and rootPart then
			flyState.suppressedByNearbyPlayer = false
			flyState.nearbyPlayerDistance = math.huge
			flyState.targetHeight = rootPart.Position.Y
			flyState.lastVerticalInput = 0
		else
			flyState.targetHeight = nil
			flyState.lockHeightEnabled = false
			flyState.diveBelowEnabled = false
			flyState.suppressedByNearbyPlayer = false
			flyState.nearbyPlayerDistance = math.huge
		end

		if not enabled and rootPart then
			rootPart.AssemblyLinearVelocity = Vector3.zero
			rootPart.AssemblyAngularVelocity = Vector3.zero
		end

		updateFlyButton()
		updateLockHeightButton()
		updateDiveBelowButton()
		updateFlyInfoLabel()
	end

	local function setNoclipEnabled(enabled)
		flyState.noclipEnabled = enabled
		applyNoclipState()
		loopState.nextNoclipRefreshAt = 0
		updateNoclipButton()
		updateFlyInfoLabel()
	end

	local function getGroundLockHeight(rootPart, character)
		getActiveLockHeightOffset()
		return refreshGroundProbe(rootPart, character)
	end

	local function toggleDiveBelow()
		if not flyState.enabled then
			setStatus("Aktifkan fly dulu untuk memakai dive below.", true)
			return
		end

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
	end

	local function resetUtility()
		savedCoordinates = {}
		refreshSavedCoordinateRows()

		for key in pairs(movementState) do
			movementState[key] = 0
		end

		xBox.Text = ""
		yBox.Text = ""
		zBox.Text = ""
		flyState.speed = defaultFlySpeed
		flySpeedBox.Text = tostring(defaultFlySpeed)
		flyState.playerSafeRadius = defaultPlayerSafeRadius
		playerRadiusBox.Text = tostring(defaultPlayerSafeRadius)
		flyState.lockHeightOffset = defaultLockHeightOffset
		lockHeightBox.Text = tostring(defaultLockHeightOffset)
		utilityState.baseWalkSpeed = defaultWalkSpeed
		utilityState.forwardRunSpeed = defaultForwardRunSpeed
		utilityState.lastGroundSpeed = nil
		walkSpeedBox.Text = tostring(defaultWalkSpeed)
		runSpeedBox.Text = tostring(defaultForwardRunSpeed)
		stopAutoClick()
		utilityState.antiAfkEnabled = true
		autoClickBox.Text = tostring(utilityState.autoClickInterval)
		setFlyEnabled(false)
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.WalkSpeed = utilityState.baseWalkSpeed
			utilityState.lastGroundSpeed = humanoid.WalkSpeed
		end
		setNoclipEnabled(false)
		updateAntiAfkButton()
		updateFlyInfoLabel()
		setStatus("Execute di-reset.", false)
	end

	local function destroyUtility()
		if destroyed then
			return
		end

		destroyed = true
		stopAutoClick()
		setFlyEnabled(false)
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.WalkSpeed = getBaseWalkSpeed()
		end

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
		flyState.speed = commitNumericBox(flySpeedBox, flyState.speed, 1, true)
		flyState.playerSafeRadius = commitNumericBox(playerRadiusBox, flyState.playerSafeRadius, 1, true)
		setFlyEnabled(not flyState.enabled)
		setStatus(flyState.enabled and "Fly aktif." or "Fly dimatikan.", false)
	end)

	connect(noclipButton.MouseButton1Click, function()
		setNoclipEnabled(not flyState.noclipEnabled)
		setStatus(flyState.noclipEnabled and "Noclip aktif." or "Noclip dimatikan.", false)
	end)

	connect(lockHeightButton.MouseButton1Click, function()
		if not flyState.enabled then
			setStatus("Aktifkan fly dulu untuk memakai lock height.", true)
			return
		end

		local previousOffset = flyState.lockHeightOffset
		flyState.lockHeightOffset = commitNumericBox(lockHeightBox, flyState.lockHeightOffset, 1, true)
		if previousOffset ~= flyState.lockHeightOffset then
			invalidateGroundProbe()
		end
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
		toggleDiveBelow()
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
		refreshSavedCoordinateRows()
		setStatus(string.format("Coordinate %d tersimpan.", index), false)
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

	connect(flySpeedBox.FocusLost, function()
		flyState.speed = commitNumericBox(flySpeedBox, flyState.speed, 1, true)
	end)

	connect(walkSpeedBox.FocusLost, function()
		utilityState.baseWalkSpeed = commitNumericBox(walkSpeedBox, utilityState.baseWalkSpeed, 1, true)
		utilityState.forwardRunSpeed = math.max(utilityState.forwardRunSpeed, utilityState.baseWalkSpeed)
		runSpeedBox.Text = string.format("%.0f", utilityState.forwardRunSpeed)
		utilityState.lastGroundSpeed = nil
	end)

	connect(runSpeedBox.FocusLost, function()
		utilityState.forwardRunSpeed = math.max(
			utilityState.baseWalkSpeed,
			commitNumericBox(runSpeedBox, utilityState.forwardRunSpeed, 1, true)
		)
		runSpeedBox.Text = string.format("%.0f", utilityState.forwardRunSpeed)
		utilityState.lastGroundSpeed = nil
	end)

	connect(lockHeightBox.FocusLost, function()
		local previousOffset = flyState.lockHeightOffset
		flyState.lockHeightOffset = commitNumericBox(lockHeightBox, flyState.lockHeightOffset, 1, true)
		if previousOffset ~= flyState.lockHeightOffset then
			invalidateGroundProbe()
		end
	end)

	connect(playerRadiusBox.FocusLost, function()
		flyState.playerSafeRadius = commitNumericBox(playerRadiusBox, flyState.playerSafeRadius, 1, true)
		loopState.nextPlayerDistanceProbeAt = 0
		updateFlyInfoLabel()
	end)

	connect(autoClickBox.FocusLost, function()
		getAutoClickInterval()
		updateAutoClickCooldownLabel()
	end)

	connect(antiAfkButton.MouseButton1Click, function()
		utilityState.antiAfkEnabled = not utilityState.antiAfkEnabled
		updateAntiAfkButton()
		setStatus(utilityState.antiAfkEnabled and "Anti AFK aktif." or "Anti AFK dimatikan.", false)
		sendNotification(utilityState.antiAfkEnabled and "Anti AFK aktif" or "Anti AFK nonaktif")
	end)

	connect(autoClickButton.MouseButton1Click, function()
		local interval = getAutoClickInterval()
		if utilityState.autoClickEnabled then
			stopAutoClick()
			setStatus("Auto click dimatikan.", false)
			sendNotification("Auto click nonaktif")
			return
		end

		startAutoClick()
		setStatus(string.format("Auto click aktif. Interval %.1f detik.", interval), false)
		sendNotification(string.format("Auto click aktif (%.1f detik)", interval))
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
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid")
		humanoid.WalkSpeed = getBaseWalkSpeed()
		applyHumanoidFlightState(humanoid, flyState.enabled and not flyState.suppressedByNearbyPlayer)
		utilityState.lastGroundSpeed = humanoid.WalkSpeed
		rebuildCharacterPartsCache(character)
		applyNoclipState()
		invalidateGroundProbe()
		originCoordinate = nil
		captureOriginCoordinate()
		refreshSavedCoordinateRows()

		if flyState.enabled then
			task.defer(function()
				if not destroyed then
					setFlyEnabled(true)
				end
			end)
		end
	end)

	connect(touchDive.MouseButton1Click, function()
		toggleDiveBelow()
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

	connect(localPlayer.Idled, function()
		if destroyed or not utilityState.antiAfkEnabled then
			return
		end

		performAntiAfkMovement()
	end)

	connect(workspace:GetPropertyChangedSignal("CurrentCamera"), resizeResponsive)
	connect(savedList:GetPropertyChangedSignal("AbsoluteContentSize"), updateSavedSectionHeight)
	connect(listLayout:GetPropertyChangedSignal("AbsoluteContentSize"), updateContentCanvas)

	connect(RunService.Heartbeat, function(deltaTime)
		local moveInput = getPlayerMoveVector()
		applyGroundMovementSpeed(moveInput)

		local now = os.clock()
		if now >= loopState.nextHudRefreshAt then
			loopState.nextHudRefreshAt = now + hudRefreshInterval
			updateAutoClickCooldownLabel()
			updateInputLogLabel()
		end

		if flyState.noclipEnabled and now >= loopState.nextNoclipRefreshAt then
			loopState.nextNoclipRefreshAt = now + noclipRefreshInterval
			applyNoclipState()
		end

		if destroyed or not flyState.enabled then
			-- utility features still continue below
		else
			local character = localPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local camera = workspace.CurrentCamera
			if rootPart and humanoid and camera then
				updateFlySuppression(rootPart)
				if flyState.suppressedByNearbyPlayer then
					return
				end

				applyHumanoidFlightState(humanoid, true)
				flyState.targetHeight = flyState.targetHeight or rootPart.Position.Y

				local verticalInput = movementState.up - movementState.down
				if verticalInput == 0 and flyState.lastVerticalInput ~= 0 then
					flyState.targetHeight = rootPart.Position.Y
					flyState.velocity = Vector3.new(flyState.velocity.X, 0, flyState.velocity.Z)
				end
				flyState.lastVerticalInput = verticalInput

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

				local horizontalMoveVector
				if moveInput.Magnitude > analogDeadzone then
					local humanoidMove = humanoid.MoveDirection
					horizontalMoveVector = Vector3.new(humanoidMove.X, 0, humanoidMove.Z)
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
				if math.abs(altitudeError) < 0.35 and verticalInput == 0 and not flyState.lockHeightEnabled and not flyState.diveBelowEnabled then
					verticalVelocity = 0
				end
				local targetVelocity = horizontalMoveVector * flyState.speed + Vector3.yAxis * verticalVelocity
				local blendAlpha = math.clamp(deltaTime * (horizontalMoveVector == Vector3.zero and 24 or 14), 0, 1)
				flyState.velocity = flyState.velocity:Lerp(targetVelocity, blendAlpha)
				rootPart.AssemblyAngularVelocity = Vector3.zero
				if horizontalMoveVector == Vector3.zero then
					flyState.velocity = Vector3.new(0, flyState.velocity.Y, 0)
				end
				rootPart.AssemblyLinearVelocity = flyState.velocity

				local cameraLook = camera.CFrame.LookVector
				local flatLook = Vector3.new(cameraLook.X, 0, cameraLook.Z)
				if flatLook.Magnitude > 0.05 then
					rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + flatLook.Unit, Vector3.yAxis)
				end
			end
		end
	end)

	rebuildCharacterPartsCache(localPlayer.Character)
	applyNoclipState()
	local currentHumanoid = getHumanoid()
	if currentHumanoid then
		currentHumanoid.WalkSpeed = getBaseWalkSpeed()
		utilityState.lastGroundSpeed = currentHumanoid.WalkSpeed
	end
	task.defer(function()
		if not destroyed then
			refreshSavedCoordinateRows()
		end
	end)
	updateContentCanvas()
	resizeResponsive()
	updateFlyButton()
	updateNoclipButton()
	updateLockHeightButton()
	updateDiveBelowButton()
	updateAntiAfkButton()
	updateAutoClickButton()
	updateAutoClickCooldownLabel()
	updateInputLogLabel()
	setPanelVisible(false)
end

bootstrap()
