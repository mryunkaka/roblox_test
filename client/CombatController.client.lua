local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackRemote = remotes:WaitForChild("RequestAttack")

local lastAttackAt = 0
local cooldown = 0.55

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
        requestAttack()
    end
end)
