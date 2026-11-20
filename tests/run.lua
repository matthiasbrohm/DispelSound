-- Tests ohne WoW: luajit tests/run.lua
-- Baut ein kleines WoW nach (Events, Zeit, Gruppe, Kampf, die Aura-Sound-Schnittstelle des Spiels),
-- lädt das Addon wie der Client (Dateien in der Reihenfolge der .toc) und prüft, was es beim Spiel
-- anmeldet. Exitcode 1 bei Fehlern (für GitHub Actions).

local here = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "tests"
local root = here .. "/.."

-------------------------------------------------------------------------------
-- Die Welt
-------------------------------------------------------------------------------

local W            -- die aktuelle Welt
local realPrint = print

local FrameMT = {}
FrameMT.__index = FrameMT
function FrameMT:Hide() self.shown = false end
function FrameMT:Show() self.shown = true end
function FrameMT:IsShown() return self.shown end
function FrameMT:SetScript(name, fn) self.scripts[name] = fn end
function FrameMT:RegisterEvent(event) self.events[event] = true end

-- Neue Welt. "keep" übernimmt, was einen /reload überlebt: gespeicherte Variablen und (je nach
-- Fall) die Aura-Sounds im Spiel samt Zähler.
local function newWorld(opts, keep)
    opts = opts or {}
    W = {
        frames = {}, timers = {}, now = 0, clock = 0, printed = {}, played = {},
        combat = false, raid = false, group = false, units = { player = true }, me = "player",
        class = opts.class or "PALADIN", known = opts.known or { [4987] = true },
        restr = {}, refuse = false, missing = { [16] = true },
        registry = keep and keep.registry or {}, nextID = keep and keep.nextID or 1,
        addCalls = 0, illegal = 0, lsm = opts.lsm,
    }
    DispelSoundDB = keep and keep.db or nil
    SlashCmdList = {}
    LibStub = nil

    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        W.printed[#W.printed + 1] = table.concat(parts, " ")
    end
    CreateFrame = function()
        local f = setmetatable({ shown = true, scripts = {}, events = {} }, FrameMT)
        W.frames[#W.frames + 1] = f
        return f
    end
    C_Timer = { After = function(delay, fn) W.timers[#W.timers + 1] = { at = W.now + delay, fn = fn } end }
    InCombatLockdown = function() return W.combat end
    IsInRaid = function() return W.raid end
    IsInGroup = function() return W.group or W.raid end
    UnitExists = function(unit) return W.units[unit] or false end
    UnitIsUnit = function(a, b) return a == b or (a == W.me and b == "player") end
    UnitClass = function() return "?", W.class end
    GetLocale = function() return opts.locale or "enUS" end
    PlaySoundFile = function(file, channel) W.played[#W.played + 1] = file end
    debugprofilestop = function() W.clock = W.clock + 0.5; return W.clock end
    issecretvalue = function() return false end
    Enum = {
        UnitAuraSoundTrigger = { Added = 0 },
        AddOnRestrictionType = { Combat = 0, Encounter = 1, ChallengeMode = 2, PvPMatch = 3, Map = 4 },
        AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 },
    }
    C_RestrictedActions = { IsAddOnRestrictionActive = function(kind) return W.restr[kind] or false end }
    C_Secrets = { ShouldAurasBeSecret = function() return W.combat end }
    C_SpellBook = { IsSpellKnown = function(id) return W.known[id] or false end }
    C_Spell = {
        DoesSpellExist = function(id) return not W.missing[id] end,
        GetSpellName = function(id) return "Spell" .. id end,
    }
    C_UnitAuras = {
        AddAuraSound = function(trigger, info)
            W.addCalls = W.addCalls + 1
            if W.combat or next(W.restr) then W.illegal = W.illegal + 1; error("blocked") end
            if W.refuse then return nil end
            assert(trigger == 0, "trigger")
            assert(type(info.unitToken) == "string" and type(info.spellID) == "number", "unit/spell")
            assert(info.soundFileName or info.soundFileID, "kein Sound")
            assert(not (info.soundFileName and info.soundFileID), "Pfad und Datei-ID zugleich")
            assert(info.throttleSeconds >= 0 and info.throttleSeconds <= 5, "throttle")
            local id = W.nextID
            W.nextID = id + 1
            W.registry[id] = { unit = info.unitToken, spell = info.spellID, file = info.soundFileName or info.soundFileID, channel = info.outputChannel }
            return id
        end,
        RemoveAuraSound = function(id) W.registry[id] = nil end,
    }
    if opts.lsm then
        local lsm = {}
        function lsm:List() local names = {} for name in pairs(opts.lsm) do names[#names + 1] = name end table.sort(names) return names end
        function lsm:Fetch(kind, name) return opts.lsm[name] end
        LibStub = function(name, silent) if name == "LibSharedMedia-3.0" then return lsm end if not silent then error("?") end end
    end
    if opts.settings then
        local controls = {}
        W.controls = controls
        local function control(kind, setting)
            local c = { kind = kind, setting = setting }
            function c:SetParentInitializer(parent, predicate) self.parent = parent end
            controls[#controls + 1] = c
            return c
        end
        Settings = { VarType = { Boolean = "boolean", String = "string", Number = "number" } }
        function Settings.RegisterVerticalLayoutCategory(name)
            local layout = {}
            function layout:AddInitializer(init) controls[#controls + 1] = { kind = "layout", init = init } end
            local category = {}
            function category:GetID() return 77 end
            return category, layout
        end
        function Settings.RegisterProxySetting(category, variable, varType, name, default, get, set)
            assert(type(default) == varType, variable .. ": Standardwert hat den falschen Typ")
            assert(type(get()) == varType, variable .. ": Wert hat den falschen Typ")
            return { variable = variable, get = get, set = set, varType = varType }
        end
        function Settings.CreateCheckbox(category, setting) return control("check", setting) end
        function Settings.CreateDropdown(category, setting, options) assert(#options() > 0); return control("drop", setting) end
        function Settings.CreateSlider(category, setting, options) assert(options); return control("slider", setting) end
        function Settings.CreateSliderOptions() local o = {} function o:SetLabelFormatter(where, fn) assert(fn(1.5) == "1.5 s") end return o end
        function Settings.CreateControlTextContainer()
            local c = { data = {} }
            function c:Add(value, label) self.data[#self.data + 1] = { value = value, label = label } end
            function c:GetData() return self.data end
            return c
        end
        function Settings.RegisterAddOnCategory(category) W.category = category end
        function Settings.OpenToCategory(id) W.opened = id end
        MinimalSliderWithSteppersMixin = { Label = { Right = 2 } }
        CreateSettingsListSectionHeaderInitializer = function(name) return { header = name } end
        CreateSettingsButtonInitializer = function(name, text, click) return { click = click } end
    else
        Settings = nil
    end
    return W
end

local function tocFiles()
    local files = {}
    for line in io.lines(root .. "/DispelSound.toc") do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^#") then files[#files + 1] = line end
    end
    return files
end

local function fire(event, ...)
    for _, f in ipairs(W.frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

local function run(seconds)
    for _ = 1, math.floor(seconds / 0.02) do
        W.now = W.now + 0.02
        local due = {}
        for i = #W.timers, 1, -1 do
            if W.timers[i].at <= W.now then table.insert(due, 1, table.remove(W.timers, i)) end
        end
        for _, t in ipairs(due) do t.fn() end
        for _, f in ipairs(W.frames) do
            if f.shown and f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.02) end
        end
    end
end

-- Lädt das Addon und meldet den Charakter an.
local function login(opts, keep)
    newWorld(opts, keep)
    local ns = {}
    for _, file in ipairs(tocFiles()) do
        local chunk = assert(loadfile(root .. "/" .. file))
        chunk("DispelSound", ns)
    end
    W.ns = ns
    fire("PLAYER_LOGIN")
    fire("PLAYER_ENTERING_WORLD")
    run(4)
    return ns
end

local function slash(text) SlashCmdList.DISPELSOUND(text) end

-- Was im Spiel angemeldet ist: Anzahl je Einheit, doppelte Einträge, verwendete Dateien.
local function registered()
    local per, seen, dup, files = {}, {}, 0, {}
    for _, r in pairs(W.registry) do
        per[r.unit] = (per[r.unit] or 0) + 1
        local key = r.unit .. ":" .. r.spell
        if seen[key] then dup = dup + 1 end
        seen[key] = true
        files[tostring(r.file)] = true
    end
    return per, dup, files
end

local function units()
    local per = registered()
    local names = {}
    for unit in pairs(per) do names[#names + 1] = unit end
    table.sort(names)
    return table.concat(names, " ")
end

local function printedMatch(pattern)
    for _, line in ipairs(W.printed) do
        if line:find(pattern) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- Testgerüst
-------------------------------------------------------------------------------

local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function equal(actual, expected, what)
    if actual ~= expected then
        error(("%s: erwartet %s, bekommen %s"):format(what or "Wert", tostring(expected), tostring(actual)), 2)
    end
end
local function check(cond, what) if not cond then error(what or "Bedingung nicht erfüllt", 2) end end

-- Nach jedem Test: nie doppelt angemeldet, nie während einer Sperre beim Spiel angefragt.
local function invariants()
    local _, dup = registered()
    equal(dup, 0, "doppelt angemeldete Sounds")
    equal(W.illegal, 0, "Anmeldungen während Kampf/Begegnung")
end

local function count(tbl) local n = 0 for _ in pairs(tbl) do n = n + 1 end return n end

-------------------------------------------------------------------------------
-- Tests
-------------------------------------------------------------------------------

local MAGIC, CURSE, DISEASE, POISON

test("Daten: jede Zauber-ID höchstens einmal je Art, Arten vollständig", function()
    local ns = login()
    for _, typ in ipairs({ "Magic", "Curse", "Disease", "Poison" }) do
        local list = ns.DEBUFFS[typ]
        check(type(list) == "table" and #list > 50, typ .. " fehlt oder ist zu kurz")
        local seen = {}
        for _, id in ipairs(list) do
            check(type(id) == "number" and id > 0 and id == math.floor(id), typ .. ": ungültige ID")
            check(not seen[id], typ .. ": doppelte ID " .. id)
            seen[id] = true
        end
    end
    MAGIC, CURSE, DISEASE, POISON = #ns.DEBUFFS.Magic, #ns.DEBUFFS.Curse, #ns.DEBUFFS.Disease, #ns.DEBUFFS.Poison
end)

test("Dateien: alles aus der .toc, alle Sounds und das Icon sind vorhanden", function()
    local ns = login()
    local function exists(path) local f = io.open(path, "rb") if f then f:close() return true end return false end
    for _, file in ipairs(tocFiles()) do check(exists(root .. "/" .. file), "fehlt: " .. file) end
    check(#ns.SOUNDS >= 10, "zu wenige Sounds")
    for _, s in ipairs(ns.SOUNDS) do
        local name = s.file:match("([^\\]+)$")
        check(s.file:find("^Interface\\AddOns\\DispelSound\\Sounds\\"), "falscher Pfad: " .. s.file)
        check(exists(root .. "/Sounds/" .. name), "Sounddatei fehlt: " .. name)
    end
    check(exists(root .. "/icon.tga"), "icon.tga fehlt")
end)

test("Solo: Paladin mit Reinigung des Glaubens meldet Magie, Krankheit und Gift für sich an", function()
    login()
    local per, _, files = registered()
    equal(units(), "player", "Einheiten")
    equal(per.player, MAGIC + DISEASE + POISON - 1, "Anzahl (eine ID gibt es im Testspiel nicht)")
    check(files["Interface\\AddOns\\DispelSound\\Sounds\\Ping.ogg"], "Standardsound Ping")
    check(printedMatch("active for Magic, Disease, Poison"), "Meldung nach der Anmeldung")
end)

test("Läutern allein: nur Krankheit und Gift; ohne Bannzauber nichts", function()
    login({ known = { [1152] = true } })
    local per = registered()
    equal(per.player, DISEASE + POISON, "nur Läutern")
    W.known = {}
    fire("SPELLS_CHANGED"); run(6)
    equal(units(), "", "ohne Bannzauber")
    W.known = { [4987] = true }
    fire("SPELLS_CHANGED"); run(6)
    equal(registered().player, MAGIC + DISEASE + POISON - 1, "Reinigung gelernt")
end)

test("Andere Klassen: Druide Fluch und Gift, Krieger nichts", function()
    login({ class = "DRUID", known = { [2782] = true, [8946] = true } })
    equal(registered().player, CURSE + POISON, "Druide")
    login({ class = "WARRIOR", known = {} })
    equal(units(), "", "Krieger")
end)

test("Kampf: Gruppenbeitritt im Kampf wird erst danach angemeldet", function()
    login()
    W.combat, W.group = true, true
    W.units.party1, W.units.party2 = true, true
    fire("GROUP_ROSTER_UPDATE"); run(4)
    equal(units(), "player", "im Kampf")
    W.combat = false
    fire("PLAYER_REGEN_ENABLED"); run(6)
    equal(units(), "party1 party2 player", "nach dem Kampf")
end)

test("Schlachtzug: nur Raid-Einheiten, der eigene Platz zählt als 'ich'", function()
    local ns = login()
    W.raid, W.me = true, "raid3"
    for i = 1, 5 do W.units["raid" .. i] = true end
    fire("GROUP_ROSTER_UPDATE"); run(12)
    equal(units(), "raid1 raid2 raid3 raid4 raid5", "Raid")
    ns.db.self = false
    ns.Refresh(); run(6)
    equal(units(), "raid1 raid2 raid4 raid5", "ohne mich")
    ns.db.self, ns.db.raid = true, false
    W.units.party1 = true
    ns.Refresh(); run(12)
    equal(units(), "party1 player", "Raid aus: ich und meine Untergruppe")
    ns.db.party = false
    ns.Refresh(); run(6)
    equal(units(), "player", "nur ich")
end)

test("Begegnung: angekündigte Sperre hält die Anmeldung an", function()
    login()
    W.raid, W.me = true, "raid1"
    W.units.raid1, W.units.raid2 = true, true
    fire("GROUP_ROSTER_UPDATE"); run(8)
    equal(units(), "raid1 raid2", "vor der Begegnung")
    fire("ADDON_RESTRICTION_STATE_CHANGED", 1, 1)      -- Encounter wird aktiv
    W.restr[1] = true
    W.units.raid3 = true
    fire("GROUP_ROSTER_UPDATE"); run(4)
    equal(units(), "raid1 raid2", "während der Begegnung")
    W.restr[1] = nil
    fire("ADDON_RESTRICTION_STATE_CHANGED", 1, 0); run(6)
    equal(units(), "raid1 raid2 raid3", "nach der Begegnung")
end)

test("Sound wechseln: per Name, deutschem Namen, Datei-ID, Pfad und aus LibSharedMedia", function()
    local ns = login({ locale = "deDE", lsm = { None = "Interface\\Quiet.ogg", ["Fremder Ton"] = "Interface\\AddOns\\X\\ton.ogg" } })
    local function only(file)
        run(8)
        local _, _, files = registered()
        equal(count(files), 1, "genau eine Datei angemeldet")
        check(files[tostring(file)], "angemeldet ist nicht " .. tostring(file))
    end
    slash("sound gong"); only("Interface\\AddOns\\DispelSound\\Sounds\\Gong.ogg")
    slash("sound Glockenspiel"); only("Interface\\AddOns\\DispelSound\\Sounds\\Chime.ogg")
    slash("sound 567397"); only(567397)
    slash("sound Interface\\AddOns\\Y\\z.ogg"); only("Interface\\AddOns\\Y\\z.ogg")
    slash("sound fremder ton"); only("Interface\\AddOns\\X\\ton.ogg")
    equal(ns.db.sound, "lsm:Fremder Ton", "gespeicherter Schlüssel")
    check(#W.played >= 5, "Vorschau beim Wechsel")
    slash("sounds")
    check(printedMatch("Fremder Ton") and printedMatch("Glocke") and not printedMatch("None"), "Liste der Sounds")
    ns.db.sound = "lsm:Gibt es nicht"
    equal(ns.SoundSource(), "Interface\\AddOns\\DispelSound\\Sounds\\Ping.ogg", "Rückfall auf Ping")
end)

test("Ausnehmen und Ergänzen einzelner Zauber, Aus- und Einschalten", function()
    login()
    local before = registered().player
    slash("ignore 118"); run(8)
    equal(registered().player, before - 1, "118 ausgenommen")
    slash("add 99999"); run(8)
    equal(registered().player, before, "99999 ergänzt")
    slash("ignore abc")
    check(printedMatch("spell ID"), "Hinweis bei falscher Eingabe")
    slash("off"); run(8)
    equal(units(), "", "ausgeschaltet")
    slash("on"); run(8)
    equal(registered().player, before, "wieder eingeschaltet")
    slash("status"); slash("test"); slash("unsinn")
    check(printedMatch("Units registered: 1 of 1"), "Status")
end)

test("Neu laden: bleiben die alten Sounds im Spiel, werden sie entfernt; sonst nichts", function()
    login()
    local n = registered().player
    fire("PLAYER_LOGOUT")
    check(type(DispelSoundDB.handles) == "table" and #DispelSoundDB.handles == 1, "Sound-IDs als ein Bereich gespeichert")
    -- Das Spiel behält seine Liste über den /reload
    login(nil, { db = DispelSoundDB, registry = W.registry, nextID = W.nextID })
    equal(registered().player, n, "keine doppelten Sounds nach dem Neuladen")
    fire("PLAYER_LOGOUT")
    -- Das Spiel beginnt von vorn
    login(nil, { db = DispelSoundDB })
    equal(registered().player, n, "nach dem Neustart")
    check(DispelSoundDB.enabled == true and DispelSoundDB.sound == "Ping", "Einstellungen bleiben erhalten")
end)

test("Ablehnung: Das Spiel nimmt keine Sounds an, dann wieder doch", function()
    newWorld()
    local ns = {}
    for _, file in ipairs(tocFiles()) do assert(loadfile(root .. "/" .. file))("DispelSound", ns) end
    W.refuse = true
    fire("PLAYER_LOGIN"); fire("PLAYER_ENTERING_WORLD"); run(4)
    equal(units(), "", "nichts angemeldet")
    check(printedMatch("refused"), "Meldung")
    local calls = W.addCalls
    run(20)
    equal(W.addCalls, calls, "keine Dauerversuche")
    W.refuse = false
    fire("PLAYER_REGEN_ENABLED"); run(6)
    equal(units(), "player", "nach der Ablehnung")
end)

test("Optionen: Fenster wird aufgebaut, jede Einstellung lässt sich setzen", function()
    local ns = login({ settings = true })
    check(ns.optionsError == nil, "Fehler beim Aufbau: " .. tostring(ns.optionsError))
    equal(ns.categoryID, 77, "Kategorie")
    local settings = 0
    for _, c in ipairs(W.controls) do
        if c.setting then
            settings = settings + 1
            local value = c.setting.get()
            if c.setting.varType == "boolean" then c.setting.set(not value) end
            c.setting.set(value)
        end
        if c.init and c.init.click then c.init.click() end
    end
    check(settings >= 11, "zu wenige Einstellungen: " .. settings)
    slash("")
    equal(W.opened, 77, "/dsound öffnet die Optionen")
    run(8)
    equal(units(), "player", "unverändert nach dem Durchklicken")
end)

test("Ohne Aura-Sound-Schnittstelle: Hinweis statt Fehler", function()
    newWorld()
    C_UnitAuras = {}
    local ns = {}
    for _, file in ipairs(tocFiles()) do assert(loadfile(root .. "/" .. file))("DispelSound", ns) end
    fire("PLAYER_LOGIN"); fire("PLAYER_ENTERING_WORLD"); run(4)
    check(printedMatch("no aura sound API"), "Hinweis")
end)

-------------------------------------------------------------------------------

local failed = 0
for _, t in ipairs(tests) do
    local ok, err = xpcall(function() t.fn(); invariants() end, function(e) return debug.traceback(tostring(e), 2) end)
    if ok then
        realPrint("ok    " .. t.name)
    else
        failed = failed + 1
        realPrint("FEHLER " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
    end
end
realPrint(("\n%d Tests, %d fehlgeschlagen"):format(#tests, failed))
if failed > 0 then os.exit(1) end
