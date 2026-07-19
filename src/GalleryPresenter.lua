local _, ns = ...

---The gallery as data: everything the frame needs to draw, and nothing that knows how to
---draw it. All the judgement calls about what a player is told live here, where they are
---cheap to test; `GalleryFrame` only maps these fields onto widgets.
---@class GalleryView
---@field filters GalleryControlView[]
---@field sorts GalleryControlView[]
---@field rows GalleryRowView[] Only the rows inside the viewport, ready to draw.
---@field scroll GalleryScrollView
---@field emptyMessage string? Shown instead of rows when the list is empty.
---@field detail GalleryDetailView? The selected row, expanded.

---The list is windowed rather than fully drawn: the client reports thousands of sets, and
---a widget per set would be both a stall and a memory leak. The frame keeps one pooled row
---per visible line and redraws it with whatever `rows` currently holds.
---@class GalleryScrollView
---@field offset number Rows scrolled past, always within [0, maxOffset].
---@field visible number How many rows fit in the viewport.
---@field total number Rows the current filter matched, viewport or not.
---@field maxOffset number
---@field canScrollUp boolean
---@field canScrollDown boolean

---@class GalleryControlView
---@field key string Passed straight back to setFilter / setSort.
---@field label string
---@field active boolean

---@class GalleryRowView
---@field id string
---@field name string
---@field subtitle string?
---@field progress string "6 / 8 collected", or the loading notice.
---@field missing string "2 missing", "Complete", or empty while loading.
---@field status string "Wearable by Rogue", "Cannot wear", "Loading…".
---@field wearable boolean
---@field unresolved boolean
---@field selected boolean

---@class GalleryDetailView
---@field id string
---@field name string
---@field subtitle string?
---@field progress string
---@field status string
---@field slots GalleryDetailSlotView[]

---@class GalleryDetailSlotView
---@field label string Human name of the inventory slot.
---@field state string "Collected", "Not collected", "No usable source", "Loading…".
---@field collected boolean
---@field usable boolean
---@field unresolved boolean

---@class GalleryPresenter
---@field getView fun(): GalleryView
---@field select fun(id: string?)
---@field getSelectedId fun(): string?
---@field setFilter fun(key: string)
---@field setSort fun(key: string)
---@field setViewportSize fun(rows: number?) How many rows the frame can draw; nil means all.
---@field scrollTo fun(offset: number)
---@field scrollBy fun(delta: number)

---@class GalleryPresenterDeps
---@field gallery GalleryController
---@field getPlayerClass fun(): string? Localised class name, for "Wearable by Rogue".

---Equipment slot numbers as the player knows them. A detail pane listing "slot 3" would be
---useless; anything unmapped falls back to the number rather than being dropped, because a
---slot we cannot name is still a slot the player is missing.
local SLOT_NAMES = {
    [1] = "Head",
    [2] = "Neck",
    [3] = "Shoulders",
    [4] = "Shirt",
    [5] = "Chest",
    [6] = "Waist",
    [7] = "Legs",
    [8] = "Feet",
    [9] = "Wrists",
    [10] = "Hands",
    [15] = "Back",
    [16] = "Main Hand",
    [17] = "Off Hand",
    [19] = "Tabard",
}

local FILTER_LABELS = {
    { key = "all", label = "All sets" },
    { key = "wearable", label = "Can wear" },
    { key = "unwearable", label = "Cannot wear" },
}

local SORT_LABELS = {
    { key = "none", label = "Default" },
    { key = "missingAsc", label = "Missing: low to high" },
    { key = "missingDesc", label = "Missing: high to low" },
}

local EMPTY_MESSAGES = {
    all = "No transmog sets found yet.",
    wearable = "No sets are completely wearable by this character yet.",
    unwearable = "Every set this character can see is wearable.",
}

local LOADING = "Loading…"

---@param slot number
---@return string
local function slotLabel(slot)
    return SLOT_NAMES[slot] or ("Slot " .. tostring(slot))
end

