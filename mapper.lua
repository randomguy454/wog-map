-- SIMPLYSPY MAPPER v3 BULLETPROOF
-- first line of execution: identity check
print("[MAPPER] v3 bulletproof booting")

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local CFG = {
    MAX_CHILDREN_PER_NODE = 0,     -- 0 = uncapped
    YIELD_EVERY = 500,
    PROPERTY_DUMP = true,
    GUI_TEXT = true,
    MAX_TEXT_LEN = 120,
    DEDUP_SIBLINGS = true,
    DEDUP_MAX_SAMPLE = 3,

    FILES = {
        FULL      = "wogmap.txt",
        REMOTES   = "wog_remotes.txt",
        SCRIPTS   = "wog_scripts.txt",
        GUITEXT   = "wog_guitext.txt",
        VALUES    = "wog_values.txt",
        STRUCTURE = "wog_structure.txt",
        SUMMARY   = "wog_summary.txt",
    },
}

---------------------------------------------------------------------
-- SAFE PRIMITIVES (everything routes through these)
---------------------------------------------------------------------

local function safe(f, ...)
    local ok, result = pcall(f, ...)
    if ok then
        return result
    end
    return nil
end

local function safeYield()
    if task and task.wait then
        task.wait()
    else
        wait()
    end
end

local function canWrite()
    return type(writefile) == "function"
end

local function canClip()
    return type(setclipboard) == "function"
end

---------------------------------------------------------------------
-- BUFFERS
---------------------------------------------------------------------

local report = {}
local structureOut = {}
local remotesByContainer = {}
local scriptsByLocation = {}
local guiTexts = {}
local valueObjects = {}

local lineCount = 0
local sectionStart = {}
local sectionEnd = {}

local function emit(line)
    lineCount = lineCount + 1
    table.insert(report, line)
    table.insert(structureOut, line)
end

local function beginSection(tag, title)
    sectionStart[tag] = lineCount + 1
    emit("")
    emit("======== [" .. tag .. "] " .. title .. " ========")
end

local function endSection(tag)
    sectionEnd[tag] = lineCount
end

---------------------------------------------------------------------
-- STATS
---------------------------------------------------------------------

local stats = {
    nodes = 0,
    remotes = 0,
    scripts = 0,
    parts = 0,
    tools = 0,
    maxDepth = 0,
    errors = 0,
}

---------------------------------------------------------------------
-- CLASSIFICATION (fully pcalled: a locked-down instance cannot
-- crash the walker)
---------------------------------------------------------------------

local function classify(inst)
    local r = safe(function()
        if inst:IsA("RemoteEvent") then return "REMOTE_EVENT"
        elseif inst:IsA("RemoteFunction") then return "REMOTE_FUNCTION"
        elseif inst:IsA("UnreliableRemoteEvent") then return "REMOTE_UNRELIABLE"
        elseif inst:IsA("LocalScript") then return "LOCAL_SCRIPT"
        elseif inst:IsA("ModuleScript") then return "MODULE_SCRIPT"
        elseif inst:IsA("Script") then return "SERVER_SCRIPT"
        elseif inst:IsA("Tool") then return "TOOL"
        elseif inst:IsA("BasePart") then return "PART"
        elseif inst:IsA("Humanoid") then return "HUMANOID"
        end
        return nil
    end)
    return r
end

---------------------------------------------------------------------
-- COLLECTORS
---------------------------------------------------------------------

local function containerPathOf(inst)
    return safe(function()
        local parent = inst.Parent
        if not parent then return "(no parent)" end
        if parent == game then return "game" end
        return parent:GetFullName()
    end) or "?"
end

local function noteRemote(inst, kind)
    stats.remotes = stats.remotes + 1
    local container = containerPathOf(inst)
    if not remotesByContainer[container] then
        remotesByContainer[container] = {}
    end
    local name = safe(function() return inst.Name end) or "?"
    table.insert(remotesByContainer[container],
        name .. "  " .. kind)
end

