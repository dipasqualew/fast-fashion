local addonName, ns = ...

---Everything the addon needs from the outside world, in one injectable bag.
---@class WowEnv
---@field print fun(message: string)
---@field transmog TransmogAPI
---@field db table SavedVariables root.
---@field ui UIAPI? Absent under test, and in game until the UI is available.
---@field getPlayerClass fun(): string? Localised class name.
---@field registerSlash fun(name: string, commands: string[], handler: fun(input: string))?
---@field preview TransmogPreviewAPI? Absent where no transmog UI exists.
---@field collections CollectionsAPI? Absent under test; drives the Wardrobe tab.
---@field after fun(seconds: number, callback: fun())? C_Timer.After, for coalescing refreshes.
---@field registerEvents fun(events: string[], handler: fun(event: string))? Client event stream.

---Composition root. Wires the modules together.
---@param env WowEnv
---@return table
function ns.main(env)
    local db = env.db
    local logger = ns.newLogger({
        sink = env.print,
        prefix = "|cff33ff99" .. addonName .. "|r:",
        debug = db.debug,
    })

    local blizzardSets = ns.newBlizzardSetProvider({
        api = env.transmog,
        logger = logger,
    })

    -- The gallery reads every provider in this list; community outfits join it later
    -- without anything downstream changing.
    ---@type OutfitProvider[]
    local providers = { blizzardSets }

    local appearances = ns.newAppearanceResolver({
        api = env.transmog,
        logger = logger,
    })

    local collection = ns.newCollectionResolver({
        appearances = appearances,
        logger = logger,
    })

    local gallery = ns.newGalleryController({
        providers = providers,
        collection = collection,
        logger = logger,
    })

    local preview
    if env.preview then
        preview = ns.newTransmogPreview({
            api = env.preview,
            logger = logger,
        })
    end

    local presenter = ns.newGalleryPresenter({
        gallery = gallery,
        -- Defaulted rather than required, so a caller with no character context still gets
        -- a working gallery; the wearability line just drops the class name.
        getPlayerClass = env.getPlayerClass or function() return nil end,
        preview = preview,
    })

    local frame = ns.newGalleryFrame({
        presenter = presenter,
        ui = env.ui or {},
        logger = logger,
        -- The Wardrobe panel is only a parent once Blizzard_Collections is loaded, so this
        -- is asked at build time rather than now.
        getParent = env.collections and function()
            return env.collections.isLoaded() and env.collections.getGalleryHost() or nil
        end or nil,
    })

    local wardrobeTab
    if env.collections then
        wardrobeTab = ns.newWardrobeTab({
            collections = env.collections,
            gallery = frame,
            logger = logger,
        })
    end

    -- Refreshes are coalesced because the client's data events arrive in bursts of
    -- hundreds; see RefreshScheduler. Without a timer there is nothing to coalesce with,
    -- so the refresh just runs inline.
    local function refreshView()
        gallery.invalidatePending()
        frame.refresh()
    end

    local scheduler
    if env.after then
        scheduler = ns.newRefreshScheduler({
            after = env.after,
            run = refreshView,
        })
    end

    local requestRefresh = scheduler and scheduler.request or refreshView

    if env.registerEvents then
        env.registerEvents({
            -- The item data the provider asked for, arriving. This is the event that turns
            -- a gallery full of "Loading…" into a gallery full of sets.
            "GET_ITEM_INFO_RECEIVED",
            "TRANSMOG_COLLECTION_UPDATED",
            "TRANSMOG_COLLECTION_SOURCE_ADDED",
            "TRANSMOG_COLLECTION_SOURCE_REMOVED",
            "TRANSMOG_SETS_UPDATE_FAVORITE",
            "PLAYER_ENTERING_WORLD",
        }, function()
            requestRefresh()
        end)
    end

    local slash = ns.newSlashCommands({
        gallery = frame,
        wardrobeTab = wardrobeTab,
        controller = gallery,
        logger = logger,
        db = db,
    })

    if env.registerSlash then
        env.registerSlash("FASTFASHION", { "/ff", "/fastfashion" }, slash.handle)
    end

    return {
        logger = logger,
        providers = providers,
        blizzardSets = blizzardSets,
        appearances = appearances,
        collection = collection,
        gallery = gallery,
        presenter = presenter,
        preview = preview,
        frame = frame,
        wardrobeTab = wardrobeTab,
        scheduler = scheduler,
        slash = slash,
    }
end

