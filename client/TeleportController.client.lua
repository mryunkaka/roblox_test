local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local teleportRemote = remotes:WaitForChild("RequestTeleport")

local keybinds = {
    [Enum.KeyCode.One] = "Camp",
    [Enum.KeyCode.Two] = "WatchTower",
    [Enum.KeyCode.Three] = "River",
    [Enum.KeyCode.Four] = "Cave",
}

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    local targetNode = keybinds[input.KeyCode]
    if targetNode then
        teleportRemote:FireServer(targetNode)
    end
end)
