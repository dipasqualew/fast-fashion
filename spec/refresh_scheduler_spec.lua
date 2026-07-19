local loader = require("addon_loader")
local fake = require("fake_wow")

describe("ns.newRefreshScheduler", function()
    local ns = loader.load()

    ---Builds a scheduler over a fake clock. Time is injected rather than waited for, so
    ---these tests run at the speed of the rest of the suite.
    ---@param options table? `{ delay = number? }`
    ---@return RefreshScheduler scheduler
    ---@return table recorded `{ runs }` — how often the coalesced work actually happened
    ---@return table clock `{ queued, elapse }`
    local function newScheduler(options)
        options = options or {}
        local after, clock = fake.newTimer()
        local recorded = { runs = 0 }

        local scheduler = ns.newRefreshScheduler({
            after = after,
            delay = options.delay,
            run = function()
                recorded.runs = recorded.runs + 1
            end,
        })

        return scheduler, recorded, clock
    end

    it("is exported by the addon files", function()
        assert.is_function(ns.newRefreshScheduler)
    end)

    describe("coalescing a burst of events", function()
        -- GET_ITEM_INFO_RECEIVED fires once per item the server delivers, which during a
        -- first gallery open is hundreds of events across a handful of frames. Rebuilding
        -- the view for each one rebuilds it hundreds of times to show the same list.
        it("runs the work once for a whole burst of requests", function()
            local scheduler, recorded, clock = newScheduler()

            for _ = 1, 500 do
                scheduler.request()
            end
            clock.elapse()

            assert.equal(1, recorded.runs)
        end)

        it("arms exactly one timer for a whole burst", function()
            local scheduler, _, clock = newScheduler()

            for _ = 1, 500 do
                scheduler.request()
            end

            assert.equal(1, #clock.queued)
        end)

        it("does no work at all until the window expires", function()
            local scheduler, recorded = newScheduler()

            scheduler.request()

            assert.equal(0, recorded.runs)
        end)

        -- A change after the window is a new change, not a duplicate of the last one.
        it("runs again for a request after the window closed", function()
            local scheduler, recorded, clock = newScheduler()

            scheduler.request()
            clock.elapse()
            scheduler.request()
            clock.elapse()

            assert.equal(2, recorded.runs)
        end)

        -- The refresh itself touches the client and can provoke the very events that call
        -- back in here, so the flag has to be clear before the work runs or the request
        -- that follows a real change is swallowed.
        it("accepts a request made from inside the run itself", function()
            local after, clock = fake.newTimer()
            local runs = 0
            local scheduler
            scheduler = ns.newRefreshScheduler({
                after = after,
                run = function()
                    runs = runs + 1
                    if runs == 1 then
                        scheduler.request()
                    end
                end,
            })

            scheduler.request()
            clock.elapse()
            clock.elapse()

            assert.equal(2, runs)
        end)
    end)

    describe("the delay", function()
        it("uses the delay it was given", function()
            local scheduler, _, clock = newScheduler({ delay = 2.5 })

            scheduler.request()

            assert.equal(2.5, clock.queued[1].seconds)
        end)

        it("falls back to a default delay", function()
            local scheduler, _, clock = newScheduler()

            scheduler.request()

            assert.is_true(clock.queued[1].seconds > 0)
        end)
    end)

    describe("isArmed", function()
        it("starts unarmed", function()
            local scheduler = newScheduler()

            assert.is_false(scheduler.isArmed())
        end)

        it("reports itself armed while a refresh is pending", function()
            local scheduler = newScheduler()

            scheduler.request()

            assert.is_true(scheduler.isArmed())
        end)

        it("is unarmed again once the work has run", function()
            local scheduler, _, clock = newScheduler()
            scheduler.request()

            clock.elapse()

            assert.is_false(scheduler.isArmed())
        end)
    end)

    describe("cancel", function()
        -- The timer cannot be unscheduled, so cancelling clears the flag and lets the
        -- callback arrive to find nothing to do.
        it("stops an armed refresh from running", function()
            local scheduler, recorded, clock = newScheduler()
            scheduler.request()

            scheduler.cancel()
            clock.elapse()

            assert.equal(0, recorded.runs)
        end)

        it("reports itself unarmed after cancelling", function()
            local scheduler = newScheduler()
            scheduler.request()

            scheduler.cancel()

            assert.is_false(scheduler.isArmed())
        end)

        it("is harmless when nothing was armed", function()
            local scheduler, recorded, clock = newScheduler()

            assert.has_no.errors(function()
                scheduler.cancel()
            end)
            clock.elapse()
            assert.equal(0, recorded.runs)
        end)

        it("accepts a fresh request after a cancel", function()
            local scheduler, recorded, clock = newScheduler()
            scheduler.request()
            scheduler.cancel()

            scheduler.request()
            clock.elapse()

            assert.equal(1, recorded.runs)
        end)
    end)
end)
