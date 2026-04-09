local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	return
end

local coreGuiContainer = nil
pcall(function()
	coreGuiContainer = game:GetService("CoreGui")
end)

local existingGui = nil
for _, container in ipairs({coreGuiContainer, localPlayer:FindFirstChildOfClass("PlayerGui")}) do
	if container then
		local found = container:FindFirstChild("StandaloneMovementGui")
		if found then
			existingGui = found
			break
		end
	end
end

if existingGui then
	existingGui:Destroy()
end

local guiParent = localPlayer:FindFirstChildOfClass("PlayerGui")
if coreGuiContainer then
	guiParent = coreGuiContainer
end

if not guiParent then
	return
end

local flySpeed = 64
local flySmoothing = 0.18
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
}

local flyKeys = {
	[Enum.KeyCode.W] = "forward",
	[Enum.KeyCode.S] = "backward",
	[Enum.KeyCode.A] = "left",
	[Enum.KeyCode.D] = "right",
	[Enum.KeyCode.Space] = "up",
	[Enum.KeyCode.LeftControl] = "down",
}

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
toggleButton.Size = UDim2.fromOffset(112, 32)
toggleButton.Position = UDim2.new(1, -132, 0.5, -16)
toggleButton.BackgroundColor3 = Color3.fromRGB(18, 24, 34)
toggleButton.BackgroundTransparency = 0.2
toggleButton.BorderSizePixel = 0
toggleButton.Text = "Open Panel"
toggleButton.TextColor3 = Color3.fromRGB(235, 240, 245)
toggleButton.TextSize = 14
toggleButton.Font = Enum.Font.GothamMedium
toggleButton.Parent = screenGui

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 10)
toggleCorner.Parent = toggleButton

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.Size = UDim2.fromOffset(300, 252)
panel.Position = UDim2.new(1, -320, 0.5, -126)
panel.BackgroundColor3 = Color3.fromRGB(15, 20, 28)
panel.BackgroundTransparency = 0.18
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
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundTransparency = 1
titleBar.Parent = panel

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -80, 1, 0)
titleLabel.Position = UDim2.fromOffset(14, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Movement Panel"
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.TextColor3 = Color3.fromRGB(240, 244, 248)
titleLabel.TextSize = 16
titleLabel.Font = Enum.Font.GothamSemibold
titleLabel.Parent = titleBar

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.Size = UDim2.fromOffset(58, 24)
closeButton.Position = UDim2.new(1, -68, 0.5, -12)
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

local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -20, 1, -48)
content.Position = UDim2.fromOffset(10, 38)
content.BackgroundTransparency = 1
content.Parent = panel

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
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame

	return frame
end

local flySection = createSection(66)
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

local flyHint = Instance.new("TextLabel")
flyHint.Size = UDim2.new(1, -24, 0, 18)
flyHint.Position = UDim2.fromOffset(12, 34)
flyHint.BackgroundTransparency = 1
flyHint.Text = "WASD + Space + Ctrl"
flyHint.TextXAlignment = Enum.TextXAlignment.Left
flyHint.TextColor3 = Color3.fromRGB(172, 182, 196)
flyHint.TextSize = 12
flyHint.Font = Enum.Font.Gotham
flyHint.Parent = flySection

local flyButton = Instance.new("TextButton")
flyButton.Name = "FlyToggle"
flyButton.Size = UDim2.fromOffset(82, 32)
flyButton.Position = UDim2.new(1, -94, 0.5, -16)
flyButton.BackgroundColor3 = Color3.fromRGB(120, 52, 52)
flyButton.BorderSizePixel = 0
flyButton.Text = "OFF"
flyButton.TextColor3 = Color3.fromRGB(245, 248, 250)
flyButton.TextSize = 14
flyButton.Font = Enum.Font.GothamBold
flyButton.Parent = flySection

local flyCorner = Instance.new("UICorner")
flyCorner.CornerRadius = UDim.new(0, 10)
flyCorner.Parent = flyButton

local teleportSection = createSection(126)
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
	local box = Instance.new("TextBox")
	box.Name = name
	box.Size = UDim2.new(1 / 3, -4, 1, 0)
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
actionRow.Size = UDim2.new(1, -24, 0, 32)
actionRow.Position = UDim2.fromOffset(12, 100)
actionRow.BackgroundTransparency = 1
actionRow.Parent = teleportSection

local actionLayout = Instance.new("UIListLayout")
actionLayout.FillDirection = Enum.FillDirection.Horizontal
actionLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
actionLayout.SortOrder = Enum.SortOrder.LayoutOrder
actionLayout.Padding = UDim.new(0, 8)
actionLayout.Parent = actionRow

local function createActionButton(name, text, color)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.new(0.5, -4, 1, 0)
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

