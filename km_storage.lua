local App = require("km_app")
local UI = require("ui/uimanager")
local S = {}
local function message(text) UI:show(require("ui/widget/infomessage"):new{ text = text }) end
local function size(bytes) return string.format("%.1f MiB", bytes / 1024 / 1024) end

local function active()
    local reader = require("apps/reader/readerui").instance
    local doc = reader and reader.document
    return doc and doc.is_komikku and doc.is_open and doc.km_dir or nil
end

local function confirm(text, task, after)
    UI:show(require("ui/widget/confirmbox"):new{ text = text .. "\n阅读进度和手机书架会保留。",
        ok_callback = function()
            local ok, err = pcall(task)
            if ok then after() else message(tostring(err):gsub("^.-:%d+: ", "")) end
        end,
    })
end

function S.show(owner, offline)
    local entries = App.cache:entries()
    local online_bytes, offline_bytes = 0, 0
    for _, e in ipairs(entries) do
        if e.offline then offline_bytes = offline_bytes + e.bytes else online_bytes = online_bytes + e.bytes end
    end
    if offline == nil then
        local limit = App.config.online_cache_limit_mb
        if limit == nil then limit = 128 end
        owner:menu("缓存管理", {
            { text = "手动离线下载", mandatory = size(offline_bytes), callback = function() S.show(owner, true) end },
            { text = "在线阅读缓存", mandatory = size(online_bytes), callback = function() S.show(owner, false) end },
            { text = "在线缓存上限：" .. (limit == 0 and "关闭自动清理" or (limit .. " MiB")),
                callback = function() S.limit(owner) end },
            { text = "清空在线阅读缓存", callback = function()
                confirm("清空在线缓存？手动离线下载和当前阅读章节将保留。", function()
                    local protected = active()
                    for _, e in ipairs(App.cache:entries()) do
                        if not e.offline and e.dir ~= protected then App.cache:removeDir(e.dir) end
                    end
                end, function() S.show(owner) end)
            end },
        })
        return
    end
    local items = {}
    for _, e in ipairs(entries) do
        if e.offline == offline then
            local m = e.manifest or {}
            local count = type(m.pages) == "table" and #m.pages or 0
            local status = e.done .. " / " .. count .. " 页 · " .. size(e.bytes)
            if e.offline then status = status .. (count > 0 and App.cache:isOffline(e.dir, count) and " · 已完成" or " · 未完成") end
            items[#items + 1] = { text = m.title or "未知章节", mandatory = status,
                callback = function() S.entry(owner, e) end }
        end
    end
    if #items == 0 then items[1] = { text = "暂无缓存", select_enabled = false } end
    owner:menu(offline and "手动离线下载" or "在线阅读缓存", items)
end

function S.entry(owner, entry)
    local m = entry.manifest or {}
    local manga, chapter
    if m.manga_key and m.chapter_key then manga, chapter = App:find(m.manga_key, m.chapter_key) end
    -- Old server caches remain removable but must not be opened with another server's credentials.
    local readable = chapter and App.cache:directory(chapter.url) == entry.dir
    owner:menu(m.title or "缓存章节", {
        { text = "阅读 / 继续阅读", select_enabled = not not readable,
            callback = function() if readable then owner:openChapter(manga, chapter) end end },
        { text = "继续下载整章", select_enabled = not not readable,
            callback = function() if readable then owner:download(manga, chapter) end end },
        { text = "删除本章缓存", callback = function()
            if active() == entry.dir then message("请先返回文件管理器，再删除当前章节缓存。") return end
            confirm("删除“" .. (m.title or "此章节") .. "”的缓存？", function()
                assert(active() ~= entry.dir, "当前章节正在阅读，请先返回文件管理器。")
                App.cache:removeDir(entry.dir)
            end, function() S.show(owner, entry.offline) end)
        end },
    })
end

function S.limit(owner)
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = "在线缓存上限（MiB）", input = tostring(App.config.online_cache_limit_mb or 128),
        input_hint = "0 关闭自动清理；1–4096。优先删除最早阅读的章节。",
        buttons = { {
            { text = "取消", callback = function() UI:close(dialog) end },
            { text = "保存", callback = function()
                local text = dialog:getInputText():match("^%s*(.-)%s*$")
                local value = text:match("^%d+$") and tonumber(text)
                if not value or value > 4096 then message("请输入 0–4096 的整数。") return end
                App.config.online_cache_limit_mb = value; App:saveConfig()
                local ok, err = pcall(App.cache.evict, App.cache, active())
                UI:close(dialog)
                if not ok then message(tostring(err)) end
                S.show(owner)
            end },
        } },
    }
    UI:show(dialog); dialog:onShowKeyboard()
end

return S
