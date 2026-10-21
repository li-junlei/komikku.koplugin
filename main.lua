local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local NetworkMgr = require("ui/network/manager")
local App = require("km_app")
local Sync = require("km_sync")
local Http = require("km_http")
local F = require("km_files")
local Plugin = WidgetContainer:extend{ name = "komikku", is_doc_only = false }

local function message(text) UIManager:show(InfoMessage:new{ text = text }) end

local function errorText(err)
    -- Do not show remote response bodies, URLs containing credentials, or request headers.
    return tostring(err):gsub("^.-:%d+: ", "")
end

local function worker(task, text)
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        local ok, value = pcall(task)
        return { ok = ok, value = ok and value or errorText(value) }
    end, text or "正在连接…（点击可取消）")
    if not completed then return nil end
    if not result or not result.ok then
        message(result and result.value or "操作未完成，本地进度已保留")
        return nil
    end
    return result.value
end

function Plugin:init()
    App:init()
    local registry = require("document/documentregistry")
    if not registry.known_providers.komikku then require("km_document"):register(registry) end
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if self.document and self.document.is_komikku then
        require("km_navigation").install(self.ui, self.document, self)
        local m = self.document.km_manifest
        self.manga, self.chapter = App:find(m.manga_key, m.chapter_key)
    end
end

function Plugin:addToMainMenu(items)
    items.komikku = {
        text = "Komikku 漫画",
        sub_item_table = {
            { text = "打开书架", callback = function() self:openShelf() end },
            { text = "浏览 Komga 书库", callback = function() require("km_library").open(self, worker) end },
            { text_func = function() return self:resumeText() end, callback = function() self:resume() end },
            { text = "缓存管理", callback = function() require("km_storage").show(self) end },
            { text = "设置", callback = function() self:settings() end },
            { text = "更新", callback = function() self:updateMenu() end },
            { text = "同步状态", callback = function() self:status() end },
        },
    }
    if self.document and self.document.is_komikku then
        table.insert(items.komikku.sub_item_table, {
            text = "漫画去灰", checked_func = function() return App.config.comic_degray == true end,
            callback = function()
                App.config.comic_degray = not App.config.comic_degray
                App:saveConfig()
                self.ui:handleEvent(require("ui/event"):new("RedrawCurrentPage"))
                UIManager:setDirty(self.ui.dialog, "full")
            end,
        })
    end
end