---@param deps GalleryPresenterDeps
---@return GalleryPresenter
function ns.newGalleryPresenter(deps)
    local gallery = deps.gallery
    local getPlayerClass = deps.getPlayerClass

    ---@type string?
    local selectedId
    ---nil until a frame declares how many rows it can draw, so a presenter driven without
    ---a viewport (tests, or any future non-windowed view) still sees the whole list.
    ---@type number?
    local viewportSize
    local scrollOffset = 0

    ---The offset has to be re-clamped on every read, not just when the player scrolls:
    ---changing a filter can shrink the list under a scrolled-down viewport, and an offset
    ---left past the end would show a blank gallery over a list that has matches.
    ---@param total number
    ---@return number offset, number visible, number maxOffset
    local function clampScroll(total)
        local visible = viewportSize or total
        local maxOffset = math.max(0, total - visible)

        if scrollOffset > maxOffset then
            scrollOffset = maxOffset
        elseif scrollOffset < 0 then
            scrollOffset = 0
        end

        return scrollOffset, visible, maxOffset
    end

    ---@param definitions table[]
    ---@param active string
    ---@return GalleryControlView[]
    local function controls(definitions, active)
        local built = {}
        for index, definition in ipairs(definitions) do
            built[index] = {
                key = definition.key,
                label = definition.label,
                active = definition.key == active,
            }
        end
        return built
    end

    ---The wearability line is the product's whole pitch, so it names the class: "Wearable
    ---by Rogue" on a Druid set is the sentence that tells the player this addon knows
    ---something the default UI does not.
    ---@param row ResolvedOutfit
    ---@return string
    local function statusOf(row)
        if row.unresolved then
            return LOADING
        end
        if not row.wearable then
            return "Cannot wear"
        end

        local class = getPlayerClass()
        if class and class ~= "" then
            return "Wearable by " .. class
        end
        return "Wearable"
    end

    ---@param row ResolvedOutfit
    ---@return string
    local function progressOf(row)
        if row.unresolved then
            return LOADING
        end
        return row.collectedCount .. " / " .. row.totalCount .. " collected"
    end

    ---@param row ResolvedOutfit
    ---@return string
    local function missingOf(row)
        if row.unresolved then
            return ""
        end
        if row.missingCount == 0 then
            return "Complete"
        end
        return row.missingCount .. " missing"
    end

    ---@param row ResolvedOutfit
    ---@return GalleryRowView
    local function toRowView(row)
        return {
            id = row.outfit.id,
            name = row.outfit.name,
            subtitle = row.outfit.description,
            progress = progressOf(row),
            missing = missingOf(row),
            status = statusOf(row),
            wearable = row.wearable,
            unresolved = row.unresolved == true,
            selected = row.outfit.id == selectedId,
        }
    end

    ---A slot the character cannot source at all is a different problem from one they simply
    ---have not collected: the first is a dead end, the second is a to-do list. The detail
    ---pane is the only place that distinction is visible, so it must not be flattened.
    ---@param slot ResolvedOutfitSlot
    ---@return string
    local function slotState(slot)
        if slot.unresolved then
            return LOADING
        end
        if not slot.usable then
            return "No usable source"
        end
        if slot.collected then
            return "Collected"
        end
        return "Not collected"
    end

    ---@param row ResolvedOutfit
    ---@return GalleryDetailView
    local function toDetailView(row)
        local slots = {}
        for index, slot in ipairs(row.slots) do
            slots[index] = {
                label = slotLabel(slot.inventorySlot or index),
                state = slotState(slot),
                collected = slot.collected,
                usable = slot.usable,
                unresolved = slot.unresolved == true,
            }
        end

        return {
            id = row.outfit.id,
            name = row.outfit.name,
            subtitle = row.outfit.description,
            progress = progressOf(row),
            status = statusOf(row),
            slots = slots,
        }
    end

    return {
        ---@return GalleryView
        getView = function()
            local resolved = gallery.getRows()
            local filter = gallery.getFilter()

            local total = #resolved
            local offset, visible, maxOffset = clampScroll(total)

            -- The detail pane is resolved over the whole list, not the window: a set the
            -- player selected and then scrolled past is still the set they are reading.
            local detail
            if selectedId then
                for _, row in ipairs(resolved) do
                    if row.outfit.id == selectedId then
                        detail = toDetailView(row)
                        break
                    end
                end
            end

            local rows = {}
            for index = 1, visible do
                local row = resolved[offset + index]
                if not row then
                    break
                end
                rows[index] = toRowView(row)
            end

            return {
                filters = controls(FILTER_LABELS, filter),
                sorts = controls(SORT_LABELS, gallery.getSort()),
                rows = rows,
                scroll = {
                    offset = offset,
                    visible = visible,
                    total = total,
                    maxOffset = maxOffset,
                    canScrollUp = offset > 0,
                    canScrollDown = offset < maxOffset,
                },
                -- Keyed off the match count rather than the window, and filter-specific:
                -- "no sets found" under a wearability filter would read as a broken addon
                -- rather than as a narrow filter.
                emptyMessage = total == 0 and EMPTY_MESSAGES[filter] or nil,
                detail = detail,
            }
        end,

        ---@param rows number?
        setViewportSize = function(rows)
            viewportSize = rows
        end,

        ---Both scroll actions record the request as-is and let the next read clamp it,
        ---so neither has to know how many rows the current filter matched.
        ---@param offset number
        scrollTo = function(offset)
            scrollOffset = math.floor(tonumber(offset) or 0)
        end,

        ---@param delta number
        scrollBy = function(delta)
            scrollOffset = scrollOffset + math.floor(tonumber(delta) or 0)
        end,

        ---@param id string?
        select = function(id)
            selectedId = id
        end,

        getSelectedId = function()
            return selectedId
        end,

        ---Changing a filter can hide the selected row, and a detail pane describing a set
        ---the player can no longer see in the list is a confusing dead end. The list is a
        ---different list now, so it starts at the top too.
        ---@param key string
        setFilter = function(key)
            gallery.setFilter(key)
            selectedId = nil
            scrollOffset = 0
        end,

        ---Re-sorting keeps the selection — the player is tracking a set, not a position —
        ---but the row they were looking at has moved, so the window returns to the top.
        ---@param key string
        setSort = function(key)
            gallery.setSort(key)
            scrollOffset = 0
        end,
    }
end
