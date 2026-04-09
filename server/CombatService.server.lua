local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackRemote = remotes:WaitForChild("RequestAttack")

local cooldowns = {}

local function getCharacterRoot(player)
    local character = player.Character
    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
end

local function getNearbyTarget(originPosition, ignoreModel)
    local nearestModel
    local nearestDistance = CombatConfig.HitRange

    for _, model in Workspace:GetChildren() do
        if model ~= ignoreModel and model:IsA("Model") then
            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart")
            if humanoid and humanoid.Health > 0 and root then
                local distance = (root.Position - originPosition).Magnitude
                if distance <= nearestDistance then
                    nearestModel = model
                    nearestDistance = distance
                end
            end
        end
    end

    return nearestModel
end

attackRemote.OnServerEvent:Connect(function(player)
    local now = os.clock()
    local lastAttackAt = cooldowns[player]
    if lastAttackAt and now - lastAttackAt < CombatConfig.LightAttackCooldown then
        return
    end

    local character = player.Character
    local root = getCharacterRoot(player)
    if not character or not root then
        return
    end

    cooldowns[player] = now

    local target = getNearbyTarget(root.Position, character)
    if not target then
        return
    end

    local humanoid = target:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid:TakeDamage(CombatConfig.LightAttackDamage)
    end
end)

Players.PlayerRemoving:Connect(function(player)
    cooldowns[player] = nil
end)