function Plugin:menu(title, items)
    local menu
    menu = Menu:new{
        title = title, item_table = items, is_enable_shortcut = false,
        width = require("device").screen:getWidth(), items_max_lines = 2,
        close_callback = function() UIManager:close(menu) end,
    }
    App.menus = App.menus or {}
    App.menus[#App.menus + 1] = menu
    UIManager:show(menu)
end

function Plugin:closeMenus()
    for _, menu in ipairs(App.menus or {}) do UIManager:close(menu) end
    App.menus = {}
end

function Plugin:sync(after)
    if App.syncing then return end
    if not App.config.webdav_url or App.config.webdav_url == "" then
        message("请先在设置中填写 WebDAV，同步目录与手机保持一致")
        return
    end
    NetworkMgr:runWhenConnected(function()
        if App.syncing then return end
        App.syncing = true
        Trapper:wrap(function()
            local ok, result = pcall(App.sync, App, function(task)
                return worker(task, "正在同步书架与进度…（点击可取消）")
            end)
            App.syncing = false
            if not ok then message(errorText(result)) end
            if after then after()
            elseif ok and result then self:status() end
        end)
    end)
end

function Plugin:openShelf()
    if App.config.auto_sync ~= false and NetworkMgr:isConnected() and App.config.webdav_url then
        self:sync(function() self:shelf() end)
    else self:shelf() end
end

function Plugin:shelf(category, page, cached_only)
    local shelf = App:reloadShelf()
    if not shelf then message("书架为空。请在手机启用书架、分类和章节同步，然后在设置的同步菜单中同步。离线时可从“缓存管理”进入。") return end
    local items, mangas = {}, {}
    items[#items + 1] = { text = "缩略图模式（每页 6 本）", callback = function()
        App.config.shelf_view = "covers"; App:saveConfig(); self:shelf(category)
    end }
    if category == nil then
        items[#items + 1] = { text = self:resumeText(), callback = function() self:resume() end }
        items[#items + 1] = { text = "按分类浏览", callback = function() self:categories() end }
    end
    for _, m in ipairs(shelf.mangas) do
        local visible = category == nil
        if category ~= nil then
            for _, id in ipairs(m.categories) do if id == category then visible = true end end
            if category == -1 and #m.categories == 0 then visible = true end
        end
        if m.favorite and visible then
            mangas[#mangas + 1] = m
            local read = 0
            for _, c in ipairs(m.chapters) do if App:current(m, c).read then read = read + 1 end end
            items[#items + 1] = { text = m.title, mandatory = read .. "/" .. #m.chapters,
                callback = function() self:chapters(m) end }
        end
    end
    if App.config.shelf_view == "covers" then self:coverShelf(mangas, category, page, cached_only); return end
    self:menu("Komikku 书架", items)
end

function Plugin:coverShelf(mangas, category, page, cached_only, context)
    local Grid = require("km_shelf")
    local selected, current, total = Grid.page(mangas, page)
    if context then selected, current, total = mangas, context.page, context.pages end
    local entries, missing = {}, {}
    local root = App.root .. "/covers"
    require("util").makePath(root)
    local lfs = require("libs/libkoreader-lfs")
    for _, m in ipairs(selected) do
        local path = root .. "/" .. require("ffi/sha2").md5((App.config.komga_url or "") .. "\0"
            .. (App.config.komga_user or "") .. "\0" .. m.key) .. ".jpg"
        local exists = (lfs.attributes(path, "size") or 0) > 0
        if not exists then missing[#missing + 1] = { manga = m, path = path } end
        local read = 0
        for _, c in ipairs(m.chapters) do if App:current(m, c).read then read = read + 1 end end
        entries[#entries + 1] = { manga = m, file = exists and path or nil,
            status = context and "点击查看 / 加入书架" or (read .. " / " .. #m.chapters .. " 章已读") }
    end
    local grid
    local function close() if grid and not grid.closed then UIManager:close(grid) end end
    local header_buttons
    if context then
        header_buttons = {}
        for _, button in ipairs(context.buttons) do
            local callback = button.callback
            header_buttons[#header_buttons + 1] = { text = button.text, callback = function() close(); callback() end }
        end
        header_buttons[#header_buttons + 1] = { text = "关闭", callback = close }
    end
    grid = Grid:new{
        entries = entries, page_number = current, page_count = total,
        title_text = context and context.title, header_buttons = header_buttons,
        on_page = function(number) close(); if context then context.on_page(number) else self:shelf(category, number) end end,
        on_list = function()
            close()
            if context then context.on_list() else App.config.shelf_view = "list"; App:saveConfig(); self:shelf(category) end
        end,
        on_categories = function() close(); self:categories() end,
        on_resume = function() close(); self:resume() end,
        on_select = function(m) close(); if context then context.on_select(m) else self:chapters(m) end end,
        on_closed = function()
            for i, menu in ipairs(App.menus or {}) do if menu == grid then table.remove(App.menus, i); break end end
        end,
    }
    App.menus = App.menus or {}
    App.menus[#App.menus + 1] = grid
    UIManager:show(grid)
    if not cached_only and #missing > 0 and NetworkMgr:isConnected() then
        Trapper:wrap(function()
            worker(function()
                for _, cover in ipairs(missing) do
                    pcall(require("km_komga").downloadCover, App.config, cover.manga, cover.path)
                end
                return true
            end, "正在加载本页封面…（最多 6 本，点击可取消）")
            if not grid.closed then
                close()
                if context then context.reload() else self:shelf(category, current, true) end
            end
        end)
    end
end

function Plugin:categories()
    local items = { { text = "未分类", callback = function() self:shelf(-1) end } }
    for _, c in ipairs(App.shelf.categories) do
        items[#items + 1] = { text = c.name, callback = function() self:shelf(c.order) end }
    end
    self:menu("书架分类", items)
end

function Plugin:orderedChapters(m)
    local chapters = {}
    for _, c in ipairs(m.chapters) do chapters[#chapters + 1] = c end
    table.sort(chapters, function(a, b)
        if a.order == b.order then return a.url < b.url end
        return a.order > b.order
    end)
    return chapters
end

function Plugin:chapters(m)
    local items, first = {}, nil
    local chapters = self:orderedChapters(m)
    for _, c in ipairs(chapters) do
        if not App:current(m, c).read and not first then first = c end
    end
    if first then items[#items + 1] = { text = "继续阅读：" .. first.name, callback = function() self:openChapter(m, first) end } end
    if #chapters == 0 then
        message("同步文件中没有章节。请在手机获取章节列表，并开启章节同步后重新同步。")
        return
    end
    for _, c in ipairs(chapters) do
        local p = App:current(m, c)
        items[#items + 1] = { text = (p.read and "✓ " or "") .. c.name,
            mandatory = p.page > 0 and ("第 " .. (p.page + 1) .. " 页") or nil,
            callback = function() self:chapterActions(m, c) end }
    end
    self:menu(m.title, items)
end

function Plugin:chapterActions(m, c)
    self:menu(c.name, {
        { text = "阅读 / 继续阅读", callback = function() self:openChapter(m, c) end },
        { text = "下载整章（离线阅读）", callback = function() self:download(m, c) end },
        { text = "删除本章下载与图片缓存", callback = function() self:deleteChapter(c) end },
    })
end

function Plugin:prepareChapter(m, c, metadata_only)
    local manifest, dir = App.cache:manifest(c.url)
    manifest.title, manifest.manga_key, manifest.chapter_key = m.title .. " · " .. c.name, m.key, c.key
    F.write(dir .. "/chapter.kmk", require("json").encode(manifest))
    local page = math.max(1, math.min(App:current(m, c).page + 1, #manifest.pages))
    if not metadata_only then App.cache:ensure(manifest, dir, page) end
    return { manifest = manifest, dir = dir, page = page }
end

function Plugin:openChapter(m, c)
    local function run()
        Trapper:wrap(function()
            App.cache:stopPrefetch()
            local result = worker(function() return self:prepareChapter(m, c, true) end,
                "正在准备漫画…（点击可取消）")
            if not result then return end
            local path = result.dir .. "/chapter.kmk"
            local settings = require("docsettings"):open(path)
            settings:saveSetting("last_page", result.page)
            settings:saveSetting("provider", "komikku")
            settings:flush()
            App.cache:markRead(result.dir)
            App.cache:evict(result.dir)
            self:closeMenus()
            require("apps/reader/readerui"):showReader(path, require("km_document"))
        end)
    end
    local dir = App.cache:directory(c.url)
    local cached = F.read(dir .. "/chapter.kmk")
    if cached then
        local manifest = require("json").decode(cached)
        local page = math.max(1, math.min(App:current(m, c).page + 1, #manifest.pages))
        if App.cache:hasPage(dir, page) then run(); return end
    end
    NetworkMgr:runWhenConnected(run)
end

function Plugin:download(m, c)
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            App.cache:stopPrefetch()
            local chapter = worker(function() return self:prepareChapter(m, c, true) end,
                "正在获取章节信息…（点击可取消）")
            if not chapter then return end
            self:downloadWithProgress(chapter.manifest, chapter.dir)
        end)
    end)
end

function Plugin:downloadWithProgress(manifest, dir)
    local ProgressDialog = require("ui/widget/progressbardialog")
    local dialog = ProgressDialog:new{
        title = "正在下载整章", subtitle = "准备下载…",
        progress_max = #manifest.pages, refresh_time_seconds = 1,
    }
    -- shortcut: subtitle layout follows KOReader 2026.07.2; recheck if its dialog layout changes.
    local group = dialog[1][1]
    local label = group[2]
    local closed, last_text = false, nil
    function dialog:onCloseWidget()
        closed = true
        return ProgressDialog.onCloseWidget(self)
    end
    local poll
    poll = function()
        if closed then return end
        local done, total, current, bytes = App.cache:downloadProgress(manifest, dir)
        local percent = math.floor(done * 100 / total)
        local text = string.format("%d / %d 页（%d%%）", done, total, percent)
        if current then text = text .. string.format(" · 第 %d 页：%.0f KiB", current, bytes / 1024) end
        text = text .. " · 点击取消"
        if text ~= last_text then
            last_text = text
            label:setText(text)
            group:resetLayout()
            dialog.progress_bar:setPercentage(done / total)
            UIManager:setDirty(dialog, "ui")
        end
        UIManager:scheduleIn(1, poll)
    end
    dialog:show()
    poll()
    local ok, result = pcall(worker, function()
        App.cache:download(manifest, dir)
        return true
    end, dialog)
    UIManager:unschedule(poll)
    -- Trapper's callback resumes its coroutine: never invoke it again on normal completion.
    dialog.dismiss_callback = nil
    if not closed then dialog:close() end
    if not ok then message(errorText(result))
    elseif result then message("整章已下载，可离线阅读。") end
end

function Plugin:deleteChapter(c)
    local dir = App.cache:directory(c.url)
    local reader = require("apps/reader/readerui").instance
    if reader and reader.document and reader.document.file == dir .. "/chapter.kmk" then
        message("请先关闭当前章节，再删除下载。") return
    end
    local confirm
    confirm = require("ui/widget/confirmbox"):new{
        text = "删除“" .. c.name .. "”的本地下载？阅读进度会保留。",
        ok_callback = function()
            local ok, err = pcall(App.cache.remove, App.cache, c.url)
            message(ok and "下载已删除，阅读进度已保留。" or errorText(err))
        end,
    }
    UIManager:show(confirm)
end

function Plugin:resume()
    local last = App.state.last
    if last then
        local m, c = App:find(last.manga, last.chapter)
        if c then self:openChapter(m, c); return end
    end
    message("暂无可继续阅读的记录，请从书架选择漫画。")
end

function Plugin:resumeText()
    local last = App.state.last
    local manga = last and App:find(last.manga)
    return manga and ("继续阅读 — " .. manga.title) or "继续阅读"
end

function Plugin:nextChapter(direction)
    if not self.chapter then return end
    local list = self:orderedChapters(self.manga)
    for i, c in ipairs(list) do
        if c.key == self.chapter.key then
            local target = list[i + (direction or 1)]
            if target then self:openChapter(self.manga, target)
            else message(direction == -1 and "已经是第一章。" or "已经是最后一章。") end
            return
        end
    end
end

function Plugin:readerContents()
    if not self.chapter then return end
    local list, index = self:orderedChapters(self.manga)
    for i, c in ipairs(list) do if c.key == self.chapter.key then index = i; break end end
    local function run(fn) return function() self:closeMenus(); fn() end end
    local items = {
        { text = "上一章", select_enabled = index and index > 1 or false,
            callback = run(function() self:nextChapter(-1) end) },
        { text = "重试当前章节", callback = run(function() self:openChapter(self.manga, self.chapter) end) },
        { text = "下一章", select_enabled = index and index < #list or false,
            callback = run(function() self:nextChapter(1) end) },
    }
    local current = self.ui:getCurrentPage()
    for page = 1, self.document:getPageCount() do
        items[#items + 1] = { text = "第 " .. page .. " 页", mandatory = page == current and "当前页" or nil,
            callback = run(function() self.ui:handleEvent(require("ui/event"):new("GotoPage", page)) end) }
    end
    self:menu("漫画目录 · " .. self.chapter.name, items)
end

function Plugin:updateMenu()
    local version = assert(loadfile(self.path .. "/_meta.lua"))().version
    self:menu("插件更新", {
        { text = "当前版本：" .. version, select_enabled = false },
        { text = "检查更新", callback = function() require("km_update").show(self, worker) end },
    })
end

function Plugin:syncSettings()
    self:menu("同步", {
        { text = "WebDAV 同步设置", callback = function() self:connectionSettings("webdav") end },
        { text = "自动同步：" .. (App.config.auto_sync == false and "关" or "开"), callback = function()
            App.config.auto_sync = App.config.auto_sync == false
            App:saveConfig(); self:syncSettings()
        end },
        { text = "立即同步", callback = function() self:sync() end },
    })
end

function Plugin:settings()
    self:menu("Komikku 设置", {
        { text = "Komga 连接", callback = function() self:connectionSettings("komga") end },
        { text = "Komga 同步来源", callback = function() require("km_library").sourceSettings(self) end },
        { text = "同步", callback = function() self:syncSettings() end },
        { text = "自定义 CA 证书路径（可选）", callback = function() self:caSetting() end },
        { text = "说明", callback = function()
            message("Komga 与 WebDAV 地址均使用 HTTPS。同步目录与手机保持一致；留空表示 WebDAV 地址的根目录。\n\n默认在线阅读，预取后续 2 页；缓存管理中可设置在线缓存上限，默认 128 MiB，0 表示关闭自动清理。最早阅读的章节优先清理，当前章节和手动离线下载受保护。\n\n账号信息保存在设备本地设置文件，请保管设备及备份。")
        end },
    })
end

function Plugin:connectionSettings(service)
    local dialog
    local fields = {
        { description = "HTTPS 地址", text = App.config[service .. "_url"] or "", hint = "https://…" },
        { description = "用户名", text = App.config[service .. "_user"] or "" },
        { description = "密码", text = App.config[service .. "_password"] or "", text_type = "password" },
    }
    if service == "webdav" then fields[#fields + 1] = {
        description = "同步目录（与手机一致，可留空）", text = App.config.webdav_folder or "",
    } end
    dialog = require("ui/widget/multiinputdialog"):new{
        title = service == "komga" and "Komga 连接" or "WebDAV 同步",
        fields = fields,
        buttons = { {
            { text = "取消", callback = function() UIManager:close(dialog) end },
            { text = "保存", callback = function()
                local values = dialog:getFields()
                local ok, base = pcall(Http.validateBase, values[1]:match("^%s*(.-)%s*$"))
                if not ok then message(errorText(base)); return end
                if values[2]:find(":") then message("用户名不能包含冒号"); return end
                if service == "webdav" then
                    local valid, err = pcall(Http.webdavUrl, { webdav_url = base, webdav_folder = values[4] })
                    if not valid then message(errorText(err)); return end
                end
                local identity_changed = base ~= App.config[service .. "_url"] or values[2] ~= App.config[service .. "_user"]
                    or (service == "webdav" and values[4] ~= App.config.webdav_folder)
                if identity_changed and self.chapter then
                    message("请先关闭漫画，再更换连接地址、用户或同步目录。") return
                end
                if service == "webdav" and next(App.state.pending) and (
                    base ~= App.config.webdav_url or values[2] ~= App.config.webdav_user
                    or values[4] ~= App.config.webdav_folder) then
                    message("还有待同步进度。请先同步，再更换 WebDAV 地址、用户或目录。") return
                end
                App.config[service .. "_url"], App.config[service .. "_user"], App.config[service .. "_password"] = base, values[2], values[3]
                if service == "webdav" then App.config.webdav_folder = values[4] end
                if service == "webdav" and identity_changed then App.config.komga_source_id = nil end
                App:saveConfig()
                if identity_changed and service == "webdav" then
                    local old = F.read(App.root .. "/shelf.proto")
                    if old then F.write(App.root .. "/shelf.previous.proto", old); os.remove(App.root .. "/shelf.proto") end
                    App.shelf = nil
                    App.state.last = nil
                    App:saveState()
                end
                UIManager:close(dialog)
                message("设置已保存。")
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Plugin:caSetting()
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = "自定义 CA 证书路径", input = App.config.ca_file or "",
        input_hint = "留空使用 KOReader 的 CA 证书",
        buttons = { {
            { text = "取消", callback = function() UIManager:close(dialog) end },
            { text = "保存", callback = function()
                App.config.ca_file = dialog:getInputText()
                App:saveConfig(); UIManager:close(dialog)
            end },
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function Plugin:status()
    local n = 0
    for _ in pairs(App.state.pending) do n = n + 1 end
    message("书架：" .. (App.shelf and #App.shelf.mangas or 0) .. " 部\n待同步章节：" .. n
        .. "\n上次同步：" .. (App.state.last_sync and os.date("%Y-%m-%d %H:%M", App.state.last_sync) or "尚未同步")
        .. "\n\n未匹配到远端章节的进度会继续保留，不会复活手机已删除的收藏。")
end

function Plugin:onReaderReady()
    if self.document and self.document.is_komikku then App.cache.active_dir = self.document.km_dir end
    if self.document and self.document.is_komikku then UIManager:setDirty(self.ui.dialog, "full") end
    if not self.chapter then return end
    local doc = self.document
    if not require("km_pageload").start(self) then return end
    App.cache:prefetch(doc.km_manifest, doc.km_dir, self.ui:getCurrentPage())
end

function Plugin:onPageUpdate(page)
    if self.document and self.document.is_komikku then UIManager:setDirty(self.ui.dialog, "full") end
    if not self.chapter then return end
    UIManager:nextTick(function()
        if not self.document or not self.document.is_open then return end
        local doc = self.document
        if self.ui:getCurrentPage() ~= page then return end
        if not require("km_pageload").start(self) then return end
        local ok, err = pcall(App.record, App, self.manga, self.chapter, page, doc:getPageCount(), doc.km_dir)
        if not ok then message(errorText(err)) end
        App.cache:prefetch(doc.km_manifest, doc.km_dir, page)
    end)
end

function Plugin:onSuspend()
    if self.chapter then
        require("km_pageload").stop(self)
        App.cache:stopPrefetch()
        local ok, err = pcall(App.record, App, self.manga, self.chapter, self.ui:getCurrentPage(),
            self.document:getPageCount(), self.document.km_dir)
        if not ok then message(errorText(err)) end
    end
end

function Plugin:onCloseDocument()
    if not self.chapter then return end
    self:onSuspend()
    App.cache.active_dir = nil
    self.chapter, self.manga = nil, nil
    UIManager:nextTick(function()
        local ok, err = pcall(App.cache.evict, App.cache)
        if not ok then message(errorText(err)) end
    end)
    if App.config.auto_sync ~= false and App.config.webdav_url and NetworkMgr:isConnected() then
        UIManager:nextTick(function() self:sync(function() end) end)
    end
end

function Plugin:onNetworkConnected()
    if self.chapter and App.config.auto_sync ~= false and App.config.webdav_url then
        UIManager:nextTick(function() self:sync(function() end) end)
    end
end

function Plugin:onResume()
    if self.chapter and NetworkMgr:isConnected() then
        self:onNetworkConnected()
        UIManager:nextTick(function() if self.chapter then require("km_pageload").start(self) end end)
    end
end

return Plugin