-- Only auto-start inside the game; under test the harness calls ns.main itself.
if CreateFrame then
    -- SavedVariables only exist once the addon's variables have loaded.
    local bootstrap = CreateFrame("Frame")
    bootstrap:RegisterEvent("ADDON_LOADED")
    bootstrap:SetScript("OnEvent", function(self, _, loaded)
        if loaded ~= addonName then
            return
        end
        self:UnregisterAllEvents()

        FastFashionDB = FastFashionDB or {}

        ns.app = ns.main({
            print = print,
            transmog = {
                getAllSets = C_TransmogSets.GetAllSets,
                getSetAppearances = C_Transmog.GetAllSetAppearancesByID,
                getSourceInfo = C_TransmogCollection.GetSourceInfo,
                getAppearanceSources = C_TransmogCollection.GetAppearanceSources,
                requestItemData = C_Item and C_Item.RequestLoadItemDataByID or nil,
            },
            after = C_Timer.After,
            registerEvents = function(events, handler)
                local listener = CreateFrame("Frame")
                for _, event in ipairs(events) do
                    -- Registration fails on an event this client build does not know, and
                    -- one unknown event must not cost us the rest of the stream.
                    pcall(listener.RegisterEvent, listener, event)
                end
                listener:SetScript("OnEvent", function(_, event)
                    handler(event)
                end)
                return listener
            end,
            preview = {
                isAvailable = function()
                    -- Pending transmog is only accepted while the player is actually at a
                    -- transmogrifier; anywhere else SetPending is rejected.
                    return C_Transmog.IsAtTransmogNPC and C_Transmog.IsAtTransmogNPC() == true
                end,
                clearPending = function()
                    C_Transmog.ClearAllPending()
                end,
                setPending = function(inventorySlot, sourceID)
                    local location = TransmogUtil.GetTransmogLocation(
                        inventorySlot,
                        Enum.TransmogType.Appearance,
                        Enum.TransmogModification.Main
                    )
                    if not location then
                        return false
                    end
                    local ok = pcall(C_Transmog.SetPending, location, sourceID)
                    return ok
                end,
                open = function()
                    if TransmogFrame and not TransmogFrame:IsShown() then
                        TransmogFrame:Show()
                    end
                end,
            },
            collections = {
                isLoaded = function()
                    return C_AddOns.IsAddOnLoaded("Blizzard_Collections") == true
                end,
                load = function()
                    local ok = C_AddOns.LoadAddOn("Blizzard_Collections")
                    return ok == true
                end,
                onLoaded = function(callback)
                    local listener = CreateFrame("Frame")
                    listener:RegisterEvent("ADDON_LOADED")
                    listener:SetScript("OnEvent", function(frame, _, loadedName)
                        if loadedName ~= "Blizzard_Collections" then
                            return
                        end
                        frame:UnregisterAllEvents()
                        callback()
                    end)
                end,
                getWardrobe = function()
                    return WardrobeCollectionFrame
                end,
                ---The gallery is parented to the wardrobe itself, so it inherits the
                ---panel's size and is hidden along with it.
                getGalleryHost = function()
                    return WardrobeCollectionFrame
                end,
                openCollections = function()
                    if CollectionsJournal_LoadUI then
                        CollectionsJournal_LoadUI()
                    end
                    if ShowUIPanel and CollectionsJournal then
                        ShowUIPanel(CollectionsJournal)
                    end
                end,
                ---Blizzard's own wardrobe tabs are `WardrobeCollectionFrameTabN` built from
                ---a template; a third one follows the same shape and reuses the frame's
                ---own tab machinery rather than reimplementing selection.
                addTab = function(wardrobe, label, onSelect, onDeselect)
                    if not wardrobe or not CreateFrame then
                        return nil
                    end

                    local index = (wardrobe.numTabs or 2) + 1
                    local ok, tab = pcall(
                        CreateFrame,
                        "Button",
                        "FastFashionWardrobeTab",
                        wardrobe,
                        "WardrobeCollectionFrameTabTemplate"
                    )
                    if not ok or not tab then
                        return nil
                    end

                    tab:SetID(index)
                    tab:SetText(label)
                    tab:SetPoint("TOPLEFT", _G["WardrobeCollectionFrameTab" .. (index - 1)], "TOPRIGHT", -15, 0)
                    tab:SetScript("OnClick", function(clicked)
                        -- Blizzard's own tabs stay visually selected until something else
                        -- is picked, so deselecting them is our job.
                        for other = 1, index - 1 do
                            local sibling = _G["WardrobeCollectionFrameTab" .. other]
                            if sibling then
                                PanelTemplates_DeselectTab(sibling)
                            end
                        end
                        PanelTemplates_SelectTab(clicked)
                        if wardrobe.ItemsCollectionFrame then
                            wardrobe.ItemsCollectionFrame:Hide()
                        end
                        if wardrobe.SetsCollectionFrame then
                            wardrobe.SetsCollectionFrame:Hide()
                        end
                        onSelect()
                    end)

                    -- Picking one of Blizzard's tabs has to put the gallery away again.
                    hooksecurefunc(wardrobe, "SetTab", function()
                        PanelTemplates_DeselectTab(tab)
                        onDeselect()
                    end)

                    wardrobe.numTabs = index
                    return tab
                end,
            },
            ui = {
                createFrame = CreateFrame,
                parent = UIParent,
                registerEscapeClose = function(globalName)
                    UISpecialFrames[#UISpecialFrames + 1] = globalName
                end,
            },
            getPlayerClass = function()
                -- The localised name is the one the player recognises; the token is not.
                return (UnitClass("player"))
            end,
            registerSlash = function(name, commands, handler)
                for index, command in ipairs(commands) do
                    _G["SLASH_" .. name .. index] = command
                end
                SlashCmdList[name] = handler
            end,
            db = FastFashionDB,
        })
    end)
end
