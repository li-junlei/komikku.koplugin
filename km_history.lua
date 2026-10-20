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
    function history:addItem(file, ...)
        if not owned(file) then return add(self, file, ...) end
    end
    function history:updateLastBookTime(...)
        local reader = require("apps/reader/readerui").instance
        if reader and reader.document and owned(reader.document.file) then return end
        if not self.hist or not self.hist[1] then return end
        return update(self, ...)
    end
end

return H
