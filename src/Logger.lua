local _, ns = ...

---@class Logger
---@field info fun(message: string)
---@field debug fun(message: string) Suppressed unless the debug flag is on.
---@field setDebug fun(enabled: boolean)

---@class LoggerDeps
---@field sink fun(message: string) Where the line goes, e.g. `print`.
---@field prefix string Shown before every message.
---@field debug boolean? Start with debug logging on. Default false.

---@param deps LoggerDeps
---@return Logger
function ns.newLogger(deps)
    local sink = deps.sink
    local prefix = deps.prefix
    local debugging = deps.debug or false

    ---@param message string
    local function emit(message)
        sink(prefix .. " " .. message)
    end

    return {
        info = emit,

        ---Diagnostics for data the client streams in asynchronously — noisy by nature, and
        ---off unless someone is actually chasing a resolution problem.
        ---@param message string
        debug = function(message)
            if debugging then
                emit("|cff888888debug|r " .. message)
            end
        end,

        ---@param enabled boolean
        setDebug = function(enabled)
            debugging = enabled and true or false
        end,
    }
end
