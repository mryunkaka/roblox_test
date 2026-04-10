local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local attackRemote = remotes:WaitForChild("RequestAttack")

local lastAttackAt = 0
local cooldown = 0.55
local autoClickGraceWindow = 0.35

_G.NightsForestInputLog = _G.NightsForestInputLog or {
    lastAutoClickAt = 0,
    lastAutoClickSource = nil,
    lastMessage = "Belum ada log klik.",
}

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
        return false
    end

    lastAttackAt = now
    attackRemote:FireServer()
    return true
end

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if isClickOnGui() then
            _G.NightsForestInputLog.lastMessage = "klik diblokir karena GUI"
            print("[CombatController] Klik diblokir karena GUI di bawah cursor.")
            return
        end

        local now = os.clock()
        local inputLog = _G.NightsForestInputLog
        local sourceLabel
        if inputLog and now - (inputLog.lastAutoClickAt or 0) <= autoClickGraceWindow then
            sourceLabel = string.format(
                "auto click (%s)",
                tostring(inputLog.lastAutoClickSource or "unknown")
            )
        else
            sourceLabel = string.format(
                "non-autoclick input=%s keyCode=%s position=(%d,%d)",
                tostring(input.UserInputType),
                tostring(input.KeyCode),
                input.Position.X,
                input.Position.Y
            )
        end

        local fired = requestAttack()
        local message = string.format(
            "[CombatController] RequestAttack %s: %s",
            fired and "terkirim" or "tertahan cooldown",
            sourceLabel
        )
        _G.NightsForestInputLog.lastMessage = message
        print(message)
    end
end)
