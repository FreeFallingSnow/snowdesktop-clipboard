local historyStorage = module.require("modules/storage.lua")

local function same(actual, expected, label)
    if actual ~= expected then
        error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function commit(data)
    return function(callback)
        local draft = {}
        for key, value in pairs(data) do draft[key] = value end
        callback({
            set = function(_, key, value) draft[key] = value end,
            remove = function(_, key) draft[key] = nil end,
        })
        for key in pairs(data) do data[key] = nil end
        for key, value in pairs(draft) do data[key] = value end
        return true
    end
end

return {
    ["commits a text entry and pruned keys as one snapshot"] = function()
        local data = { ["entry.old"] = "old" }
        local item = { id = "new", ts = 100, pinned = false, text = "fixture" }
        local changed = historyStorage.write(commit(data), item, { "old" },
            function(entry)
                return entry.ts .. "\t0\t" .. entry.text
            end)
        same(changed, true, "commit")
        same(data["entry.old"], nil, "pruned")
        same(data["entry.new"], "100\t0\tfixture", "new text")
    end,

    ["rejects failed commits without changing the previous snapshot"] = function()
        local data = { ["entry.old"] = "old" }
        local item = { id = "new", ts = 100, pinned = false, text = "fixture" }
        local function reject(callback)
            callback({
                set = function() error("must not leak partial set", 2) end,
                remove = function() end,
            })
        end
        local ok = pcall(historyStorage.write, reject, item, { "old" },
            function() return "encoded" end)
        same(ok, false, "rejected")
        same(data["entry.old"], "old", "old snapshot retained")
        same(data["entry.new"], nil, "new snapshot absent")
        local function rejectRemove(callback)
            callback({
                remove = function() error("injected remove failure", 2) end,
            })
        end
        local removed = pcall(historyStorage.removeDropped, rejectRemove, { "old" })
        same(removed, false, "failed remove propagates")
        same(data["entry.old"], "old", "failed remove retains old key")
    end,
}
