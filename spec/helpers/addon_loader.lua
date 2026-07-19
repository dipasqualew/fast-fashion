---Loads the addon the way the WoW client does: parse the .toc, then execute each
---listed file with the (addonName, namespace) varargs. Because the .toc is the
---source of truth, a file missing from it fails the tests rather than only failing in game.
local loader = {}

local ROOT = (debug.getinfo(1, "S").source:match("@(.*/)") or "./") .. "../../"
local TOC = ROOT .. "fast-fashion.toc"

---@return string[] relative file paths, in load order
function loader.tocFiles()
    local files = {}
    local handle = assert(io.open(TOC, "r"), "cannot open " .. TOC)
    for line in handle:lines() do
        line = line:gsub("%s+$", "")
        if line ~= "" and not line:match("^##") and not line:match("^#") then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    handle:close()
    return files
end

---@param addonName string?
---@return table namespace populated by the addon files
function loader.load(addonName)
    local ns = {}
    for _, relative in ipairs(loader.tocFiles()) do
        local path = ROOT .. relative
        local chunk = assert(loadfile(path), "cannot load " .. path)
        chunk(addonName or "FastFashion", ns)
    end
    return ns
end

return loader
