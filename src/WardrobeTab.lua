local _, ns = ...

---Puts the gallery in Collections → Appearances as a third tab.
---
---Blizzard_Collections is a load-on-demand addon: it does not exist at login, and it may
---never exist in a session where the player never opens their collections. So attaching is
---a three-step dance — ask whether it is loaded, register interest if it is not, attach
---when it arrives — and every step has to survive the answer being "no". A gallery that
---breaks the default Appearances panel is worse than one the player has to type `/ff` to
---reach, so every failure here falls back to the standalone window rather than erroring.
---@class WardrobeTab
---@field attach fun(): boolean Attaches now if possible; returns whether the tab exists.
---@field isAttached fun(): boolean
---@field select fun(): boolean Brings the tab to the front; false when there is no tab to show.

---The slice of Blizzard's collections UI this needs. Every global lives behind here.
---@class CollectionsAPI
---@field isLoaded fun(): boolean Whether Blizzard_Collections is loaded.
---@field load fun(): boolean Load it on demand; false when the client refuses.
---@field onLoaded fun(callback: fun()) Call back once it loads.
---@field getWardrobe fun(): any? The WardrobeCollectionFrame, once it exists.
---@field addTab fun(wardrobe: any, label: string, onSelect: fun(), onDeselect: fun()): any? Adds the tab.
---@field openCollections fun() Show the Collections frame on the Appearances panel.

---@class WardrobeTabDeps
---@field collections CollectionsAPI
---@field newEmbeddedGallery fun(host: any): GalleryFrame Built only once a host frame exists.
---@field logger Logger?

local TAB_LABEL = "Fast Fashion"

local function noop() end

---@param deps WardrobeTabDeps
---@return WardrobeTab
function ns.newWardrobeTab(deps)
    local collections = deps.collections
    local newEmbeddedGallery = deps.newEmbeddedGallery
    local logger = deps.logger or { info = noop, debug = noop }

    local tab
    ---@type GalleryFrame?
    local embedded
    local attached = false
    ---Set once so a failed attach is not retried on every click; the reason it failed
    ---(a UI that does not expose what we need) will not change within a session.
    local gaveUp = false

    ---@return boolean
    local function attach()
        if attached then
            return true
        end
        if gaveUp then
            return false
        end
        if not collections.isLoaded() then
            return false
        end

        local wardrobe = collections.getWardrobe()
        if not wardrobe then
            logger.debug("collections loaded but the wardrobe frame is missing; staying standalone")
            gaveUp = true
            return false
        end

        local host = collections.getGalleryHost and collections.getGalleryHost() or wardrobe
        embedded = newEmbeddedGallery(host)

        tab = collections.addTab(wardrobe, TAB_LABEL, function()
            embedded.show()
        end, function()
            embedded.hide()
        end)

        if not tab then
            logger.debug("could not add a wardrobe tab; staying standalone")
            embedded = nil
            gaveUp = true
            return false
        end

        attached = true
        logger.debug("wardrobe tab attached")
        return true
    end

    -- Registered unconditionally at construction: the player may open their collections at
    -- any point in the session, and the tab has to be there when they do.
    if not collections.isLoaded() then
        collections.onLoaded(attach)
    end

    return {
        attach = attach,

        isAttached = function()
            return attached
        end,

        ---Shows the gallery in its tab. Returns false when it could not — the caller owns
        ---the fallback, because the standalone window is not this module's to open and
        ---reaching for it from here is what made a failed attach show nothing at all.
        ---@return boolean shown
        select = function()
            if not collections.isLoaded() and not collections.load() then
                logger.debug("Blizzard_Collections would not load")
                return false
            end

            if not attach() then
                return false
            end

            collections.openCollections()
            if tab and tab.Click then
                tab:Click()
            end
            return true
        end,
    }
end
