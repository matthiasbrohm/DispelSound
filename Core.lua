-- DispelSound - Core.lua
--
-- How it works (and why it looks nothing like a classic debuff scanner):
--
-- Since the 12.1 engine (WoW Forever 1.60 uses it too) addons cannot read auras
-- while in combat; every C_UnitAuras query hard-errors there. The only thing that
-- still reacts to an aura in combat is the game itself: C_UnitAuras.AddAuraSound
-- hands the game a sound for one unit token and one spell ID, and the game plays
-- it when that aura lands. So this addon never looks at a single aura. Out of
-- combat it registers one aura sound per watched unit (player, party1-4,
-- raid1-40) for every debuff of the types the character can dispel (Data.lua),
-- and the engine does the rest.
--
-- Registration is only possible while nothing restricts addons (not in combat,
-- not during an encounter), so all changes are queued and worked off in small
-- slices between fights.

local ADDON, ns = ...
local L = ns.L

local TYPES = { "Magic", "Curse", "Disease", "Poison" }

local SOUND_DIR = "Interface\\AddOns\\" .. ADDON .. "\\Sounds\\"
ns.SOUNDS = {}
for _, key in ipairs({
    "Ping", "Bell", "Chime", "Harp", "Drop", "Blip", "Double", "Knock", "Gong",
    "Alarm", "Siren", "Horn", "Buzzer",
}) do
    ns.SOUNDS[#ns.SOUNDS + 1] = { key = key, name = L["SOUND_" .. key] or key, file = SOUND_DIR .. key .. ".ogg" }
end
ns.CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }

ns.DEFAULTS = {
    enabled = true,
    self = true,
    party = true,
    raid = true,
    sound = "Ping",
    custom = false,         -- path (string) or file ID (number) for sound == "custom"
    channel = "Master",
    throttle = 1,           -- seconds, the game accepts 0 to 5
    autoTypes = true,
    types = { Magic = true, Curse = false, Disease = true, Poison = true },
    ignore = {},            -- [spellID] = true: never register
    extra = {},             -- [spellID] = true: always register
}

-- Dispel spells per class (WoW Forever) and the debuff types they remove.
local CLASS_DISPELS = {
    PALADIN = {
        { 4987, "Magic", "Poison", "Disease" },    -- Cleanse
        { 1152, "Poison", "Disease" },             -- Purify
    },
    PRIEST = {
        { 527, "Magic" }, { 988, "Magic" },        -- Dispel Magic
        { 552, "Disease" },                        -- Abolish Disease
        { 528, "Disease" },                        -- Cure Disease
    },
    DRUID = {
        { 2782, "Curse" },                         -- Remove Curse
        { 2893, "Poison" },                        -- Abolish Poison
        { 8946, "Poison" },                        -- Cure Poison
    },
    SHAMAN = {
        { 526, "Poison" },                         -- Cure Poison
        { 2870, "Disease" },                       -- Cure Disease
    },
    MAGE = {
        { 475, "Curse" },                          -- Remove Lesser Curse
    },
}

local BUDGET_MS = 4         -- time per frame spent on registering
local SLICE = 50            -- calls between two looks at the clock
local PROBE = 3             -- failed calls in a row that count as "the game refuses"
local RETRY_DELAY = 30      -- seconds before a refused registration is retried
local MAX_RETRIES = 3       -- timed retries; events always retry

local issecretvalue = issecretvalue or function() return false end
local debugprofilestop = debugprofilestop or function() return 0 end

local db
local playerClass
local api = C_UnitAuras and C_UnitAuras.AddAuraSound and C_UnitAuras.RemoveAuraSound and true or false
local TRIGGER_ADDED = Enum and Enum.UnitAuraSoundTrigger and Enum.UnitAuraSoundTrigger.Added or 0

-- What should be registered right now.
local desired = { units = {}, order = {}, list = {}, sig = "", types = {} }
-- What is registered: unit -> { sig, handles = { auraSoundID, ... }, next, complete }
local registered = {}
local STALE = "\0stale"     -- pseudo unit holding last session's sounds until they are removed
local staleRanges           -- last session's sound IDs, until we know whether the game kept them
local listRev = 0           -- bumped when ignore/extra change
local blocked = false       -- the game refused a registration; wait for an event or the retry timer
local retries = 0
local reportedRefusal = false
local announced = false
local restricted = {}       -- restriction types announced as activating/active

