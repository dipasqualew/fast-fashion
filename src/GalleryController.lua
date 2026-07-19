local _, ns = ...

---@alias GalleryFilter "all" | "wearable" | "unwearable"
---@alias GallerySort "none" | "missingAsc" | "missingDesc"

---@class GalleryController
---@field getFilter fun(): GalleryFilter
---@field setFilter fun(filter: GalleryFilter)
---@field getSort fun(): GallerySort
---@field setSort fun(sort: GallerySort)
---@field getRows fun(): ResolvedOutfit[]
---@field refresh fun()

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
    ---@param left ResolvedOutfit
    ---@param right ResolvedOutfit
    ---@return boolean
    local function byIdentity(left, right)
        if left.outfit.name ~= right.outfit.name then
            return left.outfit.name < right.outfit.name
        end
        return left.outfit.id < right.outfit.id
    end

    ---@param rows ResolvedOutfit[]
    local function applySort(rows)
        if sort == ns.GALLERY_SORT_NONE then
            return
        end

        local ascending = sort == ns.GALLERY_SORT_MISSING_ASC

        table.sort(rows, function(left, right)
            local leftPending, rightPending = isPending(left), isPending(right)
            if leftPending ~= rightPending then
                return rightPending
            end
            if leftPending then
                return byIdentity(left, right)
            end
            if left.missingCount ~= right.missingCount then
                if ascending then
                    return left.missingCount < right.missingCount
                end
                return left.missingCount > right.missingCount
            end
            return byIdentity(left, right)
        end)
    end

    ---Filtering and sorting are both answers about the whole list, so this resolves every
    ---outfit. That cost is paid when the gallery is opened, never at login, and the
    ---resolvers memoise, so it is paid once per session per set.
    ---@return ResolvedOutfit[]
    local function getRows()
        local outfits = allOutfits()
        local rows = {}

        for _, outfit in ipairs(outfits) do
            local row = collection.resolve(outfit)
            if passesFilter(row) then
                rows[#rows + 1] = row
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

        ---Everything the player sees is character-specific and derived, so a refresh drops
        ---the resolutions but leaves the providers' set metadata alone.
        refresh = function()
            collection.refresh()
        end,
    }
end
