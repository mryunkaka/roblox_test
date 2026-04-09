local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackRemote = remotes:WaitForChild("RequestAttack")

local lastAttackAt = 0
local cooldown = 0.55

local function hasGuiAtPosition(container, x, y)
    local ok, objects = pcall(function()
        return container:GetGuiObjectsAtPosition(x, y)
    end)

    return ok and objects and #objects > 0
end

local function isClickOnGui()
    local mouseLocation = UserInputService:GetMouseLocation()
    local x = mouseLocation.X
    local y = mouseLocation.Y

    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    if playerGui and hasGuiAtPosition(playerGui, x, y) then
        return true
    end

    if hasGuiAtPosition(CoreGui, x, y) then
        return true
    end

    return false
end

local function requestAttack()
    local now = os.clock()
    if now - lastAttackAt < cooldown then
        return
    end

    lastAttackAt = now
    attackRemote:FireServer()
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if isClickOnGui() then
            return
        end

        requestAttack()
    end
end)