local worker = CreateFrame("Frame")
worker:Hide()

local function Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    print("|cff33ff99DispelSound|r: " .. msg)
end
ns.Print = Print

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local function InitDB()
    if type(DispelSoundDB) ~= "table" then DispelSoundDB = {} end
    db = DispelSoundDB
    for k, v in pairs(ns.DEFAULTS) do
        if db[k] == nil or type(db[k]) ~= type(v) then
            if type(v) == "table" then
                db[k] = {}
                for k2, v2 in pairs(v) do db[k][k2] = v2 end
            else
                db[k] = v
            end
        end
    end
    for _, typ in ipairs(TYPES) do
        if type(db.types[typ]) ~= "boolean" then db.types[typ] = ns.DEFAULTS.types[typ] end
    end
    if type(db.handles) == "table" then staleRanges = db.handles end
    db.handles = nil
    ns.db = db
end

-- Sounds other addons share through LibSharedMedia (EllesmereUI ships the
-- library) are offered too, under the key "lsm:<name>".
local LSM_PREFIX = "lsm:"
local function SharedMedia()
    if not LibStub then return nil end
    local ok, lsm = pcall(LibStub, "LibSharedMedia-3.0", true)
    if ok and type(lsm) == "table" and lsm.List and lsm.Fetch then return lsm end
end

local function SharedSound(name)
    local lsm = SharedMedia()
    if not lsm then return nil end
    local ok, file = pcall(lsm.Fetch, lsm, "sound", name, true)
    if ok and (type(file) == "string" or type(file) == "number") then return file end
end

