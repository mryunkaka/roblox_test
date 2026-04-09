local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local teleportRemote = remotes:WaitForChild("RequestTeleport")

local cooldowns = {}

local function getNodeCFrame(nodeName)
    local folder = Workspace:FindFirstChild("TeleportNodes")
    if not folder then
        return nil
    end

    local part = folder:FindFirstChild(nodeName)
    if not part or not part:IsA("BasePart") then
        return nil
    end

    return part.CFrame
end

teleportRemote.OnServerEvent:Connect(function(player, nodeName)
    if type(nodeName) ~= "string" or not CombatConfig.AllowedTeleportNodes[nodeName] then
        return
    end

    local now = os.clock()
    local lastAt = cooldowns[player]
    if lastAt and now - lastAt < CombatConfig.TeleportCooldown then
        return
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local targetCFrame = getNodeCFrame(nodeName)
    if not root or not targetCFrame then
        return
    end

    cooldowns[player] = now
    root.CFrame = targetCFrame + Vector3.new(0, 3, 0)
end)

Players.PlayerRemoving:Connect(function(player)
    cooldowns[player] = nil
end)
