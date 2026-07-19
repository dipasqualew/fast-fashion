local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newGalleryFrame", function()
    local ns = loader.load()

    local FRAME_NAME = "FastFashionGalleryFrame"

    ---@class FrameRowSpec
    ---@field id string
    ---@field name string?
    ---@field progress string?
    ---@field missing string?
    ---@field status string?
    ---@field wearable boolean?
    ---@field unresolved boolean?
    ---@field selected boolean?

    ---@param spec FrameRowSpec
    ---@return GalleryRowView
    local function buildRowView(spec)
        return {
            id = spec.id,
            name = spec.name or spec.id,
            progress = spec.progress or "1 / 2 collected",
            missing = spec.missing or "1 missing",
            status = spec.status or "Wearable by Rogue",
            wearable = spec.wearable ~= false,
            unresolved = spec.unresolved == true,
            selected = spec.selected == true,
        }
    end

    ---@param keys string[]
    ---@param active string
    ---@return GalleryControlView[]
    local function buildControls(keys, active)
        local controls = {}
        for index, key in ipairs(keys) do
            controls[index] = { key = key, label = key, active = key == active }
        end
        return controls
    end

    ---A `GalleryView` as the presenter would hand one over.
    ---
    ---`scroll` defaults to a list that fits its viewport, because most of these tests are
    ---about drawing rather than scrolling; a test that cares passes `spec.scroll`.
    ---@param spec table? `{ rows, filter, sort, emptyMessage, detail, scroll }`
    ---@return GalleryView
    local function buildView(spec)
        spec = spec or {}
        local rows = {}
        for index, rowSpec in ipairs(spec.rows or {}) do
            rows[index] = buildRowView(rowSpec)
        end

        local scroll = spec.scroll or {}

        return {
            filters = buildControls({ "all", "wearable", "unwearable" }, spec.filter or "all"),
            sorts = buildControls({ "none", "missingAsc", "missingDesc" }, spec.sort or "none"),
            rows = rows,
            scroll = {
                offset = scroll.offset or 0,
                visible = scroll.visible or #rows,
                total = scroll.total or #rows,
                maxOffset = scroll.maxOffset or 0,
                canScrollUp = scroll.canScrollUp == true,
                canScrollDown = scroll.canScrollDown == true,
            },
            emptyMessage = spec.emptyMessage,
            detail = spec.detail,
        }
    end

    ---A stub `GalleryPresenter`. The frame is supposed to hold no rules at all, so nothing
    ---here reacts to a call — the view only changes when a test replaces it, which is what
    ---makes a redraw over a *shorter* list expressible.
    ---@param view GalleryView
    ---@return GalleryPresenter presenter
    ---@param message string? what `previewSelected` answers, if anything
    ---@return table recorded `{ selected, filters, sorts, viewportSizes, scrollTos, scrollBys, previews }`
    ---@return fun(view: GalleryView) setView
    local function newStubPresenter(view, message)
        local recorded = {
            selected = {},
            filters = {},
            sorts = {},
            viewportSizes = {},
            scrollTos = {},
            scrollBys = {},
            previews = 0,
        }
        local current = view

        local presenter = {
            getView = function()
                return current
            end,

            select = function(id)
                recorded.selected[#recorded.selected + 1] = { id = id }
            end,

            getSelectedId = function()
                return nil
            end,

            setFilter = function(key)
                recorded.filters[#recorded.filters + 1] = key
            end,

            setSort = function(key)
                recorded.sorts[#recorded.sorts + 1] = key
            end,

            setViewportSize = function(rows)
                recorded.viewportSizes[#recorded.viewportSizes + 1] = rows
            end,

            scrollTo = function(offset)
                recorded.scrollTos[#recorded.scrollTos + 1] = offset
            end,

            scrollBy = function(delta)
                recorded.scrollBys[#recorded.scrollBys + 1] = delta
            end,

            previewSelected = function()
                recorded.previews = recorded.previews + 1
                return message
            end,
        }

        return presenter, recorded, function(next)
            current = next
        end
    end

    ---@return table lines
    ---@return Logger logger
    local function newRecordingLogger()
        local lines = {}
        return lines, {
            info = function(message)
                lines[#lines + 1] = message
            end,
            debug = function(message)
                lines[#lines + 1] = message
            end,
        }
    end

    ---Builds a frame over a fake UI.
    ---@param spec table? view spec, as `buildView` takes
    ---@param options table? `{ ui, logger, getParent, previewMessage }`
    ---@return GalleryFrame frame
    ---@return table ui recorded `{ frames, byName, escapeClosed }`
    ---@return table presenter recorded
    ---@return fun(view: GalleryView) setView
    local function newFrame(spec, options)
        options = options or {}
        local ui, uiRecorded = fake.newUi()
        local presenter, presenterRecorded, setView = newStubPresenter(buildView(spec), options.previewMessage)

        local frame = ns.newGalleryFrame({
            presenter = presenter,
            ui = options.ui or ui,
            logger = options.logger,
            getParent = options.getParent,
        })

        return frame, uiRecorded, presenterRecorded, setView
    end

    ---@param recorded table
    ---@return table widget the top-level gallery window
    local function windowOf(recorded)
        return recorded.byName[FRAME_NAME]
    end

    ---The arguments a named frame was created with. A widget answers any unset field with
    ---a no-op method, so "was this built with a template?" can only be asked of the call.
    ---@param recorded table
    ---@param name string
    ---@return table?
    local function creationOf(recorded, name)
        for _, creation in ipairs(recorded.created) do
            if creation.name == name then
                return creation
            end
        end
        return nil
    end

    ---@param parent table
    ---@param predicate fun(child: table): boolean
    ---@return table[]
    local function childrenWhere(parent, predicate)
        local found = {}
        for _, child in ipairs(parent.children) do
            if predicate(child) then
                found[#found + 1] = child
            end
        end
        return found
    end

    ---Every control button in the window, in creation order: the three filters first, then
    ---the three sorts, matching the order `build` lays them out in.
    ---@param recorded table
    ---@return table[]
    local function controlButtons(recorded)
        return childrenWhere(windowOf(recorded), function(child)
            return child.template == "UIPanelButtonTemplate"
        end)
    end

    ---@param recorded table
    ---@return table[] filters, table[] sorts
    local function controlRows(recorded)
        local buttons = controlButtons(recorded)
        return { buttons[1], buttons[2], buttons[3] }, { buttons[4], buttons[5], buttons[6] }
    end

    ---@param recorded table
    ---@return table
    local function listOf(recorded)
        return windowOf(recorded).list
    end

    ---@param recorded table
    ---@return table
    local function detailOf(recorded)
        return childrenWhere(windowOf(recorded), function(child)
            return child.template == "InsetFrameTemplate"
        end)[1]
    end

    ---@param widget table
    ---@return table[] the widget's font strings, in creation order
    local function fontStrings(widget)
        local found = {}
        for _, region in ipairs(widget.regions) do
            if region.kind == "FontString" then
                found[#found + 1] = region
            end
        end
        return found
    end

    ---Every pooled row widget, in creation order. Selected by kind rather than by position
    ---so the list's other children — the scroll bar — cannot shift the indices.
    ---@param recorded table
    ---@return table[]
    local function rowButtons(recorded)
        local buttons = {}
        for _, child in ipairs(listOf(recorded).children) do
            if child.kind == "Button" then
                buttons[#buttons + 1] = child
            end
        end
        return buttons
    end

    ---@param recorded table
    ---@param index number
    ---@return table
    local function rowButton(recorded, index)
        return rowButtons(recorded)[index]
    end

    ---The four lines of one gallery row, read back off the widgets.
    ---@param recorded table
    ---@param index number
    ---@return table `{ name, progress, missing, status }`
    local function rowText(recorded, index)
        local lines = fontStrings(rowButton(recorded, index))
        return {
            name = lines[1].text,
            progress = lines[2].text,
            missing = lines[3].text,
            status = lines[4].text,
        }
    end

    ---The list's scroll bar, the one Slider it owns.
    ---@param recorded table
    ---@return table?
    local function scrollBarOf(recorded)
        for _, child in ipairs(listOf(recorded).children) do
            if child.kind == "Slider" then
                return child
            end
        end
        return nil
    end

    ---@param spec table?
    ---@return GalleryDetailView
    local function buildDetail(spec)
        spec = spec or {}
        return {
            id = spec.id or "a",
            name = spec.name or "Bloodfang Armor",
            subtitle = spec.subtitle,
            progress = spec.progress or "1 / 2 collected",
            status = spec.status or "Wearable by Rogue",
            slots = spec.slots or {},
            preview = spec.preview or {
                label = "Preview Set",
                enabled = spec.previewEnabled ~= false,
                reason = spec.previewReason,
            },
        }
    end

    ---The detail pane's own Preview Set button: the one child of the pane built from the
    ---button template.
    ---@param recorded table
    ---@return table?
    local function previewButtonOf(recorded)
        return childrenWhere(detailOf(recorded), function(child)
            return child.template == "UIPanelButtonTemplate"
        end)[1]
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newGalleryFrame)
    end)

    describe("staying out of the way until asked", function()
        -- The addon is constructed at login for every player, most of whom never open the
        -- gallery. Building several dozen widgets for them is pure login-time cost.
        it("creates no widgets merely by being constructed", function()
            local _, recorded = newFrame({ rows = { { id = "a" } } })

            assert.same({}, recorded.frames)
        end)

        it("reports itself hidden before it has ever been built", function()
            local frame = newFrame()

            assert.is_false(frame.isShown())
        end)

        -- A refresh can be triggered by a client event long before the player opens the
        -- window; that must be a quiet no-op, not an error in the middle of an event.
        it("ignores a refresh before the window exists", function()
            local frame, recorded = newFrame({ rows = { { id = "a" } } })

            frame.refresh()

            assert.same({}, recorded.frames)
        end)
    end)

    describe("opening and closing", function()
        it("builds the window on the first show", function()
            local frame, recorded = newFrame()

            frame.show()

            assert.is_truthy(windowOf(recorded))
        end)

        it("reports itself shown once opened", function()
            local frame = newFrame()

            frame.show()

            assert.is_true(frame.isShown())
        end)

        it("hides the window on hide", function()
            local frame = newFrame()
            frame.show()

            frame.hide()

            assert.is_false(frame.isShown())
        end)

        it("opens a closed window on toggle", function()
            local frame = newFrame()

            frame.toggle()

            assert.is_true(frame.isShown())
        end)

        it("closes an open window on toggle", function()
            local frame = newFrame()
            frame.show()

            frame.toggle()

            assert.is_false(frame.isShown())
        end)

        it("builds the window only once across several opens", function()
            local frame, recorded = newFrame()
            frame.show()
            local built = #recorded.frames

            frame.hide()
            frame.show()

            assert.equal(built, #recorded.frames)
        end)

        -- Every other panel in the game closes on Escape, and a window that does not is
        -- the one the player has to hunt for a close button on.
        it("registers itself for Escape close", function()
            local frame, recorded = newFrame()

            frame.show()

            assert.same({ FRAME_NAME }, recorded.escapeClosed)
        end)
    end)

    describe("booting where no frames can be made", function()
        -- Models the client not offering a UI at all: the addon must degrade to doing
        -- nothing rather than erroring out of whatever event triggered it.
        it("constructs against a UI API that cannot create frames", function()
            local presenter = newStubPresenter(buildView())

            assert.has_no.errors(function()
                ns.newGalleryFrame({ presenter = presenter, ui = {} })
            end)
        end)

        it("stays hidden when asked to show", function()
            local lines, logger = newRecordingLogger()
            local frame = newFrame(nil, { ui = {}, logger = logger })

            frame.show()

            assert.is_false(frame.isShown())
            assert.equal(1, #lines)
        end)

        it("says why through the injected logger rather than printing", function()
            local lines, logger = newRecordingLogger()
            local frame = newFrame(nil, { ui = {}, logger = logger })

            frame.show()

            assert.is_truthy(lines[1]:find("no UI available", 1, true))
        end)

        it("survives with no logger injected at all", function()
            local frame = newFrame(nil, { ui = {} })

            assert.has_no.errors(frame.show)
        end)
    end)

    describe("drawing the list", function()
        ---@type FrameRowSpec[]
        local TWO = {
            { id = "a", name = "Bloodfang", progress = "6 / 8 collected", missing = "2 missing" },
            { id = "b", name = "Judgement", progress = "8 / 8 collected", missing = "Complete" },
        }

        it("gives each row a widget", function()
            local frame, recorded = newFrame({ rows = TWO })

            frame.show()

            assert.equal(2, #rowButtons(recorded))
        end)

        ---The frame's whole job on a row is to copy the presenter's strings onto widgets;
        ---any rewording here would be a rule living in the wrong module.
        ---@type { field: string, expected: string }[]
        local fields = {
            { field = "name", expected = "Bloodfang" },
            { field = "progress", expected = "6 / 8 collected" },
            { field = "missing", expected = "2 missing" },
            { field = "status", expected = "Wearable by Rogue" },
        }

        for _, case in ipairs(fields) do
            it("prints the presenter's " .. case.field .. " verbatim", function()
                local frame, recorded = newFrame({ rows = TWO })

                frame.show()

                assert.equal(case.expected, rowText(recorded, 1)[case.field])
            end)
        end

        it("shows the presenter's message when there is nothing to list", function()
            local frame, recorded = newFrame({ rows = {}, emptyMessage = "No sets yet." })

            frame.show()

            assert.equal("No sets yet.", fontStrings(listOf(recorded))[1].text)
        end)

        it("colours an unresolved row apart from a verdict", function()
            local frame, recorded = newFrame({ rows = { { id = "a", unresolved = true } } })

            frame.show()

            local status = fontStrings(rowButton(recorded, 1))[4]
            assert.same({ 0.7, 0.7, 0.7 }, status.textColor)
        end)
    end)

    describe("redrawing over a shorter list", function()
        -- Row widgets are pooled and outlive the rows that filled them. Leaving the tail
        -- visible is the ghost-rows bug: switching to a narrow filter would show the
        -- previous filter's leftovers below the real results.
        it("hides the widgets the new list no longer needs", function()
            local frame, recorded, _, setView = newFrame({
                rows = { { id = "a" }, { id = "b" }, { id = "c" } },
            })
            frame.show()

            setView(buildView({ rows = { { id = "a" } } }))
            frame.refresh()

            assert.is_false(rowButton(recorded, 3).shown)
        end)

        it("keeps the widgets the new list still uses", function()
            local frame, recorded, _, setView = newFrame({
                rows = { { id = "a" }, { id = "b" }, { id = "c" } },
            })
            frame.show()

            setView(buildView({ rows = { { id = "a" } } }))
            frame.refresh()

            assert.is_true(rowButton(recorded, 1).shown)
        end)

        it("reuses the pooled widgets rather than growing the list", function()
            local frame, recorded, _, setView = newFrame({ rows = { { id = "a" }, { id = "b" } } })
            frame.show()

            setView(buildView({ rows = { { id = "x" } } }))
            frame.refresh()
            setView(buildView({ rows = { { id = "x" }, { id = "y" } } }))
            frame.refresh()

            assert.equal(2, #rowButtons(recorded))
        end)

        it("shows a widget again when the list grows back", function()
            local frame, recorded, _, setView = newFrame({ rows = { { id = "a" }, { id = "b" } } })
            frame.show()
            setView(buildView({ rows = { { id = "a" } } }))
            frame.refresh()

            setView(buildView({ rows = { { id = "a" }, { id = "b" } } }))
            frame.refresh()

            assert.is_true(rowButton(recorded, 2).shown)
        end)
    end)

    describe("clicking a row", function()
        it("asks the presenter to select the set that was clicked", function()
            local frame, uiRecorded, presenter = newFrame({ rows = { { id = "a" }, { id = "b" } } })
            frame.show()

            rowButton(uiRecorded, 2):Click()

            assert.equal("b", presenter.selected[1].id)
        end)

        -- Clicking the selected row again clears it, which gives the detail pane an obvious
        -- way out without spending screen space on a close button.
        it("clears the selection when the selected row is clicked again", function()
            local frame, uiRecorded, presenter = newFrame({
                rows = { { id = "a", selected = true } },
            })
            frame.show()

            rowButton(uiRecorded, 1):Click()

            assert.equal(1, #presenter.selected)
            assert.is_nil(presenter.selected[1].id)
        end)

        it("redraws so the highlight follows the click", function()
            local frame, uiRecorded, _, setView = newFrame({ rows = { { id = "a" } } })
            frame.show()

            setView(buildView({ rows = { { id = "a", name = "Renamed" } } }))
            rowButton(uiRecorded, 1):Click()

            assert.equal("Renamed", rowText(uiRecorded, 1).name)
        end)
    end)

    describe("the filter and sort controls", function()
        -- The active control is the one you cannot press again: disabling it is both the
        -- "you are here" marker and the guard against a pointless redraw.
        it("disables the active filter and leaves the rest pressable", function()
            local frame, recorded = newFrame({ filter = "wearable" })

            frame.show()

            local filters = controlRows(recorded)
            assert.is_true(filters[1].enabled)
            assert.is_false(filters[2].enabled)
            assert.is_true(filters[3].enabled)
        end)

        it("disables the active sort and leaves the rest pressable", function()
            local frame, recorded = newFrame({ sort = "missingAsc" })

            frame.show()

            local _, sorts = controlRows(recorded)
            assert.is_true(sorts[1].enabled)
            assert.is_false(sorts[2].enabled)
            assert.is_true(sorts[3].enabled)
        end)

        it("labels each control with the presenter's label", function()
            local frame, recorded = newFrame()

            frame.show()

            local filters = controlRows(recorded)
            assert.equal("wearable", filters[2].text)
        end)

        it("hands the presenter the key of the filter that was pressed", function()
            local frame, uiRecorded, presenter = newFrame()
            frame.show()

            local filters = controlRows(uiRecorded)
            filters[2]:Click()

            assert.same({ "wearable" }, presenter.filters)
        end)

        it("hands the presenter the key of the sort that was pressed", function()
            local frame, uiRecorded, presenter = newFrame()
            frame.show()

            local _, sorts = controlRows(uiRecorded)
            sorts[3]:Click()

            assert.same({ "missingDesc" }, presenter.sorts)
        end)
    end)

    describe("the detail pane", function()
        it("stays hidden while nothing is selected", function()
            local frame, recorded = newFrame({ rows = { { id = "a" } } })

            frame.show()

            assert.is_false(detailOf(recorded).shown)
        end)

        it("appears when the presenter offers a detail view", function()
            local frame, recorded = newFrame({ rows = { { id = "a" } }, detail = buildDetail() })

            frame.show()

            assert.is_true(detailOf(recorded).shown)
        end)

        it("prints the selected set's name", function()
            local frame, recorded = newFrame({ detail = buildDetail({ name = "Judgement" }) })

            frame.show()

            assert.equal("Judgement", fontStrings(detailOf(recorded))[1].text)
        end)

        it("lists each slot with its state", function()
            local frame, recorded = newFrame({
                detail = buildDetail({
                    slots = {
                        { label = "Head", state = "Collected", collected = true, usable = true },
                        { label = "Back", state = "No usable source", collected = false, usable = false },
                    },
                }),
            })

            frame.show()

            -- Lines 1-4 are name, subtitle, progress and status; 5 is the preview reason,
            -- built with the pane. The pooled slot lines follow.
            local lines = fontStrings(detailOf(recorded))
            assert.equal("Head", lines[6].text)
            assert.equal("Collected", lines[7].text)
            assert.equal("Back", lines[8].text)
            assert.equal("No usable source", lines[9].text)
        end)

        -- Slot lines are pooled just like rows, so a set with fewer slots must not inherit
        -- the previous set's leftovers.
        it("blanks the slot lines a shorter set no longer fills", function()
            local frame, recorded, _, setView = newFrame({
                detail = buildDetail({
                    slots = {
                        { label = "Head", state = "Collected" },
                        { label = "Back", state = "Collected" },
                    },
                }),
            })
            frame.show()

            setView(buildView({
                detail = buildDetail({ slots = { { label = "Head", state = "Collected" } } }),
            }))
            frame.refresh()

            local lines = fontStrings(detailOf(recorded))
            assert.equal("", lines[8].text)
            assert.equal("", lines[9].text)
        end)

        it("hides again when the selection is dropped", function()
            local frame, recorded, _, setView = newFrame({ detail = buildDetail() })
            frame.show()

            setView(buildView({ rows = { { id = "a" } } }))
            frame.refresh()

            assert.is_false(detailOf(recorded).shown)
        end)
    end)

    describe("the Preview Set button", function()
        it("takes its label from the view model", function()
            local frame, recorded = newFrame({ detail = buildDetail() })

            frame.show()

            assert.equal("Preview Set", previewButtonOf(recorded).text)
        end)

        it("is enabled when the view model says the action can run", function()
            local frame, recorded = newFrame({ detail = buildDetail({ previewEnabled = true }) })

            frame.show()

            assert.is_true(previewButtonOf(recorded).enabled)
        end)

        -- Greyed with the reason printed beside it, rather than gone: the frame holds no
        -- opinion about why, it just draws what the presenter decided.
        it("is disabled when the view model says it cannot", function()
            local frame, recorded = newFrame({
                detail = buildDetail({ previewEnabled = false, previewReason = "Visit a transmog vendor." }),
            })

            frame.show()

            assert.is_false(previewButtonOf(recorded).enabled)
        end)

        it("prints the reason it is disabled", function()
            local frame, recorded = newFrame({
                detail = buildDetail({ previewEnabled = false, previewReason = "Visit a transmog vendor." }),
            })

            frame.show()

            assert.equal("Visit a transmog vendor.", fontStrings(detailOf(recorded))[5].text)
        end)

        it("clears a stale reason once the action becomes available", function()
            local frame, recorded, _, setView = newFrame({
                detail = buildDetail({ previewEnabled = false, previewReason = "Visit a transmog vendor." }),
            })
            frame.show()

            setView(buildView({ detail = buildDetail({ previewEnabled = true }) }))
            frame.refresh()

            assert.equal("", fontStrings(detailOf(recorded))[5].text)
        end)

        it("asks the presenter to preview the selection when pressed", function()
            local frame, recorded, presenterRecorded = newFrame({ detail = buildDetail() })
            frame.show()

            previewButtonOf(recorded):Click()

            assert.equal(1, presenterRecorded.previews)
        end)

        it("tells the player whatever the presenter had to say", function()
            local lines, logger = newRecordingLogger()
            local frame, recorded = newFrame({ detail = buildDetail() }, {
                logger = logger,
                previewMessage = "Previewed Judgement; 2 slot(s) had no source.",
            })
            frame.show()

            previewButtonOf(recorded):Click()

            assert.same({ "Previewed Judgement; 2 slot(s) had no source." }, lines)
        end)

        -- A clean preview speaks for itself on the character model.
        it("stays quiet when the presenter had nothing to say", function()
            local lines, logger = newRecordingLogger()
            local frame, recorded = newFrame({ detail = buildDetail() }, { logger = logger })
            frame.show()

            previewButtonOf(recorded):Click()

            assert.same({}, lines)
        end)
    end)

    ---The gallery is the same widget tree in the Wardrobe panel as it is standalone; only
    ---its chrome differs. Supplying our own window inside Blizzard's would stack a second
    ---set of borders inside the first, and answering Escape twice would close the inner
    ---frame and leave the player staring at an empty panel.
    describe("living inside the Wardrobe panel", function()
        ---@return table host
        local function newHost()
            return fake.newWidget("Frame", "WardrobeCollectionFrame")
        end

        ---@param host table?
        ---@return GalleryFrame frame, table recorded
        local function newEmbedded(host)
            host = host or newHost()
            return newFrame({ rows = { { id = "a" } } }, {
                getParent = function()
                    return host
                end,
            })
        end

        it("parents the gallery to the host frame", function()
            local host = newHost()
            local frame, recorded = newEmbedded(host)

            frame.show()

            assert.equal(host, windowOf(recorded).parent)
        end)

        it("takes no window template of its own", function()
            local frame, recorded = newEmbedded()

            frame.show()

            assert.is_nil(creationOf(recorded, FRAME_NAME).template)
        end)

        -- The Collections frame already carries a title; a second one would sit on top.
        it("draws no title of its own", function()
            local frame, recorded = newEmbedded()

            frame.show()

            assert.same({}, fontStrings(windowOf(recorded)))
        end)

        it("leaves Escape to the panel that owns it", function()
            local frame, recorded = newEmbedded()

            frame.show()

            assert.same({}, recorded.escapeClosed)
        end)

        it("still draws its rows", function()
            local frame, recorded = newEmbedded()

            frame.show()

            assert.equal(1, #rowButtons(recorded))
        end)

        -- A host that is not there yet is the standalone case, not an error: the Wardrobe
        -- panel only exists once Blizzard_Collections has loaded.
        it("falls back to a standalone window when there is no host", function()
            local frame, recorded = newFrame({ rows = { { id = "a" } } }, {
                getParent = function()
                    return nil
                end,
            })

            frame.show()

            assert.equal("BasicFrameTemplateWithInset", creationOf(recorded, FRAME_NAME).template)
            assert.same({ "FastFashionGalleryFrame" }, recorded.escapeClosed)
        end)

        it("builds a standalone window when no host lookup was injected at all", function()
            local frame, recorded = newFrame({ rows = { { id = "a" } } })

            frame.show()

            assert.equal("BasicFrameTemplateWithInset", creationOf(recorded, FRAME_NAME).template)
            assert.same({ "FastFashionGalleryFrame" }, recorded.escapeClosed)
        end)
    end)

    describe("scrolling", function()
        ---A view whose list is longer than its window.
        ---@param options table? `{ offset, total, visible }`
        ---@return table spec
        local function scrollableView(options)
            options = options or {}
            local visible = options.visible or 2
            local total = options.total or 10
            local offset = options.offset or 0

            local rows = {}
            for index = 1, visible do
                rows[index] = { id = "row" .. (offset + index) }
            end

            return {
                rows = rows,
                scroll = {
                    offset = offset,
                    visible = visible,
                    total = total,
                    maxOffset = total - visible,
                    canScrollUp = offset > 0,
                    canScrollDown = offset < total - visible,
                },
            }
        end

        -- The pool is sized to the window, so the frame is the only party that knows how
        -- many rows fit and it has to say so before the first draw.
        it("tells the presenter how many rows fit", function()
            local frame, _, presenterRecorded = newFrame(scrollableView())

            frame.show()

            assert.equal(1, #presenterRecorded.viewportSizes)
            assert.is_true(presenterRecorded.viewportSizes[1] > 0)
        end)

        it("builds one widget per visible row, not one per set", function()
            local frame, recorded = newFrame(scrollableView({ visible = 2, total = 500 }))

            frame.show()

            assert.equal(2, #rowButtons(recorded))
        end)

        it("gives the list a scroll bar", function()
            local frame, recorded = newFrame(scrollableView())

            frame.show()

            assert.is_not_nil(scrollBarOf(recorded))
        end)

        -- Wheel up is +1 from the client and means "towards the start", which is a smaller
        -- offset; getting this backwards is the classic inverted-scroll bug.
        ---@type { label: string, delta: number, expected: number }[]
        local wheelCases = {
            { label = "up", delta = 1, expected = -1 },
            { label = "down", delta = -1, expected = 1 },
        }

        for _, case in ipairs(wheelCases) do
            it("scrolls " .. case.label .. " on a wheel " .. case.label, function()
                local frame, recorded, presenterRecorded = newFrame(scrollableView())
                frame.show()

                listOf(recorded):GetScript("OnMouseWheel")(listOf(recorded), case.delta)

                assert.same({ case.expected }, presenterRecorded.scrollBys)
            end)
        end

        it("scrolls to the offset the player dragged the bar to", function()
            local frame, recorded, presenterRecorded = newFrame(scrollableView())
            frame.show()
            local bar = scrollBarOf(recorded)

            bar:GetScript("OnValueChanged")(bar, 4)

            assert.same({ 4 }, presenterRecorded.scrollTos)
        end)

        -- The redraw pushes the offset back onto the bar, which fires the bar's own change
        -- handler; without the guard the two chase each other until the stack overflows.
        it("does not re-enter the presenter when the redraw syncs the bar", function()
            local frame, _, presenterRecorded = newFrame(scrollableView({ offset = 3 }))
            frame.show()

            assert.has_no.errors(function()
                frame.refresh()
            end)
            assert.same({}, presenterRecorded.scrollTos)
        end)

        it("moves the bar to follow the current offset", function()
            local frame, recorded, _, setView = newFrame(scrollableView())
            frame.show()

            setView(buildView(scrollableView({ offset = 5 })))
            frame.refresh()

            assert.equal(5, scrollBarOf(recorded).value)
        end)

        -- A dead bar on a list that fits reads as a broken window.
        it("hides the bar when the whole list fits", function()
            local frame, recorded = newFrame({ rows = { { id = "a" } } })

            frame.show()

            assert.is_false(scrollBarOf(recorded).shown)
        end)

        it("shows the bar again once the list outgrows the window", function()
            local frame, recorded, _, setView = newFrame({ rows = { { id = "a" } } })
            frame.show()

            setView(buildView(scrollableView()))
            frame.refresh()

            assert.is_true(scrollBarOf(recorded).shown)
        end)
    end)
end)
