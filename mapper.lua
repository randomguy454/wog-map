--=====================================================================
--  PROJECT   : Wings of Glory - Deep Game Mapper
--  FILE      : mapper.lua
--  VERSION   : 0.2.0
--  PURPOSE   : Exhaustive read-only reconnaissance of every
--              service, instance, remote, script, GUI, attribute,
--              and property reachable from the client.
--              Fires nothing. Hooks nothing. Modifies nothing.
--  OUTPUT    : file (wogmap.txt) if writefile available,
--              else clipboard + console (may truncate).
--  LICENSE   : MIT
--=====================================================================

local TAG = "[WOG-Map]"

local function log(msg)
    print(TAG .. " " .. tostring(msg))
end

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local CFG = {
    MAX_CHILDREN_PER_NODE = 200,   -- cap listing per node (0 = uncapped)
    PROPERTY_DUMP = true,          -- dump properties of key instances
    GUI_TEXT = true,               -- dump text content of GUI labels
    MAX_TEXT_LEN = 100,            -- truncate captured text at this length
    DEPTH_UNLIMITED = true,        -- walk full trees
    FILENAME = "wogmap.txt",
}

---------------------------------------------------------------------
-- REPORT BUFFER
---------------------------------------------------------------------

local report = {}
local lineCount = 0

local function emit(line)
    lineCount = lineCount + 1
    table.insert(report, line)
end

local function section(title)
    emit("")
    emit("======== " .. title .. " ========")
end

-- Large reports: print only section headers live; full text goes
-- to file/clipboard. Set to false to print everything live too.
local LIVE_PRINT = false

local origPrint = print
local function livePrint(line)
    if LIVE_PRINT then
        origPrint(TAG .. " " .. line)
    end
end

---------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------

local function safe(f, ...)
    local ok, result = pcall(f, ...)
    if ok then
        return result
    end
    return nil
end

local function classify(inst)
    if inst:IsA("RemoteEvent") then return "REMOTE_EVENT"
    elseif inst:IsA("RemoteFunction") then return "REMOTE_FUNCTION"
    elseif inst:IsA("UnreliableRemoteEvent") then return "REMOTE_UNRELIABLE"
    elseif inst:IsA("LocalScript") then return "LOCAL_SCRIPT"
    elseif inst:IsA("ModuleScript") then return "MODULE_SCRIPT"
    elseif inst:IsA("Script") then return "SERVER_SCRIPT"
    elseif inst:IsA("Tool") then return "TOOL"
    elseif inst:IsA("BasePart") then return "PART"
    elseif inst:IsA("Model") then return "MODEL"
    elseif inst:IsA("Folder") then return "FOLDER"
    elseif inst:IsA("Humanoid") then return "HUMANOID"
    elseif inst:IsA("Sound") then return "SOUND"
    elseif inst:IsA("Camera") then return "CAMERA"
    end
    return nil
end

-- Key properties worth dumping per instance type.
local function interestingProps(inst)
    local props = {}

    local function try(prop)
        local v = safe(function() return inst[prop] end)
        if v == nil then return end
        if type(v) == "string" then
            if #v > CFG.MAX_TEXT_LEN then
                v = v:sub(1, CFG.MAX_TEXT_LEN) .. "..."
            end
            table.insert(props, prop .. "=" .. v)
        elseif type(v) == "number"
            or type(v) == "boolean" then
            table.insert(props, prop .. "=" .. tostring(v))
        elseif type(v) == "Instance" then
            table.insert(props, prop .. "=" .. v.Name)
        end
    end

    if inst:IsA("BasePart") then
        try("Anchored")
        try("CanCollide")
        try("Transparency")
        try("Massless")
    elseif inst:IsA("Humanoid") then
        try("Health")
        try("MaxHealth")
        try("WalkSpeed")
        try("JumpPower")
    elseif inst:IsA("Sound") then
        try("SoundId")
        try("Playing")
    elseif inst:IsA("Tool") then
        try("RequiresHandle")
        try("ToolTip")
    end

    -- Attributes (modern Roblox games use these heavily)
    local attrs = safe(inst.GetAttributes, inst)
    if attrs then
        for k, v in pairs(attrs) do
            local s = tostring(v)
            if #s > CFG.MAX_TEXT_LEN then
                s = s:sub(1, CFG.MAX_TEXT_LEN) .. "..."
            end
            table.insert(props, "@" .. k .. "=" .. s)
        end
    end

    return props
end

---------------------------------------------------------------------
-- DEEP TREE WALKER
---------------------------------------------------------------------

local stats = {
    nodes = 0,
    remotes = 0,
    scripts = 0,
    parts = 0,
    models = 0,
    tools = 0,
    maxDepth = 0,
}

