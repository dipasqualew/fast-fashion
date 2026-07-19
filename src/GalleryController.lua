local _, ns = ...

---@alias GalleryFilter "all" | "wearable" | "unwearable"
---@alias GallerySort "none" | "missingAsc" | "missingDesc"

---One entry of the gallery list.
---
---`resolved` is populated only when the current filter or sort could not be answered
---without it. In the default view neither can be answered *wrongly* by leaving it out —
---"all sets, in the client's own order" is a question about the set list alone — so the
---row is handed over unresolved and whoever draws it resolves the handful that are
---actually on screen. That is the difference between opening the gallery costing one
---metadata call and costing a full collection sweep of every set the client knows.
---@class GalleryRow
---@field outfit Outfit
---@field resolved ResolvedOutfit?

---@class GalleryController
---@field getFilter fun(): GalleryFilter
---@field setFilter fun(filter: GalleryFilter)
---@field getSort fun(): GallerySort
---@field setSort fun(sort: GallerySort)
---@field getRows fun(): GalleryRow[]
---@field resolve fun(outfit: Outfit): ResolvedOutfit Resolves one row, on demand and cached.
---@field needsFullResolution fun(): boolean Whether the current view had to resolve everything.
---@field refresh fun()
---@field invalidatePending fun()

---@class GalleryControllerDeps
---@field providers OutfitProvider[]
---@field collection CollectionResolver
---@field logger Logger?

ns.GALLERY_FILTER_ALL = "all"
ns.GALLERY_FILTER_WEARABLE = "wearable"
ns.GALLERY_FILTER_UNWEARABLE = "unwearable"

ns.GALLERY_SORT_NONE = "none"
ns.GALLERY_SORT_MISSING_ASC = "missingAsc"
ns.GALLERY_SORT_MISSING_DESC = "missingDesc"

local FILTERS = {
    all = true,
    wearable = true,
    unwearable = true,
}

local SORTS = {
    none = true,
    missingAsc = true,
    missingDesc = true,
}

local function noop() end

---A row the player can be told nothing definite about yet. It survives every filter — a
---set must never vanish from the gallery merely because its data is still arriving — and
---sorts to the bottom, where a provisional count cannot be mistaken for a real one.
---@param row ResolvedOutfit
---@return boolean
local function isPending(row)
    return row.unresolved == true
end

---@param deps GalleryControllerDeps
---@return GalleryController
function ns.newGalleryController(deps)
    local providers = deps.providers
    local collection = deps.collection
    local logger = deps.logger or { info = noop, debug = noop }

    ---@type GalleryFilter
    local filter = ns.GALLERY_FILTER_ALL
    ---@type GallerySort
    local sort = ns.GALLERY_SORT_NONE

    ---@return Outfit[]
    local function allOutfits()
        local outfits = {}
        for _, provider in ipairs(providers) do
            for _, outfit in ipairs(provider.getOutfits()) do
                outfits[#outfits + 1] = outfit
            end
        end
        return outfits
    end

    ---@param row ResolvedOutfit
    ---@return boolean
    local function passesFilter(row)
        if filter == ns.GALLERY_FILTER_ALL or isPending(row) then
            return true
        end
        -- Wearability is the resolver's answer over every available source, never the
        -- set's original class restriction — that is the whole point of the filter.
        if filter == ns.GALLERY_FILTER_WEARABLE then
            return row.wearable
        end
        return not row.wearable
    end

    ---Ties are broken by name and then id so the list holds still between reads; without
    ---it, two sets missing the same count would swap places on every redraw.
    ---@param left GalleryRow
    ---@param right GalleryRow
    ---@return boolean
    local function byIdentity(left, right)
        if left.outfit.name ~= right.outfit.name then
            return left.outfit.name < right.outfit.name
        end
        return left.outfit.id < right.outfit.id
    end

    ---Only ever called for a sort that forced full resolution, so every row here carries
    ---its `resolved`.
    ---@param rows GalleryRow[]
    local function applySort(rows)
        if sort == ns.GALLERY_SORT_NONE then
            return
        end

        local ascending = sort == ns.GALLERY_SORT_MISSING_ASC

        table.sort(rows, function(left, right)
            local leftPending, rightPending = isPending(left.resolved), isPending(right.resolved)
            if leftPending ~= rightPending then
                return rightPending
            end
            if leftPending then
                return byIdentity(left, right)
            end
            if left.resolved.missingCount ~= right.resolved.missingCount then
                if ascending then
                    return left.resolved.missingCount < right.resolved.missingCount
                end
                return left.resolved.missingCount > right.resolved.missingCount
            end
            return byIdentity(left, right)
        end)
    end

    ---Whether the current view is a question about the whole list. A wearability filter
    ---has to know every set's wearability, and a missing-count sort has to know every
    ---set's count — but the default view asks neither, and paying for both regardless is
    ---what made opening the gallery stall on a client reporting thousands of sets.
    ---@return boolean
    local function needsFullResolution()
        return filter ~= ns.GALLERY_FILTER_ALL or sort ~= ns.GALLERY_SORT_NONE
    end

    ---@return GalleryRow[]
    local function getRows()
        local outfits = allOutfits()
        local rows = {}

        if not needsFullResolution() then
            for index, outfit in ipairs(outfits) do
                rows[index] = { outfit = outfit }
            end
            return rows
        end

        for _, outfit in ipairs(outfits) do
            local resolved = collection.resolve(outfit)
            if passesFilter(resolved) then
                rows[#rows + 1] = { outfit = outfit, resolved = resolved }
            end
        end

        applySort(rows)
        return rows
    end

    return {
        getFilter = function()
            return filter
        end,

        ---@param value GalleryFilter
        setFilter = function(value)
            if not FILTERS[value] then
                logger.debug("ignoring unknown filter " .. tostring(value))
                return
            end
            filter = value
        end,

        getSort = function()
            return sort
        end,

        ---@param value GallerySort
        setSort = function(value)
            if not SORTS[value] then
                logger.debug("ignoring unknown sort " .. tostring(value))
                return
            end
            sort = value
        end,

        getRows = getRows,
        needsFullResolution = needsFullResolution,

        ---@param outfit Outfit
        ---@return ResolvedOutfit
        resolve = function(outfit)
            return collection.resolve(outfit)
        end,

        ---Everything the player sees is character-specific and derived, so a refresh drops
        ---the resolutions but leaves the providers' set metadata alone.
        refresh = function()
            collection.refresh()
        end,

        ---The client has streamed more data in: retire the "not yet" answers so they are
        ---asked again, and leave the settled ones alone.
        invalidatePending = function()
            collection.invalidatePending()
            for _, provider in ipairs(providers) do
                if provider.invalidatePending then
                    provider.invalidatePending()
                end
            end
        end,
    }
end