local getCoordinateButton = createActionButton("GetCoordinateButton", "Get Coordinate", Color3.fromRGB(44, 95, 155))
getCoordinateButton.Parent = actionRow

local teleportButton = createActionButton("TeleportButton", "Teleport", Color3.fromRGB(46, 138, 90))
teleportButton.Parent = actionRow

local function setPanelVisible(visible)
	panel.Visible = visible
	toggleButton.Text = visible and "Hide Panel" or "Open Panel"
end

local function updateFlyButton()
	flyButton.Text = flyState.enabled and "ON" or "OFF"
	flyButton.BackgroundColor3 = flyState.enabled and Color3.fromRGB(44, 150, 97) or Color3.fromRGB(120, 52, 52)
end

local function setStatus(text, isError)
	statusLabel.Text = text
	statusLabel.TextColor3 = isError and Color3.fromRGB(255, 122, 122) or Color3.fromRGB(172, 182, 196)
end

local dragging = false
local dragStart
local panelStart

titleBar.InputBegan:Connect(function(input)
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

UserInputService.InputChanged:Connect(function(input)
	if not dragging then
		return
	end

	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	local delta = input.Position - dragStart
	panel.Position = UDim2.new(
		panelStart.X.Scale,
		panelStart.X.Offset + delta.X,
		panelStart.Y.Scale,
		panelStart.Y.Offset + delta.Y
	)
end)

local function setFlyEnabled(enabled)
	flyState.enabled = enabled
	flyState.velocity = Vector3.zero
	updateFlyButton()

	local humanoid = getHumanoid()
	if humanoid then
		humanoid.PlatformStand = enabled
	end

	if not enabled then
		local rootPart = getRootPart()
		if rootPart then
			rootPart.AssemblyLinearVelocity = Vector3.zero
		end
	end
end

local function fillCoordinateBoxes(position)
	xBox.Text = string.format("%.2f", position.X)
	yBox.Text = string.format("%.2f", position.Y)
	zBox.Text = string.format("%.2f", position.Z)
end

toggleButton.MouseButton1Click:Connect(function()
	setPanelVisible(not panel.Visible)
end)

closeButton.MouseButton1Click:Connect(function()
	setPanelVisible(false)
end)

flyButton.MouseButton1Click:Connect(function()
	setFlyEnabled(not flyState.enabled)
	setStatus(flyState.enabled and "Fly aktif." or "Fly dimatikan.", false)
end)

getCoordinateButton.MouseButton1Click:Connect(function()
	local rootPart = getRootPart()
	if not rootPart then
		setStatus("Karakter belum siap.", true)
		return
	end

	fillCoordinateBoxes(rootPart.Position)
	setStatus("Koordinat saat ini berhasil diambil.", false)
end)

teleportButton.MouseButton1Click:Connect(function()
	local x = sanitizeNumber(xBox.Text)
	local y = sanitizeNumber(yBox.Text)
	local z = sanitizeNumber(zBox.Text)

	if not x or not y or not z then
		setStatus("Koordinat tidak valid. Isi X, Y, Z dengan angka.", true)
		return
	end

	local rootPart = getRootPart()
	if not rootPart then
		setStatus("Karakter belum siap.", true)
		return
	end

	rootPart.CFrame = CFrame.new(x, y, z)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	setStatus("Teleport berhasil.", false)
end)

localPlayer.CharacterAdded:Connect(function(character)
	character:WaitForChild("HumanoidRootPart")

	if flyState.enabled then
		task.defer(function()
			setFlyEnabled(true)
		end)
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end

	local movementKey = flyKeys[input.KeyCode]
	if movementKey then
		movementState[movementKey] = 1
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local movementKey = flyKeys[input.KeyCode]
	if movementKey then
		movementState[movementKey] = 0
	end
end)

RunService.RenderStepped:Connect(function()
	if not flyState.enabled then
		return
	end

	local character = localPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if not rootPart or not humanoid or not camera then
		return
	end

	humanoid.PlatformStand = true

	local moveVector = camera.CFrame.LookVector * (movementState.forward - movementState.backward)
		+ camera.CFrame.RightVector * (movementState.right - movementState.left)
		+ Vector3.yAxis * (movementState.up - movementState.down)

	if moveVector.Magnitude > 0 then
		moveVector = moveVector.Unit
	end

	local targetVelocity = moveVector * flySpeed
	flyState.velocity = flyState.velocity:Lerp(targetVelocity, flySmoothing)
	rootPart.AssemblyLinearVelocity = flyState.velocity

	local lookVector = camera.CFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude > 0 then
		rootPart.CFrame = CFrame.new(rootPart.Position, rootPart.Position + flatLook.Unit)
	end
end)

updateFlyButton()
setPanelVisible(false)
