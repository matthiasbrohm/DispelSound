-- DispelSound - Options.lua
-- Options page in the game's own settings window (Esc > Options > AddOns), /dsound opens it.

local ADDON, ns = ...
local L = ns.L

function ns.BuildOptions()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting
        and Settings.RegisterAddOnCategory and Settings.VarType) then
        return
    end
    local db = ns.db
    local defaults = ns.DEFAULTS
    local category, layout = Settings.RegisterVerticalLayoutCategory("DispelSound")

    local function Header(text)
        if layout and CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end

    local function Proxy(variable, varType, name, default, get, set)
        return Settings.RegisterProxySetting(category, "DispelSound_" .. variable, varType, name, default, get, set)
    end

    local function Checkbox(key, name, tip)
        local setting = Proxy(key, Settings.VarType.Boolean, name, defaults[key],
            function() return db[key] end,
            function(value) db[key] = value and true or false; ns.Refresh() end)
        return Settings.CreateCheckbox(category, setting, tip)
    end

    Checkbox("enabled", L.OPT_ENABLED, L.OPT_ENABLED_TIP)

    Header(L.OPT_HEADER_UNITS)
    Checkbox("self", L.OPT_SELF, L.OPT_SELF_TIP)
    Checkbox("party", L.OPT_PARTY, L.OPT_PARTY_TIP)
    Checkbox("raid", L.OPT_RAID, L.OPT_RAID_TIP)

    Header(L.OPT_HEADER_SOUND)
    do
        local function SoundOptions()
            local container = Settings.CreateControlTextContainer()
            for _, choice in ipairs(ns.SoundChoices()) do container:Add(choice.key, choice.name) end
            if db.custom then container:Add("custom", L.OPT_CUSTOM) end
            return container:GetData()
        end
        local setting = Proxy("sound", Settings.VarType.String, L.OPT_SOUND, defaults.sound,
            function() return db.sound end,
            function(value) db.sound = value; ns.PlayTest(); ns.Refresh() end)
        Settings.CreateDropdown(category, setting, SoundOptions, L.OPT_SOUND_TIP)

        local function ChannelOptions()
            local container = Settings.CreateControlTextContainer()
            for _, channel in ipairs(ns.CHANNELS) do container:Add(channel, channel) end
            return container:GetData()
        end
        local channel = Proxy("channel", Settings.VarType.String, L.OPT_CHANNEL, defaults.channel,
            function() return db.channel end,
            function(value) db.channel = value; ns.Refresh() end)
        Settings.CreateDropdown(category, channel, ChannelOptions, L.OPT_CHANNEL_TIP)

        local throttle = Proxy("throttle", Settings.VarType.Number, L.OPT_THROTTLE, defaults.throttle,
            function() return db.throttle end,
            function(value) db.throttle = value; ns.Refresh() end)
        local options = Settings.CreateSliderOptions(0, 5, 0.5)
        if options.SetLabelFormatter and MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
                return ("%.1f s"):format(value)
            end)
        end
        Settings.CreateSlider(category, throttle, options, L.OPT_THROTTLE_TIP)

        if layout and CreateSettingsButtonInitializer then
            layout:AddInitializer(CreateSettingsButtonInitializer(L.OPT_TEST, L.OPT_TEST_BUTTON, ns.PlayTest, L.OPT_SOUND_TIP, true))
        end
    end

    Header(L.OPT_HEADER_TYPES)
    do
        local auto = Checkbox("autoTypes", L.OPT_AUTO, L.OPT_AUTO_TIP)
        local function Manual() return not db.autoTypes end
        for _, typ in ipairs({ "Magic", "Poison", "Disease", "Curse" }) do
            local setting = Proxy("type" .. typ, Settings.VarType.Boolean, L["TYPE_" .. typ], defaults.types[typ],
                function() return db.types[typ] end,
                function(value) db.types[typ] = value and true or false; ns.Refresh() end)
            local initializer = Settings.CreateCheckbox(category, setting, L.OPT_TYPE_TIP)
            if initializer and initializer.SetParentInitializer and auto then
                initializer:SetParentInitializer(auto, Manual)
            end
        end
    end

    Settings.RegisterAddOnCategory(category)
    ns.categoryID = category:GetID()
end
