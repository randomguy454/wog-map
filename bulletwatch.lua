--=====================================================================
--  BULLETWATCH v1.1 (fixed)
--  Purpose: capture weapon-related remote traffic in Wings of Glory
--  Layout : compact draggable CoreGui panel, live feed
--
--  Red rows = call fired while trigger held
--  Gray rows = call args contain weapon keywords
--=====================================================================

print("[BulletWatch] v1.1 booting")

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then
    print("[BulletWatch] no LocalPlayer")
    return
end

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local CFG = {
    MAX_ROWS = 40,
    KEYWORDS = {
        "fire", "shoot", "shot", "gun", "bullet", "cannon",
        "missile", "bomb", "ordnance", "rocket",
        "hit", "damage", "kill", "died", "death",
        "explode", "impact", "projectile", "ammo", "weapon",
        "spawn", "lock", "flare", "countermeasure", "chaff",
    },
    KEYWORD_CHECK_DEPTH = 3,
}

---------------------------------------------------------------------
-- STATE (all forward declarations first)
---------------------------------------------------------------------

local captureLog = {}
local captureCount = 0
local isFiring = false
local lastRender = 0

local UI_refresh = nil   -- assigned later by UI section

---------------------------------------------------------------------
-- FIRING DETECTION
---------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.KeyCode == Enum.KeyCode.Space then
        isFiring = true
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.KeyCode == Enum.KeyCode.Space then
        isFiring = false
    end
end)

---------------------------------------------------------------------
-- KEYWORD MATCHING
---------------------------------------------------------------------

local function containsKeyword(value, depth)
    if depth > CFG.KEYWORD_CHECK_DEPTH then
        return nil
    end

    local t = type(value)
    if t == "string" then
        local lower = value:lower()
        for _, kw in ipairs(CFG.KEYWORDS) do
            if lower:find(kw, 1, true) then
                return kw
            end
        end
        return nil
    elseif t == "number" or t == "boolean" then
        return nil
    elseif t == "Instance" then
        local lower = value.Name:lower()
        for _, kw in ipairs(CFG.KEYWORDS) do
            if lower:find(kw, 1, true) then
                return kw
            end
        end
        return nil
    elseif t == "table" then
        for _, v in pairs(value) do
            local hit = containsKeyword(v, depth + 1)
            if hit then
                return hit
            end
        end
        return nil
    end
    return nil
end

---------------------------------------------------------------------
-- ARG SNAPSHOT (light)
---------------------------------------------------------------------

local function snapArg(v, depth)
    if depth > 2 then
        return "{...}"
    end
    local t = typeof(v)
    if t == "string" then
        if #v > 40 then
            return v:sub(1, 40) .. "..."
        end
        return v
    elseif t == "number" then
        return tostring(v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "Instance" then
        return v.Name
    elseif t == "Vector3" then
        return string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z)
    elseif t == "CFrame" then
        local p = v.Position
        return string.format("CF(%.0f,%.0f,%.0f)", p.X, p.Y, p.Z)
    elseif t == "table" then
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 4 then
                table.insert(parts, "...")
                break
            end
            table.insert(parts, tostring(k) .. "=" .. snapArg(val, depth + 1))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        return t
    end
end

---------------------------------------------------------------------
-- HOOK
---------------------------------------------------------------------

local ok, mt = pcall(getrawmetatable, game)
if not ok or not mt then
    print("[BulletWatch] no metatable access; cannot hook")
    return
end

local oldNamecall = mt.__namecall
if type(oldNamecall) ~= "function" then
    print("[BulletWatch] no __namecall")
    return
end

local function shouldLog(method, args, count)
    if method ~= "InvokeServer" and method ~= "FireServer" then
        return false
    end

    if isFiring then
        return true
    end

    for i = 1, count do
        if containsKeyword(args[i], 0) then
            return true
        end
    end
    return false
end