local function locationLabelOf(inst)
    local path = safe(function()
        return inst:GetFullName()
    end) or ""
    if path:find("^Workspace") then
        return "Workspace"
    elseif path:find("^ReplicatedStorage") then
        return "ReplicatedStorage"
    elseif path:find("^ReplicatedFirst") then
        return "ReplicatedFirst"
    elseif path:find("^StarterPlayer") then
        return "StarterPlayer"
    elseif path:find("^StarterGui") then
        return "StarterGui"
    elseif path:find("PlayerGui") then
        return "PlayerGui (live)"
    else
        return "Other"
    end
end

local function noteScript(inst, kind)
    stats.scripts = stats.scripts + 1
    local location = locationLabelOf(inst)
    if not scriptsByLocation[location] then
        scriptsByLocation[location] = {}
    end
    local path = safe(function()
        return inst:GetFullName()
    end) or "?"
    table.insert(scriptsByLocation[location],
        path .. "  " .. kind)
end

local function noteGuiText(inst)
    local text = safe(function() return inst.Text end)
    if not text or #text == 0 or text == "Label" then
        return
    end
    if #text > CFG.MAX_TEXT_LEN then
        text = text:sub(1, CFG.MAX_TEXT_LEN) .. "..."
    end
    local path = safe(function()
        return inst:GetFullName()
    end) or "?"
    table.insert(guiTexts,
        path .. ': "' .. text .. '"')
end

local function noteValueObject(inst)
    local v = safe(function() return inst.Value end)
    if v == nil then
        return
    end
    local s = tostring(v)
    if #s > CFG.MAX_TEXT_LEN then
        s = s:sub(1, CFG.MAX_TEXT_LEN) .. "..."
    end
    local path = safe(function()
        return inst:GetFullName()
    end) or "?"
    local cls = safe(function() return inst.ClassName end)
        or "Value"
    table.insert(valueObjects,
        path .. "  <" .. cls .. "> = " .. s)
end

---------------------------------------------------------------------
-- PROPERTY DUMP
---------------------------------------------------------------------

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
            table.insert(props,
                prop .. "=" .. tostring(v.Name))
        end
    end

    local isPart = safe(function() return inst:IsA("BasePart") end)
    local isHumanoid = safe(function()
        return inst:IsA("Humanoid") end)

    if isPart then
        try("Anchored")
        try("CanCollide")
        try("Transparency")
    elseif isHumanoid then
        try("Health")
        try("MaxHealth")
        try("WalkSpeed")
    end

    local attrs = safe(inst.GetAttributes, inst)
    if type(attrs) == "table" then
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
-- THE WALKER (bulletproof: every access pcalled, every error
-- counted, the walk never stops for a bad instance)
---------------------------------------------------------------------

