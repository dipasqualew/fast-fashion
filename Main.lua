local addonName, ns = ...

---Everything the addon needs from the outside world, in one injectable bag.
---@class WowEnv
---@field print fun(message: string)
---@field transmog TransmogAPI
---@field db table SavedVariables root.
---@field ui UIAPI? Absent under test, and in game until the UI is available.
---@field getPlayerClass fun(): string? Localised class name.
---@field registerSlash fun(name: string, commands: string[], handler: fun(input: string))?

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

    local presenter = ns.newGalleryPresenter({
        gallery = gallery,
        -- Defaulted rather than required, so a caller with no character context still gets
        -- a working gallery; the wearability line just drops the class name.
        getPlayerClass = env.getPlayerClass or function() return nil end,
    })

    local frame = ns.newGalleryFrame({
        presenter = presenter,
        ui = env.ui or {},
        logger = logger,
    })

    local slash = ns.newSlashCommands({
        gallery = frame,
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
        frame = frame,
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