local function recordCall(self, method, args, count)
    captureCount = captureCount + 1

    local prev = {}
    for i = 1, math.min(count, 3) do
        table.insert(prev, snapArg(args[i], 0))
    end

    local entry = {
        id = captureCount,
        time = os.clock(),
        method = method,
        remoteName = self.Name,
        remotePath = self:GetFullName(),
        whileFiring = isFiring,
        preview = table.concat(prev, " | "),
    }

    table.insert(captureLog, entry)
    if #captureLog > 500 then
        table.remove(captureLog, 1)
    end

    if UI_refresh then
        local okR, errR = pcall(UI_refresh, entry)
        if not okR then
            print("[BulletWatch] render error: " .. tostring(errR))
        end
    end
end

local replacement

if type(newcclosure) == "function" then
    replacement = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = { ... }
        local count = select("#", ...)
        if shouldLog(method, args, count) then
            local okC, errC = pcall(recordCall, self, method, args, count)
            if not okC then
                print("[BulletWatch] record error: " .. tostring(errC))
            end
        end
        return oldNamecall(self, ...)
    end)
else
    replacement = function(self, ...)
        local method = getnamecallmethod()
        local args = { ... }
        local count = select("#", ...)
        if shouldLog(method, args, count) then
            local okC, errC = pcall(recordCall, self, method, args, count)
            if not okC then
                print("[BulletWatch] record error: " .. tostring(errC))
            end
        end
        return oldNamecall(self, ...)
    end
end

setreadonly(mt, false)
mt.__namecall = replacement
setreadonly(mt, true)

print("[BulletWatch] hook installed")

---------------------------------------------------------------------
-- UI
---------------------------------------------------------------------

local T = {
    bg      = Color3.fromRGB(16, 16, 22),
    card    = Color3.fromRGB(28, 28, 36),
    border  = Color3.fromRGB(46, 46, 58),
    fire    = Color3.fromRGB(232, 92, 92),
    text    = Color3.fromRGB(238, 238, 242),
    dim     = Color3.fromRGB(156, 156, 170),
    faint   = Color3.fromRGB(104, 104, 118),
    rowbg   = Color3.fromRGB(35, 35, 45),
    rowFire = Color3.fromRGB(60, 35, 35),
}

local function new(class, props)
    local inst = Instance.new(class)
    local parent = nil
    for k, v in pairs(props or {}) do
        if k == "Parent" then
            parent = v
        else
            inst[k] = v
        end
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local gui = new("ScreenGui", {
    Name = "BulletWatch",
    ResetOnSpawn = false,
    DisplayOrder = 997,
    IgnoreGuiInset = true,
})

local containerOk = pcall(function()
    gui.Parent = game:GetService("CoreGui")
end)
if not containerOk then
    gui.Parent = player:WaitForChild("PlayerGui")
    print("[BulletWatch] using PlayerGui")
end

local panel = new("Frame", {
    Size = UDim2.fromOffset(420, 300),
    Position = UDim2.new(0, 20, 0, 20),
    BackgroundColor3 = T.card,
    BorderSizePixel = 0,
    Active = true,
    Draggable = true,
    Parent = gui,
})
new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = panel })
new("UIStroke", { Color = T.border, Thickness = 1, Parent = panel })

local titleBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = T.bg,
    BorderSizePixel = 0,
    Parent = panel,
})
new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = titleBar })

new("TextLabel", {
    Size = UDim2.new(1, -100, 1, 0),
    Position = UDim2.new(0, 10, 0, 0),
    BackgroundTransparency = 1,
    Text = "BulletWatch",
    TextColor3 = T.text,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = titleBar,
})

local fireIndicator = new("TextLabel", {
    Size = UDim2.fromOffset(80, 16),
    Position = UDim2.new(1, -130, 0, 6),
    BackgroundColor3 = T.rowbg,
    BorderSizePixel = 0,
    Text = " idle",
    TextColor3 = T.faint,
    TextSize = 10,
    Font = Enum.Font.Gotham,
    Parent = titleBar,
})
new("UICorner", { CornerRadius = UDim.new(0, 4), Parent = fireIndicator })

