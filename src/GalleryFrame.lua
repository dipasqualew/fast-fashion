local _, ns = ...

---The only module that builds widgets. It holds no rules about what a set means — it asks
---the presenter for a `GalleryView` and maps the fields onto frames. Anything resembling a
---decision belongs in `GalleryPresenter`, where it can be tested without a game client.
---@class GalleryFrame
---@field toggle fun()
---@field show fun()
---@field hide fun()
---@field isShown fun(): boolean
---@field refresh fun() Re-reads the presenter and redraws.

---The slice of the client's UI API the frame needs, injected so Main.lua stays the only
---file that touches WoW globals.
---@class UIAPI
---@field createFrame fun(kind: string, name: string?, parent: any?, template: string?): any
---@field parent any UIParent.
---@field registerEscapeClose fun(globalName: string) Adds to UISpecialFrames.

---@class GalleryFrameDeps
---@field presenter GalleryPresenter
---@field ui UIAPI
---@field logger Logger?

local WIDTH = 720
local HEIGHT = 520
local ROW_HEIGHT = 46
local ROW_INSET = 12
local LIST_WIDTH = 420
local LIST_HEIGHT = HEIGHT - 120
local DETAIL_WIDTH = 250
local SCROLL_BAR_WIDTH = 16

---How many pooled row widgets the list needs. The pool is sized to the viewport, never to
---the set list, which is what keeps a client reporting thousands of sets from building
---thousands of frames.
local VISIBLE_ROWS = math.floor(LIST_HEIGHT / ROW_HEIGHT)

local COLOR_WEARABLE = { 0.4, 0.9, 0.4 }
local COLOR_UNWEARABLE = { 0.9, 0.45, 0.45 }
local COLOR_PENDING = { 0.7, 0.7, 0.7 }
local COLOR_MUTED = { 0.75, 0.75, 0.75 }

local function noop() end

---@param row GalleryRowView|GalleryDetailSlotView
---@return number, number, number
local function statusColor(row)
    if row.unresolved then
        return COLOR_PENDING[1], COLOR_PENDING[2], COLOR_PENDING[3]
    end
    if row.wearable or row.collected then
        return COLOR_WEARABLE[1], COLOR_WEARABLE[2], COLOR_WEARABLE[3]
    end
    return COLOR_UNWEARABLE[1], COLOR_UNWEARABLE[2], COLOR_UNWEARABLE[3]
end

