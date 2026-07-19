local _, ns = ...

---The slice of the client's transmog API this provider needs, as an injectable adapter.
---Field names are ours; Main.lua binds them to the real globals.
---@class TransmogAPI
---@field getAllSets fun(): TransmogSetInfo[]? C_TransmogSets.GetAllSets.
---@field getSetAppearances fun(setID: number): TransmogSetItemInfo[]? C_Transmog.GetAllSetAppearancesByID.
---@field getSourceInfo fun(sourceID: number): AppearanceSourceInfo? C_TransmogCollection.GetSourceInfo.
---@field getAppearanceSources fun(appearanceID: number): AppearanceSourceInfo[]? GetAppearanceSources.
---@field requestItemData fun(itemID: number)? C_Item.RequestLoadItemDataByID. Optional; absent under test.

---What GetAllSets hands back. Documented here because the field names are Blizzard's and
---the provider is the only module allowed to know them.
---@class TransmogSetInfo
---@field setID number
---@field name string?
---@field baseSetID number?
---@field description string?
---@field label string?
---@field expansionID number?
---@field patchID number?
---@field classMask number?
---@field requiredFaction string? "Alliance" | "Horde" | nil.
---@field validForCharacter boolean?
---@field hiddenUntilCollected boolean?
---@field uiOrder number?

---@class TransmogSetItemInfo
---@field itemID number
---@field itemModifiedAppearanceID number A *sourceID*, despite the name.
---@field invSlot number?
---@field invType string?

---@class AppearanceSourceInfo
---@field visualID number? The canonical appearance ID.
---@field sourceID number?
---@field itemID number?
---@field inventorySlot number?
---@field isCollected boolean?
---@field isValidSourceForPlayer boolean? Whether this character may transmog this source.
---@field canDisplayOnPlayer boolean? Whether the client will at least draw it in a preview.

---@class BlizzardSetProvider : OutfitProvider
---@field getOutfits fun(): Outfit[]
---@field getOutfit fun(id: string): Outfit?
---@field getVariantsOf fun(id: string): Outfit[]
---@field refresh fun() Drops every cache; for when the client signals set data changed.
---@field invalidatePending fun() Drops only the sets that could not be built yet.

---@class BlizzardSetProviderDeps
---@field api TransmogAPI
---@field logger Logger?

local ORIGIN = "blizzard"

local function noop() end

---Blizzard reports a base set's own ID as its `baseSetID`; the model reserves that field
---for "this is a variant *of* something else", so self-references become nil.
---@param set TransmogSetInfo
---@return number?
local function baseSetIdOf(set)
    if not set.baseSetID or set.baseSetID == set.setID then
        return nil
    end
    return set.baseSetID
end