local function walk(inst, depth, prefix)
    stats.nodes = stats.nodes + 1
    if depth > stats.maxDepth then
        stats.maxDepth = depth
    end

    -- Name: safe access.
    local name = safe(function() return inst.Name end) or "?"

    -- Class: safe access.
    local className = safe(function()
        return inst.ClassName
    end) or "?"

    local kind = classify(inst)

    -- Categorize.
    if kind == "REMOTE_EVENT" or kind == "REMOTE_FUNCTION"
        or kind == "REMOTE_UNRELIABLE" then
        noteRemote(inst, kind)
    elseif kind == "LOCAL_SCRIPT" or kind == "MODULE_SCRIPT"
        or kind == "SERVER_SCRIPT" then
        noteScript(inst, kind)
    elseif kind == "PART" then
        stats.parts = stats.parts + 1
    elseif kind == "TOOL" then
        stats.tools = stats.tools + 1
    end

    local isStringValue = safe(function()
        return inst:IsA("StringValue") or inst:IsA("BoolValue")
            or inst:IsA("NumberValue") or inst:IsA("IntValue")
    end)
    if isStringValue then
        noteValueObject(inst)
    end

    local isTextish = safe(function()
        return inst:IsA("TextLabel")
            or inst:IsA("TextButton")
            or inst:IsA("TextBox")
    end)
    if isTextish then
        noteGuiText(inst)
    end

    -- Structure line.
    local label = name

    if CFG.PROPERTY_DUMP then
        local ok, props = pcall(interestingProps, inst)
        if ok and type(props) == "table" and #props > 0 then
            label = label .. "  {"
                .. table.concat(props, ", ") .. "}"
        end
    end

    local line = prefix .. label .. " <" .. className .. ">"
    if kind then
        line = line .. " [" .. kind .. "]"
    end
    emit(line)

    if CFG.GUI_TEXT and isTextish then
        local text = safe(function() return inst.Text end)
        if text and #text > 0 and text ~= "Label" then
            if #text > CFG.MAX_TEXT_LEN then
                text = text:sub(1, CFG.MAX_TEXT_LEN) .. "..."
            end
            emit(prefix .. '   TEXT: "' .. text .. '"')
        end
    end

    -- Children: safe access.
    local children = safe(function()
        return inst:GetChildren()
    end)
    if type(children) ~= "table" or #children == 0 then
        return
    end

    -- Sibling dedup.
    if CFG.DEDUP_SIBLINGS then
        local groups = {}
        local order = {}
        for _, child in ipairs(children) do
            local childName = safe(function()
                return child.Name
            end) or "?"
            local childClass = safe(function()
                return child.ClassName
            end) or "?"
            local key = childName .. "\0" .. childClass
            if not groups[key] then
                groups[key] = {
                    name = childName,
                    list = {},
                }
                table.insert(order, key)
            end
            table.insert(groups[key].list, child)
        end

        for _, key in ipairs(order) do
            local group = groups[key]
            local count = #group.list

            if count > CFG.DEDUP_MAX_SAMPLE then
                for s = 1, CFG.DEDUP_MAX_SAMPLE do
                    walk(group.list[s], depth + 1,
                        prefix .. "   ")
                end
                emit(prefix .. "   ... x"
                    .. (count - CFG.DEDUP_MAX_SAMPLE)
                    .. " more [" .. group.name .. "]")

                for s = CFG.DEDUP_MAX_SAMPLE + 1, count do
                    local sibling = group.list[s]
                    local k2 = classify(sibling)
                    if k2 == "REMOTE_EVENT"
                        or k2 == "REMOTE_FUNCTION"
                        or k2 == "REMOTE_UNRELIABLE" then
                        noteRemote(sibling, k2)
                    elseif k2 == "LOCAL_SCRIPT"
                        or k2 == "MODULE_SCRIPT"
                        or k2 == "SERVER_SCRIPT" then
                        noteScript(sibling, k2)
                    elseif k2 == "PART" then
                        stats.parts = stats.parts + 1
                    end
                end
            else
                for s = 1, count do
                    walk(group.list[s], depth + 1,
                        prefix .. "   ")
                end
            end

            if stats.nodes % CFG.YIELD_EVERY < 2 then
                safeYield()
            end
        end
    else
        for _, child in ipairs(children) do
            walk(child, depth + 1, prefix .. "   ")
            if stats.nodes % CFG.YIELD_EVERY < 2 then
                safeYield()
            end
        end
    end
end

---------------------------------------------------------------------
-- SCANS
---------------------------------------------------------------------

local player = safe(function()
    return game:GetService("Players").LocalPlayer
end)