-- Every sound on offer: { key, name }, own sounds first.
function ns.SoundChoices()
    local list = {}
    for _, s in ipairs(ns.SOUNDS) do
        list[#list + 1] = { key = s.key, name = s.name }
    end
    local lsm = SharedMedia()
    if lsm then
        local ok, names = pcall(lsm.List, lsm, "sound")
        if ok and type(names) == "table" then
            for _, name in ipairs(names) do
                if name ~= "None" and SharedSound(name) then
                    list[#list + 1] = { key = LSM_PREFIX .. name, name = name }
                end
            end
        end
    end
    return list
end

-- The sound as the game takes it: a file path or a numeric file ID.
function ns.SoundSource()
    local key = db.sound
    if key == "custom" and db.custom then return db.custom end
    for _, s in ipairs(ns.SOUNDS) do
        if s.key == key then return s.file end
    end
    if type(key) == "string" and key:sub(1, #LSM_PREFIX) == LSM_PREFIX then
        local file = SharedSound(key:sub(#LSM_PREFIX + 1))
        if file then return file end
    end
    return ns.SOUNDS[1].file
end

function ns.PlayTest()
    local src = ns.SoundSource()
    if PlaySoundFile then PlaySoundFile(src, db.channel) end
end

-------------------------------------------------------------------------------
-- Which debuff types can this character dispel?
-------------------------------------------------------------------------------

local function SpellKnown(id)
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        if ok and known and not issecretvalue(known) then return true end
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, id)
        if ok and known then return true end
    end
    return false
end

function ns.ActiveTypes()
    local t = {}
    if db.autoTypes then
        local spells = CLASS_DISPELS[playerClass]
        if spells then
            for _, entry in ipairs(spells) do
                if SpellKnown(entry[1]) then
                    for i = 2, #entry do t[entry[i]] = true end
                end
            end
        end
    else
        for _, typ in ipairs(TYPES) do
            if db.types[typ] then t[typ] = true end
        end
    end
    return t
end

function ns.TypeNames(types)
    local names = {}
    for _, typ in ipairs(TYPES) do
        if types[typ] then names[#names + 1] = L["TYPE_" .. typ] end
    end
    if #names == 0 then return L.MSG_STATUS_NONE end
    return table.concat(names, ", ")
end

-------------------------------------------------------------------------------
-- Desired state
-------------------------------------------------------------------------------

local function Exists(unit)
    local ex = UnitExists(unit)
    return ex and not issecretvalue(ex)
end

local function IsPlayer(unit)
    local same = UnitIsUnit(unit, "player")
    return same and not issecretvalue(same)
end

-- In a raid every member has a raid token (the player too), so only raid tokens
-- are used there: registering "player" as well would play the sound twice.
local function WantedUnits()
    local order = {}
    if not db.enabled then return order end
    if IsInRaid() and db.raid then
        for i = 1, 40 do
            local unit = "raid" .. i
            if Exists(unit) then
                if IsPlayer(unit) then
                    if db.self then table.insert(order, 1, unit) end   -- own sound first
                else
                    order[#order + 1] = unit
                end
            end
        end
    else
        if db.self then order[#order + 1] = "player" end
        if db.party and IsInGroup() then
            for i = 1, 4 do
                local unit = "party" .. i
                if Exists(unit) then order[#order + 1] = unit end
            end
        end
    end
    return order
end

local function BuildList(types)
    local list, seen = {}, {}
    local exists = C_Spell and C_Spell.DoesSpellExist
    local function add(id)
        if seen[id] or db.ignore[id] then return end
        seen[id] = true
        if exists then
            local ok, there = pcall(exists, id)
            if ok and there == false then return end
        end
        list[#list + 1] = id
    end
    for _, typ in ipairs(TYPES) do
        if types[typ] then
            for _, id in ipairs(ns.DEBUFFS[typ]) do add(id) end
        end
    end
    for id in pairs(db.extra) do add(id) end
    table.sort(list)
    return list
end

local function Recompute()
    if not db then return end
    local types = ns.ActiveTypes()
    local typeSig = {}
    for _, typ in ipairs(TYPES) do
        if types[typ] then typeSig[#typeSig + 1] = typ end
    end
    local throttle = math.min(5, math.max(0, tonumber(db.throttle) or 0))
    local sig = table.concat({
        table.concat(typeSig, ","), tostring(ns.SoundSource()), tostring(db.channel),
        tostring(throttle), tostring(listRev),
    }, "|")

    if sig ~= desired.sig then
        desired.list = BuildList(types)
        desired.sig = sig
    end
    desired.types = types
    desired.throttle = throttle

    local order = (#desired.list > 0) and WantedUnits() or {}
    local units = {}
    for _, unit in ipairs(order) do units[unit] = true end
    desired.order, desired.units = order, units

    if api then worker:Show() end
end

local refreshQueued = false
function ns.Refresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        Recompute()
    end)
end

-------------------------------------------------------------------------------
-- Is the game taking registrations right now?
-------------------------------------------------------------------------------

local RESTRICTIONS = { "Combat", "Encounter", "ChallengeMode", "PvPMatch" }

local function Safe()
    if InCombatLockdown() then return false end
    if next(restricted) then return false end
    local RA = C_RestrictedActions
    local kinds = Enum and Enum.AddOnRestrictionType
    if RA and RA.IsAddOnRestrictionActive and kinds then
        for _, name in ipairs(RESTRICTIONS) do
            local kind = kinds[name]
            if kind ~= nil and RA.IsAddOnRestrictionActive(kind) then return false end
        end
    end
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then return false end
    return true
end
ns.Safe = Safe

-------------------------------------------------------------------------------
-- Sounds left over from the last session
--
-- Sound IDs count up. If the first ID the game hands out now is above every ID
-- of the last session, the game kept its registry over the reload and the old
-- sounds are still in there (they would play on top of the new ones), so they
-- are removed. Otherwise the registry started over and there is nothing to do.
-------------------------------------------------------------------------------

local function CheckStale(firstNewID)
    local ranges = staleRanges
    staleRanges = nil
    if not ranges then return end
    local maxOld = 0
    for _, r in ipairs(ranges) do
        if type(r) == "table" and type(r[2]) == "number" and r[2] > maxOld then maxOld = r[2] end
    end
    if firstNewID <= maxOld then return end
    local handles = {}
    for _, r in ipairs(ranges) do
        if type(r) == "table" and type(r[1]) == "number" and type(r[2]) == "number" then
            for id = r[1], r[2] do handles[#handles + 1] = id end
        end
    end
    if #handles > 0 then
        registered[STALE] = { sig = STALE, handles = handles, complete = true }
    end
end

local function SaveHandles()
    if not db then return end
    local all = {}
    for unit, reg in pairs(registered) do
        for _, id in ipairs(reg.handles) do all[#all + 1] = id end
    end
    -- Sounds of the session before that were never looked at stay on the list.
    if staleRanges then
        for _, r in ipairs(staleRanges) do
            if type(r) == "table" and type(r[1]) == "number" and type(r[2]) == "number" then
                for id = r[1], r[2] do all[#all + 1] = id end
            end
        end
    end
    if #all == 0 then db.handles = nil; return end
    table.sort(all)
    local ranges, from, to = {}, all[1], all[1]
    for i = 2, #all do
        local id = all[i]
        if id == to + 1 then
            to = id
        elseif id ~= to then
            ranges[#ranges + 1] = { from, to }
            from, to = id, id
        end
    end
    ranges[#ranges + 1] = { from, to }
    db.handles = ranges
end

-------------------------------------------------------------------------------
-- Worker: brings "registered" in line with "desired", a slice per frame
-------------------------------------------------------------------------------

local info = {}             -- reused UnitAuraSoundInfo

local function NextAction()
    for unit, reg in pairs(registered) do
        if not desired.units[unit] or reg.sig ~= desired.sig then return "remove", unit end
    end
    for _, unit in ipairs(desired.order) do
        local reg = registered[unit]
        if not reg or not reg.complete then return "add", unit end
    end
end

local function RemoveSlice(unit)
    local reg = registered[unit]
    local handles = reg.handles
    local n = #handles
    for i = n, math.max(1, n - SLICE + 1), -1 do
        pcall(C_UnitAuras.RemoveAuraSound, handles[i])
        handles[i] = nil
    end
    if #handles == 0 then registered[unit] = nil end
end

-- Returns false when the game refused the unit's first sounds.
local function AddSlice(unit)
    local reg = registered[unit]
    if not reg then
        reg = { sig = desired.sig, handles = {}, next = 1, complete = false }
        registered[unit] = reg
    end
    local list = desired.list
    local src = ns.SoundSource()
    info.unitToken = unit
    info.soundFileName = type(src) == "string" and src or nil
    info.soundFileID = type(src) == "number" and src or nil
    info.outputChannel = db.channel
    info.throttleSeconds = desired.throttle

    local handles = reg.handles
    local probing = (#handles == 0 and reg.next == 1)
    local last = math.min(#list, reg.next + SLICE - 1)
    for i = reg.next, last do
        info.spellID = list[i]
        local ok, id = pcall(C_UnitAuras.AddAuraSound, TRIGGER_ADDED, info)
        if ok and type(id) == "number" and not issecretvalue(id) then
            handles[#handles + 1] = id
            if staleRanges then CheckStale(id) end
        elseif probing and #handles == 0 and i >= math.min(PROBE, #list) then
            -- The first few all failed: the game takes no sounds here right now.
            registered[unit] = nil
            return false
        end
    end
    reg.next = last + 1
    if reg.next > #list then reg.complete = true end
    return true
end

local function CountUnits()
    local done = 0
    for _, unit in ipairs(desired.order) do
        local reg = registered[unit]
        if reg and reg.complete and reg.sig == desired.sig then done = done + 1 end
    end
    return done, #desired.order
end
ns.CountUnits = CountUnits

local waited = 0
worker:SetScript("OnUpdate", function(self, elapsed)
    if blocked or not Safe() then
        -- Nothing to do until an event wakes the worker; look again now and then.
        waited = waited + elapsed
        if waited < 0.5 then return end
        waited = 0
        if blocked or not Safe() then return end
    end
    local start = debugprofilestop()
    repeat
        local action, unit = NextAction()
        if not action then
            self:Hide()
            retries = 0
            if not announced and #desired.order > 0 then
                announced = true
                Print(L.MSG_READY, ns.TypeNames(desired.types), #desired.list, #desired.order)
            end
            return
        end
        if action == "remove" then
            RemoveSlice(unit)
        elseif not AddSlice(unit) then
            blocked = true
            if not reportedRefusal then
                reportedRefusal = true
                Print(L.MSG_REFUSED)
            end
            if retries < MAX_RETRIES then
                retries = retries + 1
                C_Timer.After(RETRY_DELAY, function() blocked = false end)
            end
            return
        end
    until debugprofilestop() - start >= BUDGET_MS
end)

function ns.IsWorking()
    return worker:IsShown()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")

local function Wake()
    blocked = false
    retries = 0
    ns.Refresh()
end

events:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        InitDB()
        playerClass = select(2, UnitClass("player"))
        if not api then
            Print(L.MSG_NO_API)
        end
        if ns.BuildOptions then
            local ok, err = pcall(ns.BuildOptions)
            if not ok then ns.optionsError = err end
        end
        Recompute()
        -- The spellbook can fill in a moment after login, so judge it later.
        C_Timer.After(15, function()
            if db.enabled and db.autoTypes and not next(ns.ActiveTypes()) then
                Print(L.MSG_NO_TYPES)
            end
        end)
    elseif event == "PLAYER_LOGOUT" then
        SaveHandles()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        -- Fired before a restriction becomes active and after it ended; the
        -- query functions still answer "inactive" while it is being announced.
        local kind, state = ...
        local inactive = Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState.Inactive or 0
        local kinds = Enum and Enum.AddOnRestrictionType
        local watched = false
        if kinds then
            for _, name in ipairs(RESTRICTIONS) do
                if kinds[name] == kind then watched = true end
            end
        end
        if watched then
            restricted[kind] = (state ~= inactive) or nil
        end
        if not next(restricted) then Wake() end
    elseif db then
        if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
            -- Never stay locked on a missed "restriction ended" event: from here on
            -- the game's own answer (Safe) decides again.
            for k in pairs(restricted) do restricted[k] = nil end
        end
        Wake()
    end
end)

for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE",
    "PLAYER_REGEN_ENABLED", "SPELLS_CHANGED", "ADDON_RESTRICTION_STATE_CHANGED",
}) do
    pcall(events.RegisterEvent, events, event)
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and type(name) == "string" and not issecretvalue(name) then return name end
    end
    return "?"
end

local function Status()
    Print(db.enabled and L.MSG_STATUS_ON or L.MSG_STATUS_OFF)
    Print(L.MSG_STATUS_TYPES, ns.TypeNames(desired.types), db.autoTypes and L.MSG_STATUS_AUTO or L.MSG_STATUS_MANUAL)
    Print(L.MSG_STATUS_IDS, #desired.list, ns.DATA_BUILD)
    Print(L.MSG_STATUS_UNITS, CountUnits())
    if worker:IsShown() then
        Print(Safe() and not blocked and L.MSG_STATUS_WORKING or L.MSG_STATUS_WAIT)
    end
    if not api then Print(L.MSG_NO_API) end
end

local function ToggleID(tbl, arg, onMsg, offMsg)
    local id = tonumber(arg)
    if not id or id <= 0 or id ~= math.floor(id) then Print(L.MSG_BAD_ID); return end
    if tbl[id] then
        tbl[id] = nil
        Print(offMsg, id, SpellName(id))
    else
        tbl[id] = true
        Print(onMsg, id, SpellName(id))
    end
    listRev = listRev + 1
    ns.Refresh()
end

SLASH_DISPELSOUND1 = "/dsound"
SLASH_DISPELSOUND2 = "/dispelsound"
SlashCmdList["DISPELSOUND"] = function(msg)
    if not db then return end
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" then
        if ns.categoryID and Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(ns.categoryID)
        else
            Print(L.MSG_HELP)
            Status()
        end
    elseif cmd == "test" then
        ns.PlayTest()
    elseif cmd == "status" then
        Status()
    elseif cmd == "on" or cmd == "off" then
        db.enabled = (cmd == "on")
        Print(db.enabled and L.MSG_ENABLED or L.MSG_DISABLED)
        ns.Refresh()
    elseif cmd == "sounds" or (cmd == "sound" and arg == "") then
        local names = {}
        for _, choice in ipairs(ns.SoundChoices()) do names[#names + 1] = choice.name end
        Print(L.MSG_SOUND_LIST, table.concat(names, ", "))
    elseif cmd == "sound" then
        local found, shown
        local want = arg:lower()
        for _, choice in ipairs(ns.SoundChoices()) do
            if not found and (choice.key:lower() == want or choice.name:lower() == want) then
                found, shown = choice.key, choice.name
            end
        end
        if found then
            db.sound = found
        else
            db.sound = "custom"
            db.custom = tonumber(arg) or arg
        end
        Print(L.MSG_SOUND_SET, tostring(shown or db.custom))
        ns.PlayTest()
        ns.Refresh()
    elseif cmd == "ignore" then
        ToggleID(db.ignore, arg, L.MSG_IGNORED, L.MSG_UNIGNORED)
    elseif cmd == "add" then
        ToggleID(db.extra, arg, L.MSG_ADDED, L.MSG_REMOVED)
    else
        Print(L.MSG_HELP)
    end
end
