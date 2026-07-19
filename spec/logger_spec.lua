local loader = require("addon_loader")

describe("ns.newLogger", function()
    local ns = loader.load()

    local PREFIX = "|cff33ff99FastFashion|r:"

    ---@param debugging boolean?
    ---@return Logger logger
    ---@return string[] lines everything the logger sent to its sink
    local function newLogger(debugging)
        local lines = {}
        local logger = ns.newLogger({
            sink = function(message)
                lines[#lines + 1] = message
            end,
            prefix = PREFIX,
            debug = debugging,
        })
        return logger, lines
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newLogger)
    end)

    describe("info", function()
        it("emits through the injected sink", function()
            local logger, lines = newLogger()

            logger.info("hello")

            assert.equal(1, #lines)
        end)

        it("prefixes the message", function()
            local logger, lines = newLogger()

            logger.info("hello")

            assert.equal(PREFIX .. " hello", lines[1])
        end)

        -- Info is the addon talking to the player; the debug flag must never gag it.
        it("emits whether or not debug logging is on", function()
            local quiet, quietLines = newLogger(false)
            local loud, loudLines = newLogger(true)

            quiet.info("hello")
            loud.info("hello")

            assert.equal(1, #quietLines)
            assert.equal(1, #loudLines)
        end)

        it("sends nothing before it is asked to", function()
            local _, lines = newLogger()

            assert.same({}, lines)
        end)
    end)

    describe("debug", function()
        -- Resolution diagnostics fire once per unresolved source, which is thousands of
        -- lines during a cold login; off is the only sane default.
        it("stays silent by default", function()
            local logger, lines = newLogger()

            logger.debug("set 1: not resolved yet")

            assert.same({}, lines)
        end)

        it("stays silent when the flag is explicitly false", function()
            local logger, lines = newLogger(false)

            logger.debug("set 1: not resolved yet")

            assert.same({}, lines)
        end)

        it("emits when started with debug logging on", function()
            local logger, lines = newLogger(true)

            logger.debug("set 1: not resolved yet")

            assert.equal(1, #lines)
            assert.is_truthy(lines[1]:find("set 1: not resolved yet", 1, true))
        end)

        it("carries the same prefix as info", function()
            local logger, lines = newLogger(true)

            logger.debug("noisy")

            assert.equal(PREFIX, lines[1]:sub(1, #PREFIX))
        end)
    end)

    describe("setDebug", function()
        it("turns debug logging on at runtime", function()
            local logger, lines = newLogger(false)

            logger.setDebug(true)
            logger.debug("noisy")

            assert.equal(1, #lines)
        end)

        it("turns debug logging back off", function()
            local logger, lines = newLogger(true)

            logger.setDebug(false)
            logger.debug("noisy")

            assert.same({}, lines)
        end)

        -- The slash command hands this whatever the player typed, so a nil or a string
        -- has to land as a plain boolean rather than leaking into the flag.
        it("treats a nil as off", function()
            local logger, lines = newLogger(true)

            logger.setDebug(nil)
            logger.debug("noisy")

            assert.same({}, lines)
        end)

        it("leaves info alone whichever way it is flipped", function()
            local logger, lines = newLogger(true)

            logger.setDebug(false)
            logger.info("hello")

            assert.equal(PREFIX .. " hello", lines[1])
        end)
    end)
end)
