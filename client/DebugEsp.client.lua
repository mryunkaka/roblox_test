local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local tracked = {}

local function attachBillboard(instance)
    if tracked[instance] or not instance:IsA("Model") then
        return
    end

    local adornee = instance:FindFirstChild("HumanoidRootPart") or instance.PrimaryPart
    if not adornee then
        return
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "DebugEsp"
    billboard.Size = UDim2.fromOffset(160, 40)
    billboard.StudsOffset = Vector3.new(0, 4, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = adornee

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.TextScaled = true
    label.TextColor3 = Color3.fromRGB(120, 255, 180)
    label.TextStrokeTransparency = 0.3
    label.Text = instance.Name
    label.Parent = billboard

    billboard.Parent = adornee
    tracked[instance] = billboard
end

local function detachBillboard(instance)
    local billboard = tracked[instance]
    if billboard then
        billboard:Destroy()
        tracked[instance] = nil
    end
end

for _, instance in CollectionService:GetTagged("DebugVisible") do
    attachBillboard(instance)
end

CollectionService:GetInstanceAddedSignal("DebugVisible"):Connect(attachBillboard)
CollectionService:GetInstanceRemovedSignal("DebugVisible"):Connect(detachBillboard)

RunService.RenderStepped:Connect(function()
    for instance, billboard in tracked do
        if not instance.Parent then
            billboard:Destroy()
            tracked[instance] = nil
        end
    end
end)
