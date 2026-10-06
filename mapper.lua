--=====================================================================
--=====================================================================
--                                                                    --
--  WINGS OF GLORY - DEEP GAME MAPPER                                 --
--  =================================                                 --
--                                                                    --
--  Exhaustive read-only reconnaissance with multi-file output.       --
--                                                                    --
--  OUTPUT FILES (written to executor workspace folder):              --
--                                                                    --
--    wogmap.txt          full combined report (everything)         --
--    wog_remotes.txt     every RemoteEvent/RemoteFunction with      --
--                        full paths, grouped by container           --
--    wog_scripts.txt     every LocalScript/ModuleScript/Script      --
--                        with full paths, grouped by location       --
--    wog_guitext.txt    every text label/button/box in live GUI     --
--    wog_values.txt     every Value object content (PartOf tags,    --
--                        landing_tire flags, etc)                   --
--    wog_structure.txt  the full workspace/service tree             --
--    wog_summary.txt    the stats + full remote + script lists       --
--                                                                    --
--  INTERACTIVE COMMANDS (after scan):                               --
--    MAP.sections()       list section locations                    --
--    MAP.get(tag)         print a section                           --
--    MAP.copy(tag)        copy a section to clipboard                --
--    MAP.find(text)       search the entire report                  --
--    MAP.stats()          the numbers                                --
--    MAP.save()           rewrite all files                         --
--                                                                    --
--  TARGET    : UNC-compatible executors + Studio                     --
--  LICENSE   : MIT                                                   --
--                                                                    --
--=====================================================================
--=====================================================================

---------------------------------------------------------------------
-- SECTION 1 : BOOTSTRAP
---------------------------------------------------------------------

local TAG = "[WOG-Map]"

local function log(msg)
    print(TAG .. " " .. tostring(msg))
end

---------------------------------------------------------------------
-- SECTION 2 : CONFIGURATION
---------------------------------------------------------------------