local function walk(inst, depth, prefix)
    stats.nodes = stats.nodes + 1
    if depth > stats.maxDepth then
        stats.maxDepth = depth
    end

    local kind = classify(inst)
    if kind == "REMOTE_EVENT" or kind == "REMOTE_FUNCTION"
        or kind == "REMOTE_UNRELIABLE" then
        stats.remotes = stats.remotes + 1
    elseif kind == "LOCAL_SCRIPT" or kind == "MODULE_SCRIPT"
        or kind == "SERVER_SCRIPT" then
        stats.scripts = stats.scripts + 1
    elseif kind == "PART" then
        stats.parts = stats.parts + 1
    elseif kind == "MODEL" then
        stats.models = stats.models + 1
    elseif kind == "TOOL" then
        stats.tools = stats.tools + 1
    end

    -- Build the line for this instance.
    local label = inst.Name

    if CFG.PROPERTY_DUMP then
        local props = interestingProps(inst)
        if #props > 0 then
            label = label .. "  {" .. table.concat(props, ", ") .. "}"
        end
    end

    local line = prefix .. label .. " <" .. inst.ClassName .. ">"
    if kind then
        line = line .. " [" .. kind .. "]"
    end
    emit(line)

    -- GUI text capture.
    if CFG.GUI_TEXT
        and (inst:IsA("TextLabel") or inst:IsA("TextButton")
            or inst:IsA("TextBox")) then
        local text = safe(function() return inst.Text end)
        if text and #text > 0 and text ~= "Label" then
            if #text > CFG.MAX_TEXT_LEN then
                text = text:sub(1, CFG.MAX_TEXT_LEN) .. "..."
            end
            emit(prefix .. '   TEXT: "' .. text .. '"')
        end
    end

    -- Recurse.
    local children = safe(function() return inst:GetChildren() end)
    if not children then
        return
    end

    local shown = 0
    for _, child in ipairs(children) do
        if CFG.MAX_CHILDREN_PER_NODE > 0
            and shown >= CFG.MAX_CHILDREN_PER_NODE then
            emit(prefix .. "   ... ("
                .. (#children - shown) .. " more hidden)")
            break
        end
        shown = shown + 1
        walk(child, depth + 1, prefix .. "   ")
    end
end

---------------------------------------------------------------------
-- SCAN : ALL SERVICES
---------------------------------------------------------------------

log("scanning services (this may take a moment)...")

local serviceNames = {
    "Workspace", "ReplicatedStorage", "ReplicatedFirst",
    "Lighting", "SoundService", "Teams", "StarterGui",
    "StarterPlayer", "StarterPack", "Chat", "CoreGui",
    "Players",
}

local player = game:GetService("Players").LocalPlayer

for _, svcName in ipairs(serviceNames) do
    local svc = safe(game.GetService, game, svcName)
    if svc then
        section("SERVICE: " .. svcName)
        local children = safe(function() return svc:GetChildren() end)
        if children then
            emit("(" .. #children .. " children)")
            for _, child in ipairs(children) do
                walk(child, 1, "   ")
            end
        end
    end
end

-- Player-specific containers (session-lifetime objects).
if player then
    section("PLAYER: " .. player.Name)
    emit("UserId: " .. tostring(player.UserId))

    local char = player.Character
    if char then
        section("CHARACTER")
        walk(char, 1, "   ")
    end

    local backpack = player:FindFirstChild("Backpack")
    if backpack then
        section("BACKPACK")
        for _, item in ipairs(backpack:GetChildren()) do
            walk(item, 1, "   ")
        end
    end

    local pg = player:FindFirstChild("PlayerGui")
    if pg then
        section("PLAYERGUI")
        for _, gui in ipairs(pg:GetChildren()) do
            walk(gui, 1, "   ")
        end
    end

    local ls = player:FindFirstChild("leaderstats")
    if ls then
        section("LEADERSTATS")
        for _, v in ipairs(ls:GetChildren()) do
            emit("   " .. v.Name .. " = " .. tostring(
                safe(function() return v.Value end)))
        end
    end
end

---------------------------------------------------------------------
-- SCAN : CAMERA
---------------------------------------------------------------------

local cam = safe(function()
    return workspace.CurrentCamera
end)
if cam then
    section("CAMERA")
    local cf = safe(function() return cam.CFrame end)
    if cf then
        local p = cf.Position
        emit(string.format("   position: (%.1f, %.1f, %.1f)",
            p.X, p.Y, p.Z))
    end
    local scriptable = safe(function()
        return cam.CameraType end)
    if scriptable then
        emit("   type: " .. tostring(scriptable))
    end
    for _, child in ipairs(cam:GetChildren() or {}) do
        walk(child, 1, "   ")
    end
end

---------------------------------------------------------------------
-- SUMMARY
---------------------------------------------------------------------

section("SUMMARY")

emit("total nodes walked:  " .. stats.nodes)
emit("max depth reached:  " .. stats.maxDepth)
emit("remotes found:       " .. stats.remotes)
emit("scripts found:       " .. stats.scripts)
emit("parts found:         " .. stats.parts)
emit("models found:        " .. stats.models)
emit("tools found:         " .. stats.tools)
emit("report lines:        " .. lineCount)

---------------------------------------------------------------------
-- OUTPUT
---------------------------------------------------------------------

local full = table.concat(report, "\n")
local bytes = #full

log("map complete: " .. lineCount .. " lines, "
    .. math.floor(bytes / 1024) .. " KB")

if type(writefile) == "function" then
    local ok = pcall(writefile, CFG.FILENAME, full)
    if ok then
        log("written to file: " .. CFG.FILENAME)
        log("read it back with: readfile('" .. CFG.FILENAME .. "')")
        log("(transfer: run readfile and copy in chunks)")
    else
        log("file write failed, falling back to clipboard")
    end
end

if type(setclipboard) == "function" then
    if bytes < 100000 then
        setclipboard(full)
        log("copied to clipboard (" .. bytes .. " bytes)")
    else
        log("report too large for clipboard ("
            .. bytes .. " bytes)")
        if type(writefile) ~= "function" then
            log("WARNING: no file access; report is only in memory")
            log("printing in chunks - run CHUNKS to retrieve")
            -- Chunked retrieval helper:
            _G.WOG_CHUNKS = {
                total = math.ceil(lineCount / 200),
                report = report,
                get = function(self, n)
                    local lo = (n - 1) * 200 + 1
                    local hi = math.min(n * 200, lineCount)
                    local out = {}
                    for i = lo, hi do
                        table.insert(out, report[i])
                    end
                    return table.concat(out, "\n")
                end,
            }
            log("usage: _G.WOG_CHUNKS:get(1) through get("
                .. _G.WOG_CHUNKS.total .. ")")
        end
    end
end
