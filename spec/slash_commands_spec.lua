local loader = require("addon_loader")

describe("ns.newSlashCommands", function()
    local ns = loader.load()

    ---A stub `GalleryFrame`. The command surface only ever asks the gallery to toggle or
    ---refresh, so counting those two calls is the whole contract between them.
    ---@return GalleryFrame gallery
    ---@return table recorded `{ toggles, refreshes }`
    local function newStubGallery()
        local recorded = { toggles = 0, refreshes = 0 }

        local gallery = {
            toggle = function()
                recorded.toggles = recorded.toggles + 1
            end,

            refresh = function()
                recorded.refreshes = recorded.refreshes + 1
            end,
        }

        return gallery, recorded
    end

    ---@return Logger logger
    ---@return table recorded `{ lines, debugStates }`
    local function newRecordingLogger()
        local recorded = { lines = {}, debugStates = {} }

        local logger = {
            info = function(message)
                recorded.lines[#recorded.lines + 1] = message
            end,

            debug = function() end,

            setDebug = function(enabled)
                recorded.debugStates[#recorded.debugStates + 1] = enabled
            end,
        }

        return logger, recorded
    end

    ---A stub `GalleryController`. `/ff refresh` has to drop the cached resolutions, not
    ---merely redraw them, so the count of those calls is its own contract.
    ---@return GalleryController controller, table recorded `{ refreshes }`
    local function newStubController()
        local recorded = { refreshes = 0 }
        return {
            refresh = function()
                recorded.refreshes = recorded.refreshes + 1
            end,
        }, recorded
    end

    ---A stub `WardrobeTab`.
    ---@return WardrobeTab tab, table recorded `{ selects }`
    local function newStubWardrobeTab()
        local recorded = { selects = 0 }
        return {
            select = function()
                recorded.selects = recorded.selects + 1
            end,
        }, recorded
    end

    ---@param db table? the SavedVariables root, so a test can assert what persisted
    ---@param deps table? `{ controller, wardrobeTab }`, both optional on the module too
    ---@return SlashCommands commands
    ---@return table gallery recorded
    ---@return table logger recorded
    ---@return table db
    local function newCommands(db, deps)
        db = db or {}
        deps = deps or {}
        local gallery, galleryRecorded = newStubGallery()
        local logger, loggerRecorded = newRecordingLogger()

        local commands = ns.newSlashCommands({
            gallery = gallery,
            controller = deps.controller,
            wardrobeTab = deps.wardrobeTab,
            logger = logger,
            db = db,
        })

        return commands, galleryRecorded, loggerRecorded, db
    end

    ---@param lines string[]
    ---@param fragment string
    ---@return boolean
    local function anyLineContains(lines, fragment)
        for _, line in ipairs(lines) do
            if line:find(fragment, 1, true) then
                return true
            end
        end
        return false
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newSlashCommands)
    end)

    describe("a bare /ff", function()
        -- The command a player types most often should do the thing they most likely want
        -- rather than lecturing them with a help screen.
        ---@type { label: string, input: string? }[]
        local cases = {
            { label = "nothing at all", input = "" },
            { label = "only spaces", input = "   " },
            { label = "a tab", input = "\t" },
            { label = "nil, as the client sends for an empty line", input = nil },
        }

        for _, case in ipairs(cases) do
            it("opens the gallery when given " .. case.label, function()
                local commands, gallery = newCommands()

                commands.handle(case.input)

                assert.equal(1, gallery.toggles)
            end)
        end

        it("says nothing while doing it", function()
            local commands, _, logger = newCommands()

            commands.handle("")

            assert.same({}, logger.lines)
        end)
    end)

    describe("the verbs", function()
        it("opens the gallery on sets", function()
            local commands, gallery = newCommands()

            commands.handle("sets")

            assert.equal(1, gallery.toggles)
        end)

        it("re-reads collection state on refresh", function()
            local commands, gallery = newCommands()

            commands.handle("refresh")

            assert.equal(1, gallery.refreshes)
        end)

        -- Refreshing is invisible — the gallery may not even be open — so it has to
        -- acknowledge itself or the player will type it again.
        it("confirms a refresh happened", function()
            local commands, _, logger = newCommands()

            commands.handle("refresh")

            assert.is_true(anyLineContains(logger.lines, "refresh"))
        end)

        it("does not open the gallery on refresh", function()
            local commands, gallery = newCommands()

            commands.handle("refresh")

            assert.equal(0, gallery.toggles)
        end)

        -- Redrawing without dropping the cached resolutions re-renders the very answers
        -- the resolvers already had, which makes `/ff refresh` look broken to a player who
        -- just collected a piece.
        it("drops the cached collection state on refresh", function()
            local controller, controllerRecorded = newStubController()
            local commands = newCommands(nil, { controller = controller })

            commands.handle("refresh")

            assert.equal(1, controllerRecorded.refreshes)
        end)

        it("drops the cache before redrawing, not after", function()
            local order = {}
            local gallery = {
                toggle = function() end,
                refresh = function()
                    order[#order + 1] = "redraw"
                end,
            }
            local commands = ns.newSlashCommands({
                gallery = gallery,
                controller = {
                    refresh = function()
                        order[#order + 1] = "drop"
                    end,
                },
                logger = newRecordingLogger(),
                db = {},
            })

            commands.handle("refresh")

            assert.same({ "drop", "redraw" }, order)
        end)

        -- The controller is optional on the deps, so a caller that wired only a frame
        -- still gets a working redraw rather than an error in the chat box.
        it("still redraws when no controller was injected", function()
            local commands, gallery = newCommands()

            commands.handle("refresh")

            assert.equal(1, gallery.refreshes)
        end)
    end)

    ---The gallery's home is its Collections tab where one could be attached, and the
    ---standalone window everywhere else. Both `/ff` and `/ff sets` are the same door.
    describe("opening the gallery where it actually lives", function()
        ---@type { label: string, input: string }[]
        local doors = {
            { label = "a bare /ff", input = "" },
            { label = "/ff sets", input = "sets" },
        }

        for _, case in ipairs(doors) do
            it("selects the wardrobe tab on " .. case.label .. " when one exists", function()
                local tab, tabRecorded = newStubWardrobeTab()
                local commands, gallery = newCommands(nil, { wardrobeTab = tab })

                commands.handle(case.input)

                assert.equal(1, tabRecorded.selects)
                assert.equal(0, gallery.toggles)
            end)

            it("toggles the standalone window on " .. case.label .. " when no tab exists", function()
                local commands, gallery = newCommands()

                commands.handle(case.input)

                assert.equal(1, gallery.toggles)
            end)
        end

        it("leaves the wardrobe tab alone on refresh", function()
            local tab, tabRecorded = newStubWardrobeTab()
            local commands = newCommands(nil, { wardrobeTab = tab })

            commands.handle("refresh")

            assert.equal(0, tabRecorded.selects)
        end)
    end)

    describe("help", function()
        it("lists every verb the addon answers to", function()
            local commands, _, logger = newCommands()

            commands.handle("help")

            for _, verb in ipairs(commands.commands()) do
                assert.is_true(anyLineContains(logger.lines, "/ff " .. verb))
            end
        end)

        it("advertises the verbs the MVP ships", function()
            local commands = newCommands()

            assert.same({ "sets", "refresh", "debug", "help" }, commands.commands())
        end)

        it("explains what each verb does, not just its name", function()
            local commands, _, logger = newCommands()

            commands.handle("help")

            assert.is_true(anyLineContains(logger.lines, "open the set gallery"))
        end)

        -- The list is handed out fresh so a caller cannot corrupt the dispatch order.
        it("hands out a copy of the verb list", function()
            local commands = newCommands()
            local first = commands.commands()

            first[1] = "mutated"

            assert.equal("sets", commands.commands()[1])
        end)
    end)

    describe("debug", function()
        -- Persisted, because the reason to turn debug on is usually a problem that only
        -- shows up during login, long before anyone can type the command.
        it("turns diagnostics on from a fresh saved-variables table", function()
            local commands, _, _, db = newCommands()

            commands.handle("debug")

            assert.is_true(db.debug)
        end)

        it("turns diagnostics back off on a second call", function()
            local commands, _, _, db = newCommands()

            commands.handle("debug")
            commands.handle("debug")

            assert.is_false(db.debug)
        end)

        it("respects a flag that was already persisted", function()
            local commands, _, _, db = newCommands({ debug = true })

            commands.handle("debug")

            assert.is_false(db.debug)
        end)

        -- The persisted flag is useless unless the live logger is told about it too.
        it("tells the logger about both directions", function()
            local commands, _, logger = newCommands()

            commands.handle("debug")
            commands.handle("debug")

            assert.same({ true, false }, logger.debugStates)
        end)

        ---@type { state: string, calls: number }[]
        local announcements = {
            { state = "on", calls = 1 },
            { state = "off", calls = 2 },
        }

        for _, case in ipairs(announcements) do
            it("announces that debug logging is " .. case.state, function()
                local commands, _, logger = newCommands()

                for _ = 1, case.calls do
                    commands.handle("debug")
                end

                assert.is_true(anyLineContains(logger.lines, "debug logging " .. case.state))
            end)
        end
    end)

    describe("how the player actually types", function()
        ---Nobody proof-reads a slash command. Case and stray spaces are typing noise, not
        ---a different command.
        ---@type { label: string, input: string, refreshes: number, toggles: number }[]
        local cases = {
            { label = "SETS shouted", input = "SETS", refreshes = 0, toggles = 1 },
            { label = "Sets in title case", input = "Sets", refreshes = 0, toggles = 1 },
            { label = "sets with a leading space", input = " sets", refreshes = 0, toggles = 1 },
            { label = "sets with a trailing space", input = "sets ", refreshes = 0, toggles = 1 },
            { label = "REFRESH shouted", input = "REFRESH", refreshes = 1, toggles = 0 },
            { label = "refresh padded both sides", input = "  refresh  ", refreshes = 1, toggles = 0 },
        }

        for _, case in ipairs(cases) do
            it("understands " .. case.label, function()
                local commands, gallery = newCommands()

                commands.handle(case.input)

                assert.equal(case.refreshes, gallery.refreshes)
                assert.equal(case.toggles, gallery.toggles)
            end)
        end

        it("ignores anything typed after the verb", function()
            local commands, gallery = newCommands()

            commands.handle("sets please")

            assert.equal(1, gallery.toggles)
        end)
    end)

    describe("a verb the addon does not know", function()
        -- A typo in a chat box must never surface as a Lua error; the player gets a
        -- sentence pointing at the help they need instead.
        it("does not error", function()
            local commands = newCommands()

            assert.has_no.errors(function()
                commands.handle("banana")
            end)
        end)

        it("quotes the verb back so the player can spot the typo", function()
            local commands, _, logger = newCommands()

            commands.handle("banana")

            assert.is_true(anyLineContains(logger.lines, "banana"))
        end)

        it("points at the help command", function()
            local commands, _, logger = newCommands()

            commands.handle("banana")

            assert.is_true(anyLineContains(logger.lines, "/ff help"))
        end)

        it("leaves the gallery alone", function()
            local commands, gallery = newCommands()

            commands.handle("banana")

            assert.equal(0, gallery.toggles)
            assert.equal(0, gallery.refreshes)
        end)
    end)
end)