local CFG = {
    MAX_CHILDREN_PER_NODE = 0,
    YIELD_EVERY = 500,
    PROPERTY_DUMP = true,
    GUI_TEXT = true,
    MAX_TEXT_LEN = 120,
    DEDUP_SIBLINGS = true,
    DEDUP_MAX_SAMPLE = 3,

    -- Output files
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
-- SECTION 3 : REPORT BUFFERS
---------------------------------------------------------------------
-- One buffer per output file, plus the combined report.

local report = {}        -- combined (wogmap.txt)
local remotesOut = {}   -- wog_remotes.txt
local scriptsOut = {}   -- wog_scripts.txt
local guiTextOut = {}   -- wog_guitext.txt
local valuesOut = {}    -- wog_values.txt
local structureOut = {} -- wog_structure.txt
local summaryOut = {}   -- wog_summary.txt

local lineCount = 0
local sectionStart = {}
local sectionEnd = {}

local function emit(line)
    lineCount = lineCount + 1
    table.insert(report, line)
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
-- SECTION 4 : HELPERS
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
    elseif inst:IsA("Humanoid") then return "HUMANOID"
    end
    return nil
end

---------------------------------------------------------------------
-- SECTION 5 : CATEGORIZED COLLECTION
---------------------------------------------------------------------
-- Every interesting instance is collected into its category list
-- as we walk, so the per-file outputs are complete regardless of
-- where in the tree the instance lives.

local remotesByContainer = {}   -- container path -> {entries}
local scriptsByLocation = {}    -- location label -> {entries}
local guiTexts = {}             -- {path, text}
local valueObjects = []         -- {path, type, value}

local stats = {
    nodes = 0,
    remotes = 0,
    scripts = 0,
    parts = 0,
    tools = 0,
    maxDepth = 0,
}

local function containerPathOf(inst)
    local parent = inst.Parent
    if not parent then
        return "(no parent)"
    end
    if parent == game then
        return "game"
    end
    return parent:GetFullName()
end

local function noteRemote(inst, kind)
    stats.remotes = stats.remotes + 1
    local container = containerPathOf(inst)
    if not remotesByContainer[container] then
        remotesByContainer[container] = {}
    end
    table.insert(remotesByContainer[container],
        string.format("%s  %s", inst.Name, kind))
end

local function locationLabelOf(inst)
    local path = inst:GetFullName()
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
    table.insert(scriptsByLocation[location],
        string.format("%s  %s", inst:GetFullName(), kind))
end

local function noteGuiText(inst)
    local text = safe(function() return inst.Text end)
    if not text or #text == 0 or text == "Label" then
        return
    end
    if #text > CFG.MAX_TEXT_LEN then
        text = text:sub(1, CFG.MAX_TEXT_LEN) .. "..."
    end
    table.insert(guiTexts,
        string.format("%s: \"%s\"", inst:GetFullName(), text))
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
    table.insert(valueObjects, string.format("%s  <%s> = %s",
        inst:GetFullName(), inst.ClassName, s))
end

---------------------------------------------------------------------
-- SECTION 6 : PROPERTY DUMPS
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
        elseif type(v) == "number" or type(v) == "boolean" then
            table.insert(props, prop .. "=" .. tostring(v))
        elseif type(v) == "Instance" then
            table.insert(props, prop .. "=" .. v.Name)
        end
    end

    if inst:IsA("BasePart") then
        try("Anchored")
        try("CanCollide")
        try("Transparency")
    elseif inst:IsA("Humanoid") then
        try("Health")
        try("MaxHealth")
        try("WalkSpeed")
    elseif inst:IsA("Sound") then
        try("SoundId")
    elseif inst:IsA("Tool") then
        try("ToolTip")
    end

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
-- SECTION 7 : DEDUP WALKER
-----------------------------------------------------------------------

local function walk(inst, depth, prefix)
    stats.nodes = stats.nodes + 1
    if depth > stats.maxDepth then
        stats.maxDepth = depth
    end

    local kind = classify(inst)

    -- Categorize into per-file collections.
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

    -- Value object capture for the values file.
    if inst:IsA("StringValue") or inst:IsA("BoolValue")
        or inst:IsA("NumberValue") or inst:IsA("IntValue") then
        noteValueObject(inst)
    end

    -- GUI text capture for the guitext file.
    if inst:IsA("TextLabel") or inst:IsA("TextButton")
        or inst:IsA("TextBox") then
        noteGuiText(inst)
    end

    -- Structure line.
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
    table.insert(structureOut, line)

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

    -- Recurse with sibling dedup.
    local children = safe(function() return inst:GetChildren() end)
    if not children or #children == 0 then
        return
    end

    if CFG.DEDUP_SIBLINGS then
        local groups = {}
        local order = {}
        for _, child in ipairs(children) do
            local key = child.Name .. "\0" .. child.ClassName
            if not groups[key] then
                groups[key] = {
                    name = child.Name,
                    class = child.ClassName,
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
                    walk(group.list[s], depth + 1, prefix .. "   ")
                end
                emit(prefix .. "   ... x"
                    .. (count - CFG.DEDUP_MAX_SAMPLE)
                    .. " more [" .. group.name .. "]")

                -- Count collapsed siblings for stats + categories.
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
                    walk(group.list[s], depth + 1, prefix .. "   ")
                end
            end
        end
    else
        for _, child in ipairs(children) do
            walk(child, depth + 1, prefix .. "   ")
        end
    end
end

---------------------------------------------------------------------
-- SECTION 8 : YIELD WRAPPER
---------------------------------------------------------------------

local function yieldedWalk(inst, depth, prefix)
    walk(inst, depth, prefix)
    if stats.nodes % CFG.YIELD_EVERY < 2 then
        if task and task.wait then
            task.wait()
        else
            wait()
        end
    end
end

---------------------------------------------------------------------
-- SECTION 9 : SCAN RUNNER
---------------------------------------------------------------------

log("starting deep scan...")

local player = game:GetService("Players").LocalPlayer

local function scanService(tag, title, svcName)
    local svc = safe(game.GetService, game, svcName)
    if not svc then
        return
    end

    beginSection(tag, title)
    local children = safe(function() return svc:GetChildren() end)
    if children then
        emit("(" .. #children .. " children)")
        for _, child in ipairs(children) do
            yieldedWalk(child, 1, "   ")
        end
    end
    endSection(tag)
    log("scanned " .. svcName .. " ("
        .. stats.nodes .. " nodes)")
end

-- Signal-first order: remotes and scripts land before the huge
-- Workspace tree, so partial scans still contain the gold.
scanService("RS", "REPLICATED STORAGE", "ReplicatedStorage")
scanService("RF", "REPLICATED FIRST", "ReplicatedFirst")
scanService("SP", "STARTER PLAYER", "StarterPlayer")
scanService("SG", "STARTER GUI", "StarterGui")

beginSection("WS", "WORKSPACE")
local wsChildren = safe(function()
    return workspace:GetChildren()
end)
if wsChildren then
    emit("(" .. #wsChildren .. " children)")
    for _, child in ipairs(wsChildren) do
        yieldedWalk(child, 1, "   ")
    end
end
endSection("WS")
log("scanned Workspace (" .. stats.nodes .. " nodes)")

if player then
    beginSection("CH", "CHARACTER: " .. player.Name)
    local char = player.Character
    if char then
        yieldedWalk(char, 1, "   ")
    end
    endSection("CH")

    beginSection("PG", "PLAYER GUI (live)")
    local pg = player:FindFirstChild("PlayerGui")
    if pg then
        for _, gui in ipairs(pg:GetChildren()) do
            walk(gui, 1, "   ")
        end
    end
    endSection("PG")

    beginSection("LS", "LEADERSTATS")
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            local val = safe(function() return v.Value end)
            emit("   " .. v.Name .. " = " .. tostring(val))
        end
    end
    endSection("LS")
end

---------------------------------------------------------------------
-- SECTION 10 : BUILD PER-FILE CONTENT
---------------------------------------------------------------------

-- REMOTES FILE
table.insert(remotesOut,
    "==== WINGS OF GLORY REMOTES ====")
table.insert(remotesOut,
    "total: " .. stats.remotes .. " remotes")
table.insert(remotesOut, "")

local containerNames = {}
for container in pairs(remotesByContainer) do
    table.insert(containerNames, container)
end
table.sort(containerNames)

for _, container in ipairs(containerNames) do
    local list = remotesByContainer[container]
    table.sort(list)
    table.insert(remotesOut,
        "-- container: " .. container .. " (" .. #list .. ")")
    for _, entry in ipairs(list) do
        table.insert(remotesOut, "   " .. entry)
    end
    table.insert(remotesOut, "")
end

-- SCRIPTS FILE
table.insert(scriptsOut,
    "==== WINGS OF GLORY SCRIPTS ====")
table.insert(scriptsOut,
    "total: " .. stats.scripts .. " scripts")
table.insert(scriptsOut, "")

local locationNames = {}
for location in pairs(scriptsByLocation) do
    table.insert(locationNames, location)
end
table.sort(locationNames)

for _, location in ipairs(locationNames) do
    local list = scriptsByLocation[location]
    table.sort(list)
    table.insert(scriptsOut,
        "-- location: " .. location .. " (" .. #list .. ")")
    for _, entry in ipairs(list) do
        table.insert(scriptsOut, "   " .. entry)
    end
    table.insert(scriptsOut, "")
end

-- GUI TEXT FILE
table.insert(guiTextOut,
    "==== WINGS OF GLORY GUI TEXT ====")
table.insert(guiTextOut,
    "total: " .. #guiTexts .. " text elements")
table.insert(guiTextOut, "")
table.sort(guiTexts)
for _, entry in ipairs(guiTexts) do
    table.insert(guiTextOut, entry)
end

-- VALUES FILE
table.insert(valuesOut,
    "==== WINGS OF GLORY VALUE OBJECTS ====")
table.insert(valuesOut,
    "total: " .. #valueObjects .. " value objects")
table.insert(valuesOut, "")
table.sort(valueObjects)
for _, entry in ipairs(valueObjects) do
    table.insert(valuesOut, entry)
end

-- STRUCTURE FILE
table.insert(structureOut, 1,
    "==== WINGS OF GLORY STRUCTURE ====")
table.insert(structureOut, 2,
    "note: sibling-deduped, see wog_summary.txt for counts")
table.insert(structureOut, 3, "")

-- SUMMARY FILE
table.insert(summaryOut,
    "==== WINGS OF GLORY SUMMARY ====")
table.insert(summaryOut,
    "nodes: " .. stats.nodes)
table.insert(summaryOut,
    "remotes: " .. stats.remotes)
table.insert(summaryOut,
    "scripts: " .. stats.scripts)
table.insert(summaryOut,
    "parts: " .. stats.parts)
table.insert(summaryOut,
    "tools: " .. stats.tools)
table.insert(summaryOut,
    "max depth: " .. stats.maxDepth)
table.insert(summaryOut, "")
table.insert(summaryOut,
    "== ALL REMOTES (flat list) ==")

table.insert(summaryOut, "")

---------------------------------------------------------------------
-- SECTION 11 : WRITE FILES
---------------------------------------------------------------------

-- (summary remote list rebuilt here for the flat list)
local flatRemotes = {}
for _, container in ipairs(containerNames) do
    for _, entry in ipairs(remotesByContainer[container]) do
        table.insert(flatRemotes, container .. " :: " .. entry)
    end
end
table.sort(flatRemotes)

for _, entry in ipairs(flatRemotes) do
    table.insert(summaryOut, entry)
end
table.insert(summaryOut, "")
table.insert(summaryOut, "== ALL SCRIPTS (flat list) ==")

local flatScripts = {}
for _, location in ipairs(locationNames) do
    for _, entry in ipairs(scriptsByLocation[location]) do
        table.insert(flatScripts, entry)
    end
end
table.sort(flatScripts)

for _, entry in ipairs(flatScripts) do
    table.insert(summaryOut, entry)
end

local function writeOut(filename, buffer)
    if type(writefile) ~= "function" then
        return false
    end
    local content = table.concat(buffer, "\n")
    local ok = pcall(writefile, filename, content)
    if ok then
        log("wrote " .. filename .. " ("
            .. #buffer .. " lines)")
    else
        log("FAILED to write " .. filename)
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

log("scan complete: " .. lineCount .. " combined lines, "
    .. stats.nodes .. " nodes")

---------------------------------------------------------------------
-- SECTION 12 : INTERACTIVE COMMANDS
---------------------------------------------------------------------

MAP = {}

function MAP.sections()
    print("=== SECTIONS (in wogmap.txt) ===")
    for tag, start in pairs(sectionStart) do
        local count = (sectionEnd[tag] or lineCount) - start + 1
        print(string.format("  [%s] lines %d-%d (%d lines)",
            tag, start, sectionEnd[tag] or lineCount, count))
    end
end

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
    if type(setclipboard) ~= "function" then
        print("no clipboard; use MAP.get")
        return
    end
    local parts = {}
    for i = s, (e or lineCount) do
        table.insert(parts, report[i])
    end
    setclipboard(table.concat(parts, "\n"))
    print("section [" .. tag .. "] copied ("
        .. ((e or lineCount) - s + 1) .. " lines)")
end

function MAP.find(text)
    local needle = tostring(text):lower()
    local hits = 0
    for i, line in ipairs(report) do
        if line:lower():find(needle, 1, true) then
            print(string.format("%5d: %s", i, line))
            hits = hits + 1
            if hits >= 100 then
                print("(stopping at 100 hits)")
                break
            end
        end
    end
    if hits == 0 then
        print("no matches for: " .. tostring(text))
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
    print("all files rewritten")
end

log("interactive commands ready:")
log("  MAP.get('RS')   remotes + modules in ReplicatedStorage")
log("  MAP.copy('RS')  ...to clipboard")
log("  MAP.find('Gun') search everything")
log("  MAP.stats()     the numbers")
