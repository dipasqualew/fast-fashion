local _, ns = ...

---One visual appearance, answered for the logged-in character.
---
---`usable` and `collected` are deliberately separate from `unresolved`: a character who
---cannot wear any source is a real, final answer, whereas a client that has not streamed
---the sources in yet is not an answer at all. Collapsing the two would tell a player a set
---is out of reach when it is merely still loading.
---@class AppearanceResolution
---@field appearanceID number
---@field resolvedSourceID number? Best source to hand the preview; nil when nothing can be shown.
---@field usable boolean Some source is valid for this character to transmog.
---@field collected boolean Some *usable* source is already collected on the account.
---@field unresolved boolean The client has not answered yet; ask again later.

---@class AppearanceResolver
---@field resolve fun(appearanceID: number, preferredSourceID: number?): AppearanceResolution
---@field refresh fun() Drops every cache; for when the client signals the collection changed.
---@field invalidatePending fun() Drops only the "not yet" answers, so they are retried once.

---@class AppearanceResolverDeps
---@field api TransmogAPI
---@field logger Logger?

local function noop() end

---An account can own a source the current character cannot put on. Per SPEC "Definitions",
---that does not count as collected for this character, so ownership is only ever read
---together with usability.
---@param source AppearanceSourceInfo
---@return boolean
local function isUsable(source)
    return source.isValidSourceForPlayer == true
end

---@param source AppearanceSourceInfo
---@return boolean
local function isCollected(source)
    return source.isCollected == true
end

---Preview is allowed to fall back to a source the player has not collected, but only when
---the client says it can actually be drawn on this character.
---@param source AppearanceSourceInfo
---@return boolean
local function canPreview(source)
    return source.canDisplayOnPlayer == true
end

---@param deps AppearanceResolverDeps
---@return AppearanceResolver
function ns.newAppearanceResolver(deps)
    local api = deps.api
    local logger = deps.logger or { info = noop, debug = noop }

    ---@type table<number, AppearanceResolution> Final answers, good until the collection changes.
    local cache = {}
    ---Provisional "the client has not answered yet" results.
    ---
    ---These are cached, which looks wrong until you count the calls: the gallery re-reads
    ---every visible row on every redraw, and an uncached miss meant re-asking the client
    ---for the same absent data on every scroll tick. They are held only until new data
    ---actually arrives — `invalidatePending` is driven by the client's own streaming
    ---events — so a pending answer is still retried, just once per delivery instead of
    ---once per frame.
    ---@type table<number, AppearanceResolution>
    local pending = {}

    ---@param appearanceID number
    ---@return AppearanceResolution
    local function unresolvedFor(appearanceID)
        local result = {
            appearanceID = appearanceID,
            resolvedSourceID = nil,
            usable = false,
            collected = false,
            unresolved = true,
        }
        pending[appearanceID] = result
        return result
    end

    ---Ranked source choice, best first: a source the player owns and can wear, then one
    ---they can wear but have not collected, then anything the client will at least draw.
    ---The last rung exists so the preview can still show a look the character cannot
    ---legally transmog yet.
    ---@param sources AppearanceSourceInfo[]
    ---@return number? sourceID
    ---@return boolean usable
    ---@return boolean collected
    local function choose(sources)
        local usableOwned, usableAny, displayable

        for _, source in ipairs(sources) do
            local id = source.sourceID
            if id then
                if isUsable(source) then
                    if isCollected(source) then
                        usableOwned = usableOwned or id
                    else
                        usableAny = usableAny or id
                    end
                elseif canPreview(source) then
                    displayable = displayable or id
                end
            end
        end

        local usable = usableOwned ~= nil or usableAny ~= nil
        return usableOwned or usableAny or displayable, usable, usableOwned ~= nil
    end

    ---The lookup that makes a Druid set wearable by a Rogue: the set names one item, but
    ---any source sharing the visual reproduces the look, and those alternatives are where
    ---an unrestricted version of a class piece lives.
    ---@param appearanceID number
    ---@param preferredSourceID number?
    ---@return AppearanceResolution
    local function resolve(appearanceID, preferredSourceID)
        local cached = cache[appearanceID] or pending[appearanceID]
        if cached then
            return cached
        end

        local sources = api.getAppearanceSources(appearanceID)
        -- An empty list is the client answering "not yet" too: every real visual has at
        -- least the source it came from, so zero sources means the data has not arrived.
        if not sources or #sources == 0 then
            logger.debug("appearance " .. appearanceID .. ": sources not available yet")
            return unresolvedFor(appearanceID)
        end

        local sourceID, usable, collected = choose(sources)

        ---@type AppearanceResolution
        local resolution = {
            appearanceID = appearanceID,
            -- The set's own item is the best guess only when nothing better was found;
            -- a collected alternative always wins over the piece Blizzard shipped.
            resolvedSourceID = sourceID or preferredSourceID,
            usable = usable,
            collected = collected,
            unresolved = false,
        }

        cache[appearanceID] = resolution
        return resolution
    end

    return {
        resolve = resolve,

        refresh = function()
            cache = {}
            pending = {}
        end,

        ---Final answers survive: nothing the client streams in can change a resolution it
        ---has already fully answered, and re-deriving thousands of them on every batch of
        ---GET_ITEM_INFO_RECEIVED is exactly the stall this cache exists to prevent.
        invalidatePending = function()
            pending = {}
        end,
    }
end
