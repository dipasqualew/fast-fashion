local addonName, ns = ...

---Everything the addon needs from the outside world, in one injectable bag.
---@class WowEnv
---@field print fun(message: string)
---@field transmog TransmogAPI
---@field db table SavedVariables root.

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

    -- The gallery will read every provider in this list; community outfits join it later
    -- without anything downstream changing.
    ---@type OutfitProvider[]
    local providers = { blizzardSets }

    return {
        logger = logger,
        providers = providers,
        blizzardSets = blizzardSets,
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
            },
            db = FastFashionDB,
        })
    end)
end
