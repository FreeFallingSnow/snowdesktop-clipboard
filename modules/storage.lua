-- modules/storage.lua - atomic history persistence, independent of the host API.
-- `commit` implements storage.transaction semantics: callback(tx), no partial
-- commit on failure. Keeping this small lets the test runner inject failures.

local storage = {}

function storage.write(commit, entry, dropped, encode)
    return commit(function(tx)
        tx:set("entry." .. entry.id, encode(entry))
        for index = 1, #dropped do tx:remove("entry." .. dropped[index]) end
    end)
end

function storage.removeDropped(commit, dropped)
    return commit(function(tx)
        for index = 1, #dropped do tx:remove("entry." .. dropped[index]) end
    end)
end

return storage
