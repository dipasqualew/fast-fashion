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
---@field diagnose fun(): string[]? Reports which client globals this build actually has.

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

    -- The standalone window. Deliberately built with no host: whether it embeds is a fixed
    -- property of the frame, not something it works out from whatever happens to be loaded
    -- when it is first shown. Deciding that late produced a "fallback" window parented to
    -- the hidden Wardrobe panel, which is to say an invisible one.
    local frame = ns.newGalleryFrame({
        presenter = presenter,
        ui = env.ui or {},
        logger = logger,
    })

    local wardrobeTab
    if env.collections then
        wardrobeTab = ns.newWardrobeTab({
            collections = env.collections,
            logger = logger,
            -- A second, separate frame that lives inside the Wardrobe. It shares the
            -- presenter, so a set selected in one is selected in the other.
            newEmbeddedGallery = function(host)
                return ns.newGalleryFrame({
                    presenter = presenter,
                    ui = env.ui or {},
                    logger = logger,
                    getParent = function()
                        return host
                    end,
                })
            end,
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
        diagnose = env.diagnose,
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

---Picks whichever call this client build actually uses to enumerate a set's pieces.
---
---`C_Transmog.GetAllSetAppearancesByID` is what SPEC.md was written against, but it is not
---present on every build — and binding a missing global produced a provider that could
---never resolve a single set, which the UI reported as every row loading forever. So the
---adapter is chosen by what exists, and each shape is normalised to the one the provider
---understands: a list of entries carrying a *sourceID* in `itemModifiedAppearanceID`.
---The provider fills the inventory slot in from GetSourceInfo when an entry has none.
---@return fun(setID: number): table[]?
local function setAppearancesAdapter()
    if type(C_Transmog) == "table" and type(C_Transmog.GetAllSetAppearancesByID) == "function" then
        return C_Transmog.GetAllSetAppearancesByID
    end

    -- Returns `{ appearanceID, collected }`, where `appearanceID` is a sourceID despite
    -- the name — the same trap SPEC.md records for `itemModifiedAppearanceID`.
    if type(C_TransmogSets.GetSetPrimaryAppearances) == "function" then
        return function(setID)
            local primary = C_TransmogSets.GetSetPrimaryAppearances(setID)
            if not primary then
                return nil
            end
            local items = {}
            for index, entry in ipairs(primary) do
                items[index] = { itemModifiedAppearanceID = entry.appearanceID }
            end
            return items
        end
    end

    -- Bare sourceIDs, no wrapper table.
    if type(C_TransmogSets.GetAllSourceIDs) == "function" then
        return function(setID)
            local sourceIDs = C_TransmogSets.GetAllSourceIDs(setID)
            if not sourceIDs then
                return nil
            end
            local items = {}
            for index, sourceID in ipairs(sourceIDs) do
                items[index] = { itemModifiedAppearanceID = sourceID }
            end
            return items
        end
    end

    -- Nothing usable. Returning a function that answers "not yet" keeps the provider's
    -- contract intact; the gallery reports loading rather than throwing on every row.
    return function()
        return nil
    end
end

---The transmog preview, or nothing when this client does not expose the calls it needs.
---
---Returning nil is the honest answer and a supported one: the presenter greys **Preview
---Set** out with a reason rather than offering a button that cannot work. Binding the
---names anyway would turn every click into a Lua error, which the client hides by default
---— so the failure would be invisible rather than merely disappointing.
---@return TransmogPreviewAPI?
local function previewAdapter()
    local setPending = type(C_Transmog) == "table" and C_Transmog.SetPending
    local clearPending = type(C_Transmog) == "table" and C_Transmog.ClearAllPending
    local getLocation = type(TransmogUtil) == "table" and TransmogUtil.GetTransmogLocation

    if type(setPending) ~= "function" or type(clearPending) ~= "function" or type(getLocation) ~= "function" then
        return nil
    end

    return {
        isAvailable = function()
            -- Pending transmog is only accepted while the player is actually at a
            -- transmogrifier; anywhere else SetPending is rejected. The frame being open
            -- is the fallback tell, for a client that does not expose the query — without
            -- it a missing API reads as "never at a vendor".
            if type(C_Transmog.IsAtTransmogNPC) == "function" then
                return C_Transmog.IsAtTransmogNPC() == true
            end
            return TransmogFrame ~= nil and TransmogFrame:IsShown() == true
        end,

        clearPending = function()
            pcall(clearPending)
        end,

        setPending = function(inventorySlot, sourceID)
            local ok, location = pcall(
                getLocation,
                inventorySlot,
                Enum.TransmogType.Appearance,
                Enum.TransmogModification.Main
            )
            if not ok or not location then
                return false
            end
            return (pcall(setPending, location, sourceID))
        end,

        open = function()
            if TransmogFrame and not TransmogFrame:IsShown() then
                TransmogFrame:Show()
            end
        end,
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
                getSetAppearances = setAppearancesAdapter(),
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
            preview = previewAdapter(),
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

                    -- Anchoring to the last of Blizzard's own tabs only works if one is
                    -- actually there under the name we expect. Everything from here to the
                    -- hook is guesswork about another addon's internals, so it runs inside
                    -- a pcall: a wrong guess must cost us the tab, never the player's
                    -- Appearances panel.
                    local index = (wardrobe.numTabs or 2) + 1
                    local anchor = _G["WardrobeCollectionFrameTab" .. (index - 1)]
                    if not anchor then
                        return nil
                    end

                    local ok, tab = pcall(function()
                        local built = CreateFrame(
                            "Button",
                            "FastFashionWardrobeTab",
                            wardrobe,
                            "WardrobeCollectionFrameTabTemplate"
                        )
                        built:SetID(index)
                        built:SetText(label)
                        built:SetPoint("TOPLEFT", anchor, "TOPRIGHT", -15, 0)
                        return built
                    end)
                    if not ok or not tab then
                        return nil
                    end

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
                    -- A client that does not expose SetTab still gets a working tab; it
                    -- just will not auto-close, which beats erroring out of the attach.
                    if type(wardrobe.SetTab) == "function" then
                        pcall(hooksecurefunc, wardrobe, "SetTab", function()
                            PanelTemplates_DeselectTab(tab)
                            onDeselect()
                        end)
                    end

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
            ---Everything here is a global this addon guesses the existence of. The suite
            ---cannot check any of them, so the addon reports them on request instead.
            diagnose = function()
                local lines = {}

                local function report(label, value)
                    lines[#lines + 1] = label .. ": " .. (value and "yes" or "MISSING")
                end

                report("C_Item.RequestLoadItemDataByID", C_Item and C_Item.RequestLoadItemDataByID)
                report("TransmogUtil.GetTransmogLocation", TransmogUtil and TransmogUtil.GetTransmogLocation)
                report("Blizzard_Collections loaded", C_AddOns.IsAddOnLoaded("Blizzard_Collections"))
                report("WardrobeCollectionFrame", WardrobeCollectionFrame)
                report("WardrobeCollectionFrameTab2", _G["WardrobeCollectionFrameTab2"])
                report("WardrobeCollectionFrame.SetTab", WardrobeCollectionFrame and WardrobeCollectionFrame.SetTab)
                report("wardrobe tab attached", ns.app and ns.app.wardrobeTab and ns.app.wardrobeTab.isAttached())

                local sets = C_TransmogSets.GetAllSets()
                lines[#lines + 1] = "sets reported by client: " .. (sets and #sets or "none yet")

                -- Listing the namespace beats testing names one at a time: every guess I
                -- make about what this client calls a function is another round trip, and
                -- the client already knows the answer.
                local function listFunctions(label, namespace)
                    if type(namespace) ~= "table" then
                        lines[#lines + 1] = label .. ": MISSING"
                        return
                    end
                    local names = {}
                    for key, value in pairs(namespace) do
                        if type(value) == "function" then
                            names[#names + 1] = key
                        end
                    end
                    table.sort(names)
                    lines[#lines + 1] = label .. " (" .. #names .. "): " .. table.concat(names, ", ")
                end

                listFunctions("C_Transmog", C_Transmog)
                listFunctions("C_TransmogSets", C_TransmogSets)

                -- Which call actually yields a set's pieces, asked of a real set rather
                -- than assumed. This is the one that decides whether the gallery can show
                -- anything at all, so it is answered by calling, not by reading a name.
                local sampleID = sets and sets[1] and sets[1].setID
                if not sampleID then
                    lines[#lines + 1] = "no sample set to probe"
                    return lines
                end

                lines[#lines + 1] = "probing set " .. sampleID .. " (" .. (sets[1].name or "?") .. "):"

                local function probe(label, fn, ...)
                    if type(fn) ~= "function" then
                        lines[#lines + 1] = "  " .. label .. ": MISSING"
                        return
                    end
                    local ok, result = pcall(fn, ...)
                    if not ok then
                        lines[#lines + 1] = "  " .. label .. ": ERROR " .. tostring(result)
                    elseif type(result) ~= "table" then
                        lines[#lines + 1] = "  " .. label .. ": " .. tostring(result)
                    else
                        local first = result[1]
                        local shape = ""
                        if type(first) == "table" then
                            local keys = {}
                            for key in pairs(first) do
                                keys[#keys + 1] = key
                            end
                            table.sort(keys)
                            shape = " first={" .. table.concat(keys, ",") .. "}"
                        elseif first ~= nil then
                            shape = " first=" .. tostring(first)
                        end
                        lines[#lines + 1] = "  " .. label .. ": " .. #result .. " entries" .. shape
                    end
                end

                probe("C_Transmog.GetAllSetAppearancesByID", C_Transmog.GetAllSetAppearancesByID, sampleID)
                probe("C_TransmogSets.GetSetPrimaryAppearances", C_TransmogSets.GetSetPrimaryAppearances, sampleID)
                probe("C_TransmogSets.GetAllSourceIDs", C_TransmogSets.GetAllSourceIDs, sampleID)

                return lines
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
