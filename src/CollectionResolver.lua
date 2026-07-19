local _, ns = ...

---@class CollectionResolver
---@field resolve fun(outfit: Outfit): ResolvedOutfit
---@field refresh fun() Drops every cached resolution, appearance-level ones included.

---@class CollectionResolverDeps
---@field appearances AppearanceResolver
---@field logger Logger?

local function noop() end

---@param deps CollectionResolverDeps
---@return CollectionResolver
function ns.newCollectionResolver(deps)
    local appearances = deps.appearances
    local logger = deps.logger or { info = noop, debug = noop }

    ---@type table<string, ResolvedOutfit>
    local cache = {}

    ---An outfit whose slots the provider could not build yet. Reported as unresolved with
    ---no counts, never as an empty set the player has fully collected — a 0/0 row claiming
    ---completion is the worst possible lie to tell about a still-loading set.
    ---@param outfit Outfit
    ---@return ResolvedOutfit
    local function unresolvedFor(outfit)
        return {
            outfit = outfit,
            wearable = false,
            collectedCount = 0,
            missingCount = 0,
            totalCount = 0,
            slots = {},
            unresolved = true,
        }
    end

    ---@param outfit Outfit
    ---@return ResolvedOutfit
    local function build(outfit)
        local slots = outfit.slots
        if not slots or #slots == 0 then
            logger.debug("outfit " .. outfit.id .. ": slots not available yet")
            return unresolvedFor(outfit)
        end

        local resolvedSlots = {}
        local collectedCount = 0
        local wearable = true
        local unresolved = false

        for index, slot in ipairs(slots) do
            local resolution = appearances.resolve(slot.appearanceID, slot.preferredSourceID)

            if resolution.collected then
                collectedCount = collectedCount + 1
            end
            -- One slot nobody can wear is enough to put the whole set out of reach, and
            -- one slot still loading is enough to make every count provisional.
            if not resolution.usable then
                wearable = false
            end
            if resolution.unresolved then
                unresolved = true
            end

            resolvedSlots[index] = {
                -- Carried through so the detail pane can name the slot; the appearance is
                -- still the identity, but "Shoulders" is what the player is missing.
                inventorySlot = slot.inventorySlot,
                appearanceID = slot.appearanceID,
                resolvedSourceID = resolution.resolvedSourceID,
                collected = resolution.collected,
                usable = resolution.usable,
                missing = not resolution.collected,
                unresolved = resolution.unresolved,
            }
        end

        local totalCount = #resolvedSlots

        return {
            outfit = outfit,
            wearable = wearable and not unresolved,
            collectedCount = collectedCount,
            missingCount = totalCount - collectedCount,
            totalCount = totalCount,
            slots = resolvedSlots,
            unresolved = unresolved,
        }
    end

    return {
        ---@param outfit Outfit
        ---@return ResolvedOutfit
        resolve = function(outfit)
            local cached = cache[outfit.id]
            if cached then
                return cached
            end

            local resolved = build(outfit)
            -- Deliberately uncached while anything is still streaming in, so the next read
            -- retries instead of freezing a provisional answer in for the session.
            if not resolved.unresolved then
                cache[outfit.id] = resolved
            end

            return resolved
        end,

        refresh = function()
            cache = {}
            appearances.refresh()
        end,
    }
end
