local S = {}
local function nothing() end
local function disabled() return false end

function S.exclude(ui, document)
    if not document or not document.is_komikku then return end
    local stats = ui.statistics
    if not stats or stats._komikku_excluded then return end
    stats._komikku_excluded = true
    -- Instance only: keep the user's shared statistics settings and ordinary books untouched.
    stats.is_doc, stats.is_doc_not_frozen, stats.id_curr_book = false, false, nil
    stats.isEnabled, stats.isEnabledAndNotFrozen = disabled, disabled
    stats.onReaderReady, stats.initData, stats.getIdBookDB, stats.insertDB = nothing, nothing, nothing, nothing
end

function S.clean(root, backup_root)
    local lfs = require("libs/libkoreader-lfs")
    local path = require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
    if not lfs.attributes(path) then return 0 end
    local hashes = {}
    local settings = require("docsettings")
    for name in lfs.dir(root) do
        local dir = root .. "/" .. name
        if name:match("^%x+$") and lfs.attributes(dir, "mode") == "directory" then
            local sidecar = settings:open(dir .. "/chapter.kmk")
            local hash = sidecar:readSetting("partial_md5_checksum")
            if type(hash) == "string" and #hash == 32 and hash:match("^%x+$") then hashes[hash] = true end
        end
    end
    local conn = require("lua-ljsqlite3/init").open(path)
    local backup, statements = nil, {}
    local function prepare(sql)
        local stmt = conn:prepare(sql); statements[#statements + 1] = stmt; return stmt
    end
    local ok, result = pcall(function()
        local count, found = 0, {}
        local select = prepare("SELECT COUNT(*) FROM book WHERE md5 = ?")
        for hash in pairs(hashes) do
            local row = select:reset():bind(hash):step()
            local n = tonumber(row[1]) or 0
            if n > 0 then count = count + n; found[#found + 1] = hash end
        end
        if count == 0 then return 0 end
        select:reset()
        backup = backup_root .. "/statistics-before-clean-" .. os.date("%Y%m%d-%H%M%S") .. ".sqlite3"
        assert(not lfs.attributes(backup), "统计备份已存在，请稍后再试")
        -- SQLite makes a consistent backup, including committed WAL data, before deleting anything.
        prepare("VACUUM INTO ?"):bind(backup):step()
        conn:exec("BEGIN IMMEDIATE")
        local pages = prepare("DELETE FROM page_stat_data WHERE id_book IN (SELECT id FROM book WHERE md5 = ?)")
        local books = prepare("DELETE FROM book WHERE md5 = ?")
        for _, hash in ipairs(found) do pages:reset():bind(hash):step(); books:reset():bind(hash):step() end
        conn:exec("COMMIT")
        return count
    end)
    if not ok then pcall(conn.exec, conn, "ROLLBACK") end
    for _, stmt in ipairs(statements) do stmt:close() end
    conn:close()
    if not ok then error(result) end
    return result, backup
end

return S
