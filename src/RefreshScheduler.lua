local _, ns = ...

---Collapses a storm of client data events into one refresh.
---
---`GET_ITEM_INFO_RECEIVED` fires once per item the server delivers, which during a login
---or a first gallery open means hundreds of events in a handful of frames. Refreshing on
---each one would rebuild the view hundreds of times to show the same list, so requests are
---coalesced: the first one arms a timer, every further one inside that window is absorbed,
---and the work runs once when it expires.
---@class RefreshScheduler
---@field request fun() Ask for a refresh; cheap, and safe to call in a tight event loop.
---@field cancel fun() Drop an armed refresh, for when the consumer goes away.
---@field isArmed fun(): boolean

---@class RefreshSchedulerDeps
---@field after fun(seconds: number, callback: fun()) C_Timer.After, injected so tests drive time.
---@field run fun() The work to coalesce.
---@field delay number? Seconds to absorb events for. Defaults to 0.5.

local DEFAULT_DELAY = 0.5

---@param deps RefreshSchedulerDeps
---@return RefreshScheduler
function ns.newRefreshScheduler(deps)
    local after = deps.after
    local run = deps.run
    local delay = deps.delay or DEFAULT_DELAY

    local armed = false

    return {
        request = function()
            if armed then
                return
            end
            armed = true

            after(delay, function()
                -- Cleared before running, not after: the refresh itself can touch the
                -- client and provoke the very events that call back in here, and leaving
                -- the flag set would swallow the request that follows a real change.
                if not armed then
                    return
                end
                armed = false
                run()
            end)
        end,

        ---The timer cannot be unscheduled, so cancelling clears the flag and lets the
        ---callback find nothing to do.
        cancel = function()
            armed = false
        end,

        isArmed = function()
            return armed
        end,
    }
end
