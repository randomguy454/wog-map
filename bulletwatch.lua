--=====================================================================
--  BULLETWATCH v1.0
--  Purpose: capture weapon-related remote traffic in Wings of Glory
--  Layout : compact draggable CoreGui panel, live feed, verb filter
--
--  What it catches:
--    - Every InvokeServer/FireServer call whose arg1 looks like a
--      weapon/fire/hit/damage verb, OR whose any arg mentions
--      Gun/Bullet/Missile/Bomb/Damage/Hit
--    - Every call made while you are actively firing (context flag)
--
--  Controls:
--    Feed auto-scrolls. "CLR" clears. Filter box narrows the feed.
--=====================================================================

print("[BulletWatch] booting")

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
if not player then
    print("[BulletWatch] no LocalPlayer")
    return
end

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local CFG = {
    MAX_ROWS = 40,          -- visible feed rows
    KEYWORDS = {
        "fire", "shoot", "shot", "gun", "bullet", "cannon",
        "missile", "bomb", "ordnance", "rocket",
        "hit", "damage", "kill", "died", "death",
        "explode", "impact", "projectile", "ammo", "weapon",
        "spawn", "lock", "flare", "countermeasure", "chaff",
    },
    KEYWORD_CHECK_DEPTH = 3, -- how deep into table args to search
    CONTEXT_WINDOW = 2.0,    -- seconds after keypress to tag "while firing"
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local captureLog = {}     -- all captured entries
local captureCount = 0
local isFiring = false    -- true while mouse/space held
local lastFireTime = 0

-- firing detection: mouse button 1, space, and the mobile fire button
local UserInputService = game:GetService("UserInputService")

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.KeyCode == Enum.KeyCode.Space then
        isFiring = true
        lastFireTime = os.clock()
    end
end)

UserInputService.InputEnded:Connect(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.KeyCode == Enum.KeyCode.Space then
        isFiring = false
    end
end)

---------------------------------------------------------------------
-- KEYWORD MATCHING
---------------------------------------------------------------------
-- Checks a value tree for keyword hits. Returns the matched word
-- or nil.

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
-- SNAPSHOT (light: enough to render, not to round-trip)
---------------------------------------------------------------------

local function snapArg(v, depth)
    if depth > 2 then return "{...}" end
    local t = typeof(v)
    if t == "string" then
        if #v > 40 then return v:sub(1, 40) .. "..." end
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
    -- Only outgoing calls
    if method ~= "InvokeServer" and method ~= "FireServer" then
        return false
    end

    -- Always log calls made while firing (context flag)
    if isFiring then
        return true
    end

    -- Otherwise require a keyword hit in the args
    for i = 1, count do
        if containsKeyword(args[i], 0) then
            return true
        end
    end
    return false
end

local replacement
if type(newcclosure) == "function" then
    replacement = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = { ... }
        local count = select("#", ...)

        if shouldLog(method, args, count) then
            captureCount = captureCount + 1

            local entry = {
                id = captureCount,
                time = os.clock(),
                method = method,
                remoteName = self.Name,
                remotePath = self:GetFullName(),
                whileFiring = isFiring,
                preview = "",
            }

            -- build preview from first few args
            local prev = {}
            for i = 1, math.min(count, 3) do
                table.insert(prev, snapArg(args[i], 0))
            end
            entry.preview = table.concat(prev, " | ")

            table.insert(captureLog, entry)
            if #captureLog > 500 then
                table.remove(captureLog, 1)
            end

            if UI_refresh then
                UI_refresh(entry)
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
            captureCount = captureCount + 1
            local entry = {
                id = captureCount,
                time = os.clock(),
                method = method,
                remoteName = self.Name,
                remotePath = self:GetFullName(),
                whileFiring = isFiring,
                preview = "",
            }
            local prev = {}
            for i = 1, math.min(count, 3) do
                table.insert(prev, snapArg(args[i], 0))
            end
            entry.preview = table.concat(prev, " | ")
            table.insert(captureLog, entry)
            if #captureLog > 500 then
                table.remove(captureLog, 1)
            end
            if UI_refresh then
                UI_refresh(entry)
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
-- UI : compact CoreGui panel
---------------------------------------------------------------------

local T = {
    bg      = Color3.fromRGB(16, 16, 22),
    card    = Color3.fromRGB(28, 28, 36),
    border  = Color3.fromRGB(46, 46, 58),
    accent  = Color3.fromRGB(255, 170, 60),
    fire    = Color3.fromRGB(232, 92, 92),
    normal  = Color3.fromRGB(88, 200, 132),
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
    if parent then inst.Parent = parent end
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

-- Title bar
local titleBar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 28),
    BackgroundColor3 = T.bg,
    BorderSizePixel = 0,
    Parent = panel,
})
new("UICorner", { CornerRadius = UDim.new(0, 8), Parent = titleBar })

new("TextLabel", {
    Size = UDim2.new(1, -90, 1, 0),
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
    Position = UDim2.new(1, -86, 0, 6),
    BackgroundColor3 = T.rowbg,
    BorderSizePixel = 0,
    Text = " idle",
    TextColor3 = T.faint,
    TextSize = 10,
    Font = Enum.Font.Gotham,
    Parent = titleBar,
})
new("UICorner", { CornerRadius = UDim.new(0, 4), Parent = fireIndicator })

-- Fire indicator live update
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

-- Clear button
local clrBtn = new("TextButton", {
    Size = UDim2.fromOffset(40, 20),
    Position = UDim2.new(1, -46, 1, -4),
    BackgroundColor3 = T.fire,
    BorderSizePixel = 0,
    Text = "CLR",
    TextColor3 = T.text,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    Parent = titleBar,
})
new("UICorner", { CornerRadius = UDim.new(0, 4), Parent = clrBtn })

-- Feed
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

-- Rows (pooled: created once, updated in place)
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
    table.insert(rows, makeRow())
end

local function renderRows()
    -- newest at top, pooled rows updated in place
    local n = #captureLog
    local start = math.max(1, n - CFG.MAX_ROWS + 1)
    local idx = 0
    for i = n, start, -1 do
        idx = idx + 1
        local entry = captureLog[i]
        local row = rows[idx]
        if not row then break end

        row.LayoutOrder = entry.id
        row.Visible = true

        local tag = entry.whileFiring and "FIRE" or "kw"
        local remoteLabel = string.format("#%d [%s] %s:%s",
            entry.id, tag, entry.remoteName, entry.method)
        row.line1.Text = remoteLabel
        row.line2.Text = entry.preview or ""

        if entry.whileFiring then
            row.BackgroundColor3 = T.rowFire
            row.line1.TextColor3 = T.fire
        else
            row.BackgroundColor3 = T.rowbg
            row.line1.TextColor3 = T.text
        end
    end

    -- hide unused rows
    for i = idx + 1, #rows do
        rows[i].Visible = false
    end

    feed.CanvasSize = UDim2.new(0, 0, 0, idx * 32)
    -- auto-scroll to top (newest)
    feed.CanvasPosition = Vector2.new(0, 0)
end

-- throttle UI updates
local lastRender = 0
UI_refresh = function(entry)
    local now = os.clock()
    if now - lastRender > 0.1 then
        lastRender = now
        renderRows()
    end
end

clrBtn.MouseButton1Click:Connect(function()
    captureLog = {}
    captureCount = 0
    renderRows()
end)

renderRows()

print("[BulletWatch] active. Fly, fire guns, launch missiles.")
print("[BulletWatch] feed shows weapon-related calls only.")
print("[BulletWatch] red rows = call happened while trigger held")
