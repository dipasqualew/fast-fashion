local _, ns = ...

---Applies a resolved outfit to the game's transmog preview.
---
---Every dependency on Blizzard's UI internals is behind `TransmogPreviewAPI`, because this
---is the part of the addon most likely to break on a patch and the part least able to be
---exercised by a test client. The module itself is pure decision-making: which slots can
---carry an appearance, which have a source worth sending, and what to tell the player when
---the answer is "not right now".
---@class TransmogPreview
---@field preview fun(row: ResolvedOutfit): PreviewResult
---@field canPreview fun(): boolean

---What the attempt did, in terms the presenter can turn into a sentence. `applied` and
---`skipped` are both reported because a set that goes on with two slots missing is a
---success the player still needs to be told about.
---@class PreviewResult
---@field ok boolean
---@field applied number Slots handed to the preview.
---@field skipped number Slots with no source the client would draw.
---@field reason PreviewFailure? Set only when `ok` is false.

---@alias PreviewFailure "unavailable" | "loading" | "noSources"

---The slice of the client's transmog UI needed to drive a preview.
---@class TransmogPreviewAPI
---@field isAvailable fun(): boolean Whether the transmog UI can take a pending appearance now.
---@field clearPending fun() Drop whatever is currently pending.
---@field setPending fun(inventorySlot: number, sourceID: number): boolean Apply one slot.
---@field open fun()? Bring the wardrobe to the front, if it is not already.

---@class TransmogPreviewDeps
---@field api TransmogPreviewAPI
---@field logger Logger?

---Slots that can carry a transmog appearance. Neck, rings and trinkets have no appearance
---to set, and sending one is an error rather than a no-op — so a set that happens to list
---one is filtered here rather than being allowed to fail the whole preview.
local TRANSMOGGABLE_SLOTS = {
    [1] = true,   -- Head
    [3] = true,   -- Shoulders
    [4] = true,   -- Shirt
    [5] = true,   -- Chest
    [6] = true,   -- Waist
    [7] = true,   -- Legs
    [8] = true,   -- Feet
    [9] = true,   -- Wrists
    [10] = true,  -- Hands
    [15] = true,  -- Back
    [16] = true,  -- Main Hand
    [17] = true,  -- Off Hand
    [19] = true,  -- Tabard
}

local function noop() end

---@param deps TransmogPreviewDeps
---@return TransmogPreview
function ns.newTransmogPreview(deps)
    local api = deps.api
    local logger = deps.logger or { info = noop, debug = noop }

    ---@param reason PreviewFailure
    ---@return PreviewResult
    local function failure(reason)
        return { ok = false, applied = 0, skipped = 0, reason = reason }
    end

    ---@return boolean
    local function canPreview()
        return api ~= nil and api.isAvailable ~= nil and api.isAvailable() == true
    end

    ---@param row ResolvedOutfit
    ---@return PreviewResult
    local function preview(row)
        if not canPreview() then
            logger.debug("preview requested but the transmog UI is not available")
            return failure("unavailable")
        end
        -- Previewing a set whose sources are still streaming in would dress the player in
        -- whichever half had arrived, which looks like the addon picking the wrong pieces
        -- rather than like data still loading.
        if row.unresolved then
            return failure("loading")
        end

        api.clearPending()

        local applied, skipped = 0, 0
        for _, slot in ipairs(row.slots) do
            local inventorySlot = slot.inventorySlot
            if inventorySlot and TRANSMOGGABLE_SLOTS[inventorySlot] then
                -- The resolver already picked the best source, falling back to one the
                -- player has not collected when the client will still draw it. A slot with
                -- nothing at all is skipped rather than blanked, so the preview shows what
                -- the player is already wearing there instead of bare skin.
                if slot.resolvedSourceID then
                    if api.setPending(inventorySlot, slot.resolvedSourceID) then
                        applied = applied + 1
                    else
                        skipped = skipped + 1
                    end
                else
                    skipped = skipped + 1
                end
            end
        end

        if applied == 0 then
            return failure("noSources")
        end

        if api.open then
            api.open()
        end

        logger.debug("previewed " .. row.outfit.id .. ": " .. applied .. " applied, " .. skipped .. " skipped")
        return { ok = true, applied = applied, skipped = skipped }
    end

    return {
        preview = preview,
        canPreview = canPreview,
    }
end