---@param deps BlizzardSetProviderDeps
---@return BlizzardSetProvider
function ns.newBlizzardSetProvider(deps)
    local api = deps.api
    local logger = deps.logger or { info = noop, debug = noop }

    ---@type Outfit[]?
    local outfits
    ---@type table<string, Outfit>
    local byId = {}
    ---@type table<number, OutfitSlot[]>
    local slotsBySetId = {}
    ---Sets whose sources have not all streamed in. Remembering the failure is what keeps a
    ---redraw from re-walking every item of every unbuilt set; the entry is dropped as soon
    ---as the client signals it has delivered more data.
    ---@type table<number, boolean>
    local pendingSetIds = {}

    ---Turns the set's items into slots keyed by *visual*, which is the whole trick: the
    ---item Blizzard shipped is only one way to wear the look, and resolving it to a
    ---visualID is what later lets a Rogue reproduce a Druid set.
    ---
    ---Returns `nil` when any source has not streamed in yet. An unresolved piece is not a
    ---missing piece, and caching a half-built set would freeze that lie in for the
    ---session — so the caller retries instead.
    ---@param setID number
    ---@return OutfitSlot[]?
    local function buildSlots(setID)
        local items = api.getSetAppearances(setID)
        if not items then
            logger.debug("set " .. setID .. ": appearances not available yet")
            return nil
        end

        local slots = {}
        local seenSlot = {}
        local incomplete = false

        for _, item in ipairs(items) do
            local sourceID = item.itemModifiedAppearanceID
            local source = sourceID and api.getSourceInfo(sourceID) or nil

            if not source or not source.visualID then
                logger.debug("set " .. setID .. ": source " .. tostring(sourceID) .. " not resolved yet")
                -- The client does not stream item data at an addon just because the addon
                -- wants it: without this the set stays unresolved forever and the gallery
                -- reads "Loading…" for the whole session. Asking is what makes the retry
                -- eventually succeed. Every gap is requested before giving up, so one pass
                -- primes the whole set rather than one item of it.
                if api.requestItemData and item.itemID then
                    api.requestItemData(item.itemID)
                end
                incomplete = true
            else
                local inventorySlot = item.invSlot or source.inventorySlot
                if not inventorySlot then
                    -- Nothing downstream can place this piece on a character, and guessing
                    -- a slot would put the wrong appearance on the preview.
                    logger.debug("set " .. setID .. ": source " .. tostring(sourceID) .. " has no inventory slot")
                elseif seenSlot[inventorySlot] then
                    -- Sets occasionally list several items for one slot (a recolour shipped
                    -- in the same set). First wins, so the outfit stays a single look.
                    logger.debug("set " .. setID .. ": duplicate entry for slot " .. inventorySlot)
                else
                    seenSlot[inventorySlot] = true
                    slots[#slots + 1] = {
                        inventorySlot = inventorySlot,
                        appearanceID = source.visualID,
                        preferredSourceID = source.sourceID or sourceID,
                        preferredItemID = source.itemID or item.itemID,
                    }
                end
            end
        end

        -- A partial set is still not an answer: the slots that did resolve would produce a
        -- collected count over the wrong denominator, which reads as a real number and is
        -- not one. Caching that is the lie the whole `unresolved` distinction exists to
        -- prevent, so the build is discarded and retried.
        if incomplete then
            return nil
        end

        table.sort(slots, function(left, right)
            return left.inventorySlot < right.inventorySlot
        end)

        return slots
    end

    ---@param setID number
    ---@return OutfitSlot[]
    local function slotsFor(setID)
        local cached = slotsBySetId[setID]
        if cached then
            return cached
        end
        -- Already known to be waiting on the client. Re-walking its items would cost a
        -- GetSourceInfo call per piece and reach the same conclusion; the retry happens
        -- when `invalidatePending` clears this, driven by the client's own data events.
        if pendingSetIds[setID] then
            return {}
        end

        local built = buildSlots(setID)
        if not built then
            pendingSetIds[setID] = true
            return {}
        end

        slotsBySetId[setID] = built
        return built
    end

    ---Reading `outfit.slots` is what triggers item and source resolution, so listing the
    ---gallery costs one cheap metadata call and the expensive work happens per row, as the
    ---player actually looks at them.
    local lazySlots = {
        __index = function(outfit, key)
            if key ~= "slots" then
                return nil
            end
            return slotsFor(outfit.blizzardSetID)
        end,
    }

    ---@param set TransmogSetInfo
    ---@return Outfit
    local function toOutfit(set)
        return setmetatable({
            id = ns.outfitId(ORIGIN, set.setID),
            origin = ORIGIN,
            name = set.name,
            description = set.description or set.label,
            blizzardSetID = set.setID,
            baseSetID = baseSetIdOf(set),
            expansionID = set.expansionID,
            patchID = set.patchID,
            classMask = set.classMask,
            requiredFaction = set.requiredFaction,
            -- The game's answer to the *original* restriction. Recorded as metadata and
            -- never as the wearability answer, which only CollectionResolver can give.
            originallyValidForCharacter = set.validForCharacter,
            tags = {},
        }, lazySlots)
    end

    ---@return Outfit[]
    local function build()
        local sets = api.getAllSets()
        if not sets then
            logger.debug("set list not available yet")
            return {}
        end

        local built = {}
        for _, set in ipairs(sets) do
            -- A nameless set has nothing to show in a gallery row; hidden sets are kept,
            -- because "hidden until collected" is a state the gallery wants to display.
            if set.setID and set.name and set.name ~= "" then
                local outfit = toOutfit(set)
                built[#built + 1] = outfit
                byId[outfit.id] = outfit
            end
        end

        return built
    end

    ---@return Outfit[]
    local function getOutfits()
        if not outfits or #outfits == 0 then
            -- An empty result means the client had not loaded sets yet, so retry rather
            -- than caching "this account has no sets" for the session.
            outfits = build()
        end
        return outfits
    end

    return {
        getOutfits = getOutfits,

        ---@param id string
        ---@return Outfit?
        getOutfit = function(id)
            getOutfits()
            return byId[id]
        end,

        ---Every other member of this outfit's family: its siblings if it is a variant, its
        ---recolours if it is a base. Grouping is on baseSetID, which the MVP takes at face
        ---value rather than paying for a GetVariantSets call per set.
        ---@param id string
        ---@return Outfit[]
        getVariantsOf = function(id)
            local all = getOutfits()
            local outfit = byId[id]
            if not outfit then
                return {}
            end

            local family = outfit.baseSetID or outfit.blizzardSetID
            local variants = {}
            for _, candidate in ipairs(all) do
                local candidateFamily = candidate.baseSetID or candidate.blizzardSetID
                if candidateFamily == family and candidate.id ~= id then
                    variants[#variants + 1] = candidate
                end
            end

            return variants
        end,

        refresh = function()
            outfits = nil
            byId = {}
            slotsBySetId = {}
            pendingSetIds = {}
        end,

        ---Built sets are kept: their slots are a property of the set, not of the
        ---character, so nothing that streams in later changes them.
        invalidatePending = function()
            pendingSetIds = {}
            if not outfits or #outfits == 0 then
                outfits = nil
            end
        end,
    }
end