local clrBtn = new("TextButton", {
    Size = UDim2.fromOffset(40, 20),
    Position = UDim2.new(1, -46, 0, 4),
    BackgroundColor3 = T.fire,
    BorderSizePixel = 0,
    Text = "CLR",
    TextColor3 = T.text,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    Parent = titleBar,
})
new("UICorner", { CornerRadius = UDim.new(0, 4), Parent = clrBtn })

local feed = new("ScrollingFrame", {
    Size = UDim2.new(1, -16, 1, -44),
    Position = UDim2.new(0, 8, 0, 34),
    BackgroundColor3 = T.bg,
    BorderSizePixel = 0,
    ScrollBarThickness = 5,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    Parent = panel,
})
new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = feed })

new("UIListLayout", {
    Padding = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
    Parent = feed,
})

-- pooled rows
local rows = {}

local function makeRow()
    local row = new("Frame", {
        Size = UDim2.new(1, -6, 0, 30),
        BackgroundColor3 = T.rowbg,
        BorderSizePixel = 0,
        Parent = feed,
    })
    new("UICorner", { CornerRadius = UDim.new(0, 3), Parent = row })

    local line1 = new("TextLabel", {
        Size = UDim2.new(1, -8, 0, 14),
        Position = UDim2.new(0, 5, 0, 1),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = T.text,
        TextSize = 11,
        Font = Enum.Font.GothamMedium,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })

    local line2 = new("TextLabel", {
        Size = UDim2.new(1, -8, 0, 13),
        Position = UDim2.new(0, 5, 0, 15),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = T.dim,
        TextSize = 10,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })

    row.line1 = line1
    row.line2 = line2
    return row
end

for i = 1, CFG.MAX_ROWS do
    local row = makeRow()
    row.Visible = false
    table.insert(rows, row)
end

local function renderRows()
    local n = #captureLog
    local start = math.max(1, n - CFG.MAX_ROWS + 1)
    local idx = 0

    for i = n, start, -1 do
        idx = idx + 1
        local row = rows[idx]
        if not row then
            break
        end

        local entry = captureLog[i]

        row.Visible = true
        row.LayoutOrder = entry.id

        local tag = entry.whileFiring and "FIRE" or "kw"
        row.line1.Text = string.format("#%d [%s] %s:%s",
            entry.id, tag, entry.remoteName, entry.method)
        row.line2.Text = entry.preview or ""

        if entry.whileFiring then
            row.BackgroundColor3 = T.rowFire
            row.line1.TextColor3 = T.fire
        else
            row.BackgroundColor3 = T.rowbg
            row.line1.TextColor3 = T.text
        end
    end

    for i = idx + 1, #rows do
        rows[i].Visible = false
    end

    feed.CanvasSize = UDim2.new(0, 0, 0, idx * 32)
    feed.CanvasPosition = Vector2.new(0, 0)
end

-- throttled refresh assignment
UI_refresh = function()
    local now = os.clock()
    if now - lastRender > 0.1 then
        lastRender = now
        renderRows()
    end
end

-- fire indicator loop
task.spawn(function()
    while gui.Parent do
        if isFiring then
            fireIndicator.Text = " FIRING"
            fireIndicator.TextColor3 = T.fire
            fireIndicator.BackgroundColor3 = T.rowFire
        else
            fireIndicator.Text = " idle"
            fireIndicator.TextColor3 = T.faint
            fireIndicator.BackgroundColor3 = T.rowbg
        end
        task.wait(0.1)
    end
end)

clrBtn.MouseButton1Click:Connect(function()
    captureLog = {}
    captureCount = 0
    renderRows()
end)

renderRows()

print("[BulletWatch] active")
print("[BulletWatch] fly, hold fire, launch missiles - watch red rows")
