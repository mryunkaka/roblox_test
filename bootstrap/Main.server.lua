local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local function ensureFolder(parent, name)
    local folder = parent:FindFirstChild(name)
    if folder then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = parent
    return folder
end

local function ensureRemote(parent, name)
    local remote = parent:FindFirstChild(name)
    if remote then
        return remote
    end

    remote = Instance.new("RemoteEvent")
    remote.Name = name
    remote.Parent = parent
    return remote
end

local remotes = ensureFolder(ReplicatedStorage, "Remotes")
ensureFolder(ReplicatedStorage, "Shared")

local attackRemote = ensureRemote(remotes, "RequestAttack")
local teleportRemote = ensureRemote(remotes, "RequestTeleport")

local CombatConfig = require(ReplicatedStorage.Shared.CombatConfig)
local InventoryTypes = require(ReplicatedStorage.Shared.InventoryTypes)

local attackCooldowns = {}
local teleportCooldowns = {}
local inventories = {}

local function getCharacterRoot(player)
    local character = player.Character
    if not character then
        return nil, nil
    end

    return character, character:FindFirstChild("HumanoidRootPart")
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

local function getInventory(player)
    inventories[player] = inventories[player] or {}
    return inventories[player]
end

local function addItem(player, itemName, amount)
    local definition = InventoryTypes[itemName]
    if not definition then
        return false, "unknown item"
    end

    local inventory = getInventory(player)
    local current = inventory[itemName] or 0
    inventory[itemName] = math.min(current + amount, definition.stackSize)
    return true, inventory[itemName]
end

attackRemote.OnServerEvent:Connect(function(player)
    local now = os.clock()
    local lastAttackAt = attackCooldowns[player]
    if lastAttackAt and now - lastAttackAt < CombatConfig.LightAttackCooldown then
        return
    end

    local character, root = getCharacterRoot(player)
    if not character or not root then
        return
    end

    attackCooldowns[player] = now

    local target = getNearbyTarget(root.Position, character)
    if not target then
        return
    end

    local humanoid = target:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid:TakeDamage(CombatConfig.LightAttackDamage)
    end
end)

teleportRemote.OnServerEvent:Connect(function(player, nodeName)
    if type(nodeName) ~= "string" or not CombatConfig.AllowedTeleportNodes[nodeName] then
        return
    end

    local now = os.clock()
    local lastTeleportAt = teleportCooldowns[player]
    if lastTeleportAt and now - lastTeleportAt < CombatConfig.TeleportCooldown then
        return
    end

    local _, root = getCharacterRoot(player)
    local targetCFrame = getNodeCFrame(nodeName)
    if not root or not targetCFrame then
        return
    end

    teleportCooldowns[player] = now
    root.CFrame = targetCFrame + Vector3.new(0, 3, 0)
end)

Players.PlayerAdded:Connect(function(player)
    inventories[player] = {}
    addItem(player, "Torch", 1)
end)

Players.PlayerRemoving:Connect(function(player)
    attackCooldowns[player] = nil
    teleportCooldowns[player] = nil
    inventories[player] = nil
end)