---@param deps GalleryFrameDeps
---@return GalleryFrame
function ns.newGalleryFrame(deps)
    local presenter = deps.presenter
    local ui = deps.ui
    local logger = deps.logger or { info = noop, debug = noop }

    local frame
    ---@type table[] pooled row widgets, reused across redraws
    local rowPool = {}
    ---@type table[] pooled detail slot lines
    local slotPool = {}
    local filterButtons = {}
    local sortButtons = {}
    local listEmptyText
    local detail
    local scrollBar
    ---Set while the redraw pushes the current offset back onto the slider, so the slider's
    ---own change handler can tell a programmatic update from a player dragging it.
    local syncingScrollBar = false

    local refresh

    ---@param parent any
    ---@param definition GalleryControlView
    ---@param onClick fun(key: string)
    ---@return any
    local function newControlButton(parent, definition, onClick)
        local button = ui.createFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetHeight(22)
        button:SetText(definition.label)
        button:SetWidth(math.max(80, button:GetTextWidth() + 24))
        button:SetScript("OnClick", function()
            onClick(definition.key)
            refresh()
        end)
        return button
    end

    ---@param parent any
    ---@param definitions GalleryControlView[]
    ---@param onClick fun(key: string)
    ---@param anchor any
    ---@param offsetY number
    ---@return table[]
    local function buildControlRow(parent, definitions, onClick, anchor, offsetY)
        local buttons = {}
        local previous
        for index, definition in ipairs(definitions) do
            local button = newControlButton(parent, definition, onClick)
            if previous then
                button:SetPoint("LEFT", previous, "RIGHT", 6, 0)
            else
                button:SetPoint("TOPLEFT", anchor, "TOPLEFT", ROW_INSET, offsetY)
            end
            buttons[index] = button
            previous = button
        end
        return buttons
    end

    ---One gallery row: the four lines SPEC.md asks for, plus a click target.
    ---@param parent any
    ---@param index number
    ---@return table
    local function newRowWidget(parent, index)
        local button = ui.createFrame("Button", nil, parent)
        button:SetSize(LIST_WIDTH - ROW_INSET * 2, ROW_HEIGHT)
        button:SetPoint("TOPLEFT", parent, "TOPLEFT", ROW_INSET, -(index - 1) * ROW_HEIGHT)

        local highlight = button:CreateTexture(nil, "BACKGROUND")
        highlight:SetAllPoints(button)
        highlight:SetColorTexture(1, 1, 1, 0.08)
        highlight:Hide()

        local name = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        name:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -2)
        name:SetJustifyH("LEFT")

        local progress = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        progress:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
        progress:SetJustifyH("LEFT")

        local missing = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        missing:SetPoint("TOPLEFT", progress, "BOTTOMLEFT", 0, -2)
        missing:SetJustifyH("LEFT")

        local status = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        status:SetPoint("TOPRIGHT", button, "TOPRIGHT", -4, -2)
        status:SetJustifyH("RIGHT")

        return {
            button = button,
            highlight = highlight,
            name = name,
            progress = progress,
            missing = missing,
            status = status,
        }
    end

    ---@param index number
    ---@return table
    local function rowWidget(index)
        local widget = rowPool[index]
        if not widget then
            widget = newRowWidget(frame.list, index)
            rowPool[index] = widget
        end
        return widget
    end

    ---@param widget table
    ---@param row GalleryRowView
    local function drawRow(widget, row)
        widget.name:SetText(row.name)
        widget.progress:SetText(row.progress)
        widget.progress:SetTextColor(COLOR_MUTED[1], COLOR_MUTED[2], COLOR_MUTED[3])
        widget.missing:SetText(row.missing)
        widget.missing:SetTextColor(COLOR_MUTED[1], COLOR_MUTED[2], COLOR_MUTED[3])
        widget.status:SetText(row.status)
        widget.status:SetTextColor(statusColor(row))

        if row.selected then
            widget.highlight:Show()
        else
            widget.highlight:Hide()
        end

        widget.button:SetScript("OnClick", function()
            -- Clicking the selected row again clears it, so the detail pane has an obvious
            -- way out that does not need its own close button. Written out rather than as
            -- `row.selected and nil or row.id`, which can never yield nil.
            if row.selected then
                presenter.select(nil)
            else
                presenter.select(row.id)
            end
            refresh()
        end)
        widget.button:Show()
    end

    ---@param index number
    ---@return table
    local function slotWidget(index)
        local widget = slotPool[index]
        if widget then
            return widget
        end

        local label = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        label:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -78 - (index - 1) * 16)
        label:SetJustifyH("LEFT")

        local state = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        state:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -8, -78 - (index - 1) * 16)
        state:SetJustifyH("RIGHT")

        widget = { label = label, state = state }
        slotPool[index] = widget
        return widget
    end

    ---@param view GalleryDetailView?
    local function drawDetail(view)
        for _, widget in ipairs(slotPool) do
            widget.label:SetText("")
            widget.state:SetText("")
        end

        if not view then
            detail:Hide()
            return
        end

        detail.title:SetText(view.name)
        detail.subtitle:SetText(view.subtitle or "")
        detail.progress:SetText(view.progress)
        detail.status:SetText(view.status)

        for index, slot in ipairs(view.slots) do
            local widget = slotWidget(index)
            widget.label:SetText(slot.label)
            widget.state:SetText(slot.state)
            widget.state:SetTextColor(statusColor(slot))
        end

        detail:Show()
    end

    ---@param scroll GalleryScrollView
    local function drawScrollBar(scroll)
        -- A list that fits needs no bar, and leaving a dead one on screen reads as broken.
        if scroll.maxOffset == 0 then
            scrollBar:Hide()
            return
        end

        syncingScrollBar = true
        scrollBar:SetMinMaxValues(0, scroll.maxOffset)
        scrollBar:SetValue(scroll.offset)
        syncingScrollBar = false

        scrollBar:Show()
    end

    ---@param buttons table[]
    ---@param definitions GalleryControlView[]
    local function drawControls(buttons, definitions)
        for index, definition in ipairs(definitions) do
            local button = buttons[index]
            if button then
                -- The active control is the one you cannot press again; disabling it is
                -- both the "you are here" marker and the no-op guard.
                button:SetEnabled(not definition.active)
            end
        end
    end

    local function build()
        frame = ui.createFrame("Frame", "FastFashionGalleryFrame", ui.parent, "BasicFrameTemplateWithInset")
        frame:SetSize(WIDTH, HEIGHT)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:Hide()

        frame.title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        frame.title:SetPoint("TOP", frame, "TOP", 0, -5)
        frame.title:SetText("Fast Fashion")

        local view = presenter.getView()
        filterButtons = buildControlRow(frame, view.filters, presenter.setFilter, frame, -34)
        sortButtons = buildControlRow(frame, view.sorts, presenter.setSort, frame, -62)

        frame.list = ui.createFrame("Frame", nil, frame)
        frame.list:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -96)
        frame.list:SetSize(LIST_WIDTH, LIST_HEIGHT)

        -- The frame is the only thing that knows how many rows fit, so it is the frame
        -- that tells the presenter where to cut the list.
        presenter.setViewportSize(VISIBLE_ROWS)

        frame.list:EnableMouseWheel(true)
        frame.list:SetScript("OnMouseWheel", function(_, delta)
            -- Wheel up is +1 from the client and means "towards the start of the list",
            -- which is a smaller offset.
            presenter.scrollBy(-delta)
            refresh()
        end)

        scrollBar = ui.createFrame("Slider", nil, frame.list, "UIPanelScrollBarTemplate")
        scrollBar:SetPoint("TOPRIGHT", frame.list, "TOPRIGHT", -ROW_INSET, -16)
        scrollBar:SetPoint("BOTTOMRIGHT", frame.list, "BOTTOMRIGHT", -ROW_INSET, 16)
        scrollBar:SetWidth(SCROLL_BAR_WIDTH)
        scrollBar:SetValueStep(1)
        scrollBar:SetObeyStepOnDrag(true)
        scrollBar:SetScript("OnValueChanged", function(_, value)
            -- Redrawing calls SetValue to follow the wheel, which fires this handler right
            -- back; without the guard the two chase each other into a stack overflow.
            if syncingScrollBar then
                return
            end
            presenter.scrollTo(value)
            refresh()
        end)

        listEmptyText = frame.list:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
        listEmptyText:SetPoint("TOP", frame.list, "TOP", 0, -40)
        listEmptyText:SetWidth(LIST_WIDTH - ROW_INSET * 2)
        listEmptyText:SetJustifyH("CENTER")

        detail = ui.createFrame("Frame", nil, frame, "InsetFrameTemplate")
        detail:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -ROW_INSET, -96)
        detail:SetSize(DETAIL_WIDTH, HEIGHT - 120)
        detail:Hide()

        detail.title = detail:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        detail.title:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -8)
        detail.title:SetWidth(DETAIL_WIDTH - 16)
        detail.title:SetJustifyH("LEFT")

        detail.subtitle = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        detail.subtitle:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
        detail.subtitle:SetWidth(DETAIL_WIDTH - 16)
        detail.subtitle:SetJustifyH("LEFT")

        detail.progress = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        detail.progress:SetPoint("TOPLEFT", detail.subtitle, "BOTTOMLEFT", 0, -6)
        detail.progress:SetJustifyH("LEFT")

        detail.status = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        detail.status:SetPoint("TOPLEFT", detail.progress, "BOTTOMLEFT", 0, -2)
        detail.status:SetJustifyH("LEFT")

        -- Escape closes the window, the way every other panel in the game behaves.
        ui.registerEscapeClose("FastFashionGalleryFrame")
    end

    ---@return boolean built
    local function ensureBuilt()
        if frame then
            return true
        end
        if not ui.createFrame then
            logger.debug("no UI available; gallery frame not built")
            return false
        end
        build()
        return true
    end

    refresh = function()
        if not frame then
            return
        end

        local view = presenter.getView()

        drawControls(filterButtons, view.filters)
        drawControls(sortButtons, view.sorts)

        for index, row in ipairs(view.rows) do
            drawRow(rowWidget(index), row)
        end
        -- Pooled widgets outlive the rows that filled them; hiding the tail is what stops
        -- a shrinking list from leaving ghosts of the previous filter on screen.
        for index = #view.rows + 1, #rowPool do
            rowPool[index].button:Hide()
        end

        drawScrollBar(view.scroll)
        listEmptyText:SetText(view.emptyMessage or "")
        drawDetail(view.detail)
    end

    local function show()
        if not ensureBuilt() then
            return
        end
        frame:Show()
        refresh()
    end

    local function hide()
        if frame then
            frame:Hide()
        end
    end

    return {
        show = show,
        hide = hide,
        refresh = refresh,

        toggle = function()
            if frame and frame:IsShown() then
                hide()
            else
                show()
            end
        end,

        isShown = function()
            return frame ~= nil and frame:IsShown() == true
        end,
    }
end
