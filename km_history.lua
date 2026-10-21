local H = { installed = false }

function H.install(root)
    if H.installed then return end
    H.installed = true
    local history = require("readhistory")
    local add, update = history.addItem, history.updateLastBookTime
    local realpath = require("ffi/util").realpath
    root = (realpath(root) or root):gsub("/+$", "") .. "/"
    local function owned(file)
        if not file then return false end
        file = realpath(file) or file
        return file:sub(1, #root) == root
    end
    function H.prune()
        local changed = false
        for i = #(history.hist or {}), 1, -1 do
            if owned(history.hist[i].file) then table.remove(history.hist, i); changed = true end
        end
        if changed and history._flush then history:_flush() end
        return changed
    end
    local read = history._read
    if read then
        function history:_read(...)
            local changed = read(self, ...)
            if changed then H.prune() end
            return changed
        end
    end
    function history:addItem(file, ...)
        if not owned(file) then return add(self, file, ...) end
    end
    function history:updateLastBookTime(...)
        local reader = require("apps/reader/readerui").instance
        if reader and reader.document and owned(reader.document.file) then return end
        if not self.hist or not self.hist[1] then return end
        return update(self, ...)
    end
    local collections = require("readcollection")
    local update_collection = collections.updateLastBookTime
    function collections:updateLastBookTime(file, ...)
        if not owned(file) then return update_collection(self, file, ...) end
    end
    H.prune()
end

return H
