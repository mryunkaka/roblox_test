local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryTypes = require(ReplicatedStorage.Shared.InventoryTypes)

local inventories = {}

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
    local nextValue = math.min(current + amount, definition.stackSize)
    inventory[itemName] = nextValue
    return true, nextValue
end

local function removeItem(player, itemName, amount)
    local inventory = getInventory(player)
    local current = inventory[itemName] or 0
    if current < amount then
        return false, "not enough items"
    end

    inventory[itemName] = current - amount
    return true, inventory[itemName]
end

Players.PlayerAdded:Connect(function(player)
    inventories[player] = {}
    addItem(player, "Torch", 1)
end)

Players.PlayerRemoving:Connect(function(player)
    inventories[player] = nil
end)

return {
    AddItem = addItem,
    RemoveItem = removeItem,
    GetInventory = getInventory,
}