local function scanService(tag, title, svcName)
    local svc = safe(game.GetService, game, svcName)
    if not svc then
        return
    end

    beginSection(tag, title)
    local children = safe(function()
        return svc:GetChildren()
    end)
    if type(children) == "table" then
        emit("(" .. #children .. " children)")
        for _, child in ipairs(children) do
            walk(child, 1, "   ")
        end
    end
    endSection(tag)
    print("[MAPPER] scanned " .. svcName
        .. " (" .. stats.nodes .. " nodes)")
end

-- Signal-first order.
scanService("RS", "REPLICATED STORAGE", "ReplicatedStorage")
scanService("RF", "REPLICATED FIRST", "ReplicatedFirst")
scanService("SP", "STARTER PLAYER", "StarterPlayer")
scanService("SG", "STARTER GUI", "StarterGui")

beginSection("WS", "WORKSPACE")
local wsChildren = safe(function()
    return workspace:GetChildren()
end)
if type(wsChildren) == "table" then
    emit("(" .. #wsChildren .. " children)")
    for _, child in ipairs(wsChildren) do
        walk(child, 1, "   ")
    end
end
endSection("WS")
print("[MAPPER] scanned Workspace ("
    .. stats.nodes .. " nodes)")

if player then
    beginSection("CH", "CHARACTER")
    local char = safe(function() return player.Character end)
    if char then
        walk(char, 1, "   ")
    end
    endSection("CH")

    beginSection("PG", "PLAYER GUI (live)")
    local pg = safe(function()
        return player:FindFirstChild("PlayerGui")
    end)
    if pg then
        for _, gui in ipairs(pg:GetChildren()) do
            walk(gui, 1, "   ")
        end
    end
    endSection("PG")

    beginSection("LS", "LEADERSTATS")
    local ls = safe(function()
        return player:FindFirstChild("leaderstats")
    end)
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            local val = safe(function() return v.Value end)
            emit("   " .. tostring(safe(function()
                return v.Name end)) .. " = "
                .. tostring(val))
        end
    end
    endSection("LS")
end

---------------------------------------------------------------------
-- BUILD PER-FILE OUTPUTS
---------------------------------------------------------------------

-- REMOTES FILE
local remotesOut = {}
table.insert(remotesOut, "==== REMOTES ====")
table.insert(remotesOut,
    "total: " .. stats.remotes)
table.insert(remotesOut, "")

local containerNames = {}
for container in pairs(remotesByContainer) do
    table.insert(containerNames, container)
end
table.sort(containerNames)

local flatRemotes = {}
for _, container in ipairs(containerNames) do
    local list = remotesByContainer[container]
    table.sort(list)
    table.insert(remotesOut,
        "-- container: " .. container .. " (" .. #list .. ")")
    for _, entry in ipairs(list) do
        table.insert(remotesOut, "   " .. entry)
        table.insert(flatRemotes, container .. " :: " .. entry)
    end
    table.insert(remotesOut, "")
end
table.sort(flatRemotes)

-- SCRIPTS FILE
local scriptsOut = {}
table.insert(scriptsOut, "==== SCRIPTS ====")
table.insert(scriptsOut,
    "total: " .. stats.scripts)
table.insert(scriptsOut, "")

local locationNames = {}
for location in pairs(scriptsByLocation) do
    table.insert(locationNames, location)
end
table.sort(locationNames)

local flatScripts = {}
for _, location in ipairs(locationNames) do
    local list = scriptsByLocation[location]
    table.sort(list)
    table.insert(scriptsOut,
        "-- location: " .. location .. " (" .. #list .. ")")
    for _, entry in ipairs(list) do
        table.insert(scriptsOut, "   " .. entry)
        table.insert(flatScripts, entry)
    end
    table.insert(scriptsOut, "")
end
table.sort(flatScripts)

-- GUI TEXT FILE
local guiTextOut = {}
table.insert(guiTextOut, "==== GUI TEXT ====")
table.insert(guiTextOut,
    "total: " .. #guiTexts)
table.insert(guiTextOut, "")
table.sort(guiTexts)
for _, entry in ipairs(guiTexts) do
    table.insert(guiTextOut, entry)
end

-- VALUES FILE
local valuesOut = {}
table.insert(valuesOut, "==== VALUE OBJECTS ====")
table.insert(valuesOut,
    "total: " .. #valueObjects)
table.insert(valuesOut, "")
table.sort(valueObjects)
for _, entry in ipairs(valueObjects) do
    table.insert(valuesOut, entry)
end

-- STRUCTURE FILE header
table.insert(structureOut, 1, "==== STRUCTURE ====")
table.insert(structureOut, 2, "")
table.insert(structureOut, 3, "(deduped tree)")

-- SUMMARY FILE
local summaryOut = {}
table.insert(summaryOut, "==== SUMMARY ====")
table.insert(summaryOut, "nodes: " .. stats.nodes)
table.insert(summaryOut, "remotes: " .. stats.remotes)
table.insert(summaryOut, "scripts: " .. stats.scripts)
table.insert(summaryOut, "parts: " .. stats.parts)
table.insert(summaryOut, "tools: " .. stats.tools)
table.insert(summaryOut, "max depth: " .. stats.maxDepth)
table.insert(summaryOut, "")
table.insert(summaryOut, "== ALL REMOTES ==")
for _, entry in ipairs(flatRemotes) do
    table.insert(summaryOut, entry)
end
table.insert(summaryOut, "")
table.insert(summaryOut, "== ALL SCRIPTS ==")
for _, entry in ipairs(flatScripts) do
    table.insert(summaryOut, entry)
end

---------------------------------------------------------------------
-- WRITE FILES
---------------------------------------------------------------------

local function writeOut(filename, buffer)
    if not canWrite() then
        return false
    end
    local content = table.concat(buffer, "\n")
    local ok = pcall(writefile, filename, content)
    if ok then
        print("[MAPPER] wrote " .. filename
            .. " (" .. #buffer .. " lines)")
    else
        print("[MAPPER] FAILED to write " .. filename)
    end
    return ok
end

writeOut(CFG.FILES.FULL, report)
writeOut(CFG.FILES.REMOTES, remotesOut)
writeOut(CFG.FILES.SCRIPTS, scriptsOut)
writeOut(CFG.FILES.GUITEXT, guiTextOut)
writeOut(CFG.FILES.VALUES, valuesOut)
writeOut(CFG.FILES.STRUCTURE, structureOut)
writeOut(CFG.FILES.SUMMARY, summaryOut)

---------------------------------------------------------------------
-- INTERACTIVE COMMANDS
---------------------------------------------------------------------

MAP = {}

function MAP.get(tag)
    local s, e = sectionStart[tag], sectionEnd[tag]
    if not s then
        print("unknown section: " .. tostring(tag))
        return
    end
    for i = s, (e or lineCount) do
        print(report[i])
    end
end

function MAP.copy(tag)
    local s, e = sectionStart[tag], sectionEnd[tag]
    if not s then
        print("unknown section: " .. tostring(tag))
        return
    end
    if not canClip() then
        print("no clipboard; use MAP.get")
        return
    end
    local parts = {}
    for i = s, (e or lineCount) do
        table.insert(parts, report[i])
    end
    setclipboard(table.concat(parts, "\n"))
    print("section [" .. tag .. "] copied")
end

function MAP.find(text)
    local needle = tostring(text):lower()
    local hits = 0
    for i, line in ipairs(report) do
        if line:lower():find(needle, 1, true) then
            print(string.format("%5d: %s", i, line))
            hits = hits + 1
            if hits >= 100 then
                print("(stopping at 100)")
                break
            end
        end
    end
    if hits == 0 then
        print("no matches: " .. tostring(text))
    end
end

function MAP.stats()
    print(string.format(
        "nodes=%d remotes=%d scripts=%d parts=%d depth=%d",
        stats.nodes, stats.remotes, stats.scripts,
        stats.parts, stats.maxDepth))
end

function MAP.save()
    writeOut(CFG.FILES.FULL, report)
    writeOut(CFG.FILES.REMOTES, remotesOut)
    writeOut(CFG.FILES.SCRIPTS, scriptsOut)
    writeOut(CFG.FILES.GUITEXT, guiTextOut)
    writeOut(CFG.FILES.VALUES, valuesOut)
    writeOut(CFG.FILES.STRUCTURE, structureOut)
    writeOut(CFG.FILES.SUMMARY, summaryOut)
    print("files rewritten")
end

---------------------------------------------------------------------
-- DONE
---------------------------------------------------------------------

print("[MAPPER] v3 complete: " .. stats.nodes .. " nodes, "
    .. stats.remotes .. " remotes, "
    .. stats.scripts .. " scripts")

if canClip() then
    setclipboard(table.concat({
        "nodes: " .. stats.nodes,
        "remotes: " .. stats.remotes,
        "scripts: " .. stats.scripts,
        "parts: " .. stats.parts,
        "max depth: " .. stats.maxDepth,
    }, "\n"))
    print("[MAPPER] summary copied to clipboard")
end

print("[MAPPER] commands: MAP.get('RS') MAP.copy('RS')")
print("[MAPPER]           MAP.find('Gun') MAP.stats()")
