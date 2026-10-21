local App = require("km_app")
local C = require("km_catalog")
local UIManager = require("ui/uimanager")
local Network = require("ui/network/manager")
local Trapper = require("ui/trapper")
local L = {}

local function message(text) UIManager:show(require("ui/widget/infomessage"):new{ text = text }) end

local function request(worker, task, after, text)
    Network:runWhenConnected(function()
        Trapper:wrap(function()
            local value = worker(task, text)
            if value then after(value) end
        end)
    end)
end

function L.sourceSettings(owner)
    local shelf = App:reloadShelf()
    local items, seen = {}, {}
    local function save(id)
        App.config.komga_source_id = id
        App:saveConfig()
        message("同步来源已保存。书库仍访问设置中的 Komga 地址。")
    end
    items[#items + 1] = { text = "自动匹配", callback = function() save(nil) end }
    items[#items + 1] = { text = "手动填写手机来源 ID", callback = function()
        local dialog
        dialog = require("ui/widget/inputdialog"):new{
            title = "手机 Komga 来源 ID", input = App.config.komga_source_id or "",
            input_hint = "填写完整十进制 ID，可从下方来源列表查看",
            buttons = { {
                { text = "取消", callback = function() UIManager:close(dialog) end },
                { text = "保存", callback = function()
                    local id = dialog:getInputText():match("^%s*(.-)%s*$")
                    local valid = pcall(C.sourceBytes, id)
                    if not valid then
                        message("请填写完整、有效的十进制来源 ID。与手机同步时应使用手机 Komga 扩展对应的 ID。")
                        return
                    end
                    save(id); UIManager:close(dialog)
                end },
            } },
        }
        UIManager:show(dialog); dialog:onShowKeyboard()
    end }
    for _, m in ipairs(shelf and shelf.mangas or {}) do
        if C.isKomga(m) and not seen[m.source] then
            seen[m.source] = true
            local id = C.sourceId(m.source)
            items[#items + 1] = { text = (id == App.config.komga_source_id and "✓ " or "")
                .. m.title .. " · ID " .. id, callback = function() save(id) end }
        end
    end
    owner:menu("Komga 同步来源（独立使用无需设置）", items)
end

function L.open(owner, worker)
    local state = { filters = App.config.library_filters or {}, owner = owner, worker = worker }
    L.show(state, 1)
end

function L.show(state, page)
    App.config.library_filters = state.filters; App:saveConfig()
    request(state.worker, function() return C.browse(App.config, state.filters, page) end, function(result)
        state.result = result
        L.render(state)
    end, "正在浏览 Komga 书库…")
end

function L.render(state, cached_only)
    local owner, result = state.owner, state.result
    local function view(mode)
        local first = (result.page - 1) * result.page_size
        local size = mode == "covers" and 6 or 50
        App.config.library_view = mode; App:saveConfig()
        L.show(state, math.floor(first / size) + 1)
    end
    if App.config.library_view == "covers" then
        owner:coverShelf(result.items, nil, nil, cached_only, {
            title = "Komga 书库", page = result.page, pages = result.pages,
            on_page = function(page) L.show(state, page) end,
            on_list = function() view("list") end,
            on_select = function(m) L.select(state, m) end,
            reload = function() L.render(state, true) end,
            buttons = {
                { text = "列表", callback = function() view("list") end },
                { text = "搜索", callback = function() L.search(state) end },
                { text = "筛选", callback = function() L.filters(state) end },
                { text = "刷新", callback = function() L.show(state, result.page) end },
            },
        })
        return
    end
    local items = {
        { text = "缩略图模式（每页 6 本）", callback = function() view("covers") end },
        { text = "搜索：" .. (state.filters.search or ""), callback = function() L.search(state) end },
        { text = "筛选与排序", callback = function() L.filters(state) end },
    }
    for _, m in ipairs(result.items) do
        items[#items + 1] = { text = m.title, callback = function() L.select(state, m) end }
    end
    if result.page > 1 then items[#items + 1] = { text = "上一页", callback = function() L.show(state, result.page - 1) end } end
    if result.page < result.pages then items[#items + 1] = { text = "下一页", callback = function() L.show(state, result.page + 1) end } end
    if #result.items == 0 then items[#items + 1] = { text = "没有符合条件的漫画", select_enabled = false } end
    owner:menu("Komga 书库 · " .. result.page .. " / " .. result.pages, items)
end

function L.search(state)
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = "搜索 Komga 书库", input = state.filters.search or "",
        buttons = { {
            { text = "取消", callback = function() UIManager:close(dialog) end },
            { text = "搜索", callback = function()
                state.filters.search = dialog:getInputText(); UIManager:close(dialog); L.show(state, 1)
            end },
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

local function selectOne(state, title, key, options)
    local items = {}
    for _, option in ipairs(options) do
        items[#items + 1] = { text = (state.filters[key] == option.value and "✓ " or "") .. option.name,
            callback = function() state.filters[key] = option.value; L.filters(state) end }
    end
    state.owner:menu(title, items)
end

local function selectMany(state, title, key, options)
    local values = state.filters[key] or {}; state.filters[key] = values
    local items = { { text = "返回筛选", callback = function() L.filters(state) end } }
    for _, option in ipairs(options) do
        local index
        for i, v in ipairs(values) do
            if key == "author" then
                if v.name == option.value.name and v.role == option.value.role then index = i end
            elseif v == option.value then index = i end
        end
        items[#items + 1] = { text = (index and "✓ " or "") .. option.name, callback = function()
            if index then table.remove(values, index) else values[#values + 1] = option.value end
            selectMany(state, title, key, options)
        end }
    end
    state.owner:menu(title, items)
end

function L.filters(state)
    if not state.options then
        request(state.worker, function() return C.options(App.config) end, function(options)
            state.options = options; L.filters(state)
        end, "正在加载 Komga 筛选项…")
        return
    end
    local items = {
        { text = "应用筛选", callback = function() L.show(state, 1) end },
        { text = "重置筛选", callback = function() state.filters = {}; L.filters(state) end },
    }
    for _, option in ipairs({ {"unread","未读（含阅读中）"}, {"in_progress","阅读中"}, {"read","已读"}, {"descending","倒序"} }) do
        local key, title = option[1], option[2]
        items[#items + 1] = { text = (state.filters[key] and "✓ " or "") .. title,
            callback = function() state.filters[key] = not state.filters[key]; L.filters(state) end }
    end
    items[#items + 1] = { text = "查找类型", callback = function()
        selectOne(state, "查找类型", "kind", { {name="系列",value="series"}, {name="阅读列表",value="readlists"}, {name="单本",value="books"} })
    end }
    items[#items + 1] = { text = "合集（优先于查找类型）", callback = function()
        local options = { {name="无",value=""} }
        for _, c in ipairs(state.options.collections or {}) do options[#options + 1] = {name=c.name,value=c.id} end
        selectOne(state, "合集", "collection", options)
    end }
    items[#items + 1] = { text = "排序", callback = function()
        selectOne(state, "排序", "sort", { {name="相关度",value="relevance"}, {name="字母顺序",value="title"},
            {name="添加日期",value="createdDate"}, {name="更新日期",value="lastModifiedDate"}, {name="随机",value="random"} })
    end }
    items[#items + 1] = { text = "连载状态", callback = function()
        selectMany(state, "连载状态", "status", { {name="连载中",value="ONGOING"}, {name="已完结",value="ENDED"},
            {name="已中止",value="ABANDONED"}, {name="休刊",value="HIATUS"} })
    end }
    for _, group in ipairs({ {"libraries","library_id","书库"}, {"genres","genre","题材"}, {"tags","tag","标签"}, {"publishers","publisher","出版社"} }) do
        items[#items + 1] = { text = group[3], callback = function()
            local options = {}
            for _, value in ipairs(state.options[group[1]] or {}) do
                options[#options + 1] = type(value) == "table" and {name=value.name,value=value.id} or {name=value,value=value}
            end
            selectMany(state, group[3], group[2], options)
        end }
    end
    local roles = {}
    for _, author in ipairs(state.options.authors or {}) do
        roles[author.role] = roles[author.role] or {}
        roles[author.role][#roles[author.role] + 1] = {name=author.name,value={name=author.name,role=author.role}}
    end
    local sorted = {}; for role in pairs(roles) do sorted[#sorted + 1] = role end; table.sort(sorted)
    for _, role in ipairs(sorted) do
        items[#items + 1] = { text = "作者 · " .. role, callback = function() selectMany(state, role, "author", roles[role]) end }
    end
    items[#items + 1] = { text = "章节命名", callback = function() L.chapterSettings(state) end }
    state.owner:menu("Komga 筛选（与手机扩展相同规则）", items)
end

function L.chapterSettings(state)
    local dialog
    dialog = require("ui/widget/multiinputdialog"):new{
        title = "章节命名（同步时与手机保持一致）",
        fields = {
            { description="章节名称模板",text=App.config.komga_chapter_template or "{number} - {title} ({size})" },
            { description="译者分隔符",text=App.config.komga_scanlator_separator or "," },
        },
        buttons = { {
            {text="取消",callback=function() UIManager:close(dialog) end},
            {text="保存",callback=function()
                local values = dialog:getFields()
                App.config.komga_chapter_template, App.config.komga_scanlator_separator = values[1], values[2]
                App:saveConfig(); UIManager:close(dialog)
            end},
        } },
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function L.select(state, item)
    state.template = C.template(App.config, App:reloadShelf()) or C.defaultTemplate(App.config)
    request(state.worker, function() return C.prepare(App.config, state.template, item) end, function(manga)
        App:remember(manga)
        local existing = App:find(manga.key)
        local target = existing and #existing.chapters > 0 and existing or manga
        state.owner:menu(manga.title, {
            { text = "阅读 / 章节列表", callback = function() state.owner:chapters(target) end },
            { text = existing and existing.favorite and "管理书架收藏" or "加入书架",
                callback = function() L.manage(state.owner, target, state.worker) end },
            { text = "简介", callback = function() message(require("km_proto").get(manga.fields, 6, "", 2)) end },
            { text = "返回书库", callback = function() L.render(state, true) end },
        })
    end, "正在获取漫画与章节…")
end

function L.chooseCategory(state, manga)
    local items = {}
    local function add(category)
        if App.syncing then message("正在同步，请完成后再操作。") return end
        local ok, result = pcall(App.addToShelf, App, manga, category)
        if not ok then message(tostring(result):gsub("^.-:%d+: ", "")); return end
        message("已保存到书架。")
        L.autoSync(state.owner)
    end
    items[#items + 1] = { text = "未分类", callback = function() add(-1) end }
    for _, category in ipairs(App.shelf.categories) do
        items[#items + 1] = { text = category.name, callback = function() add(category.order) end }
    end
    items[#items+1] = {text="新建分类",callback=function()
        L.newCategory(state.owner, function(order) add(order) end)
    end}
    state.owner:menu("加入到哪个分类？", items)
end

function L.autoSync(owner)
    if App.config.webdav_url and App.config.webdav_url ~= "" and App.config.auto_sync ~= false
            and Network:isConnected() then owner:sync() end
end

function L.newCategory(owner, after)
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title="新建书架分类", input="", buttons={{
            {text="取消",callback=function() UIManager:close(dialog) end},
            {text="保存",callback=function()
                if App.syncing then message("正在同步，请完成后再操作。"); return end
                local ok, order = pcall(App.addCategory, App, dialog:getInputText())
                if not ok then message(tostring(order):gsub("^.-:%d+: ", "")); return end
                UIManager:close(dialog); after(order)
            end},
        }},
    }
    UIManager:show(dialog); dialog:onShowKeyboard()
end

function L.manage(owner, m, worker)
    local current = App:find(m.key) or m
    if not current.favorite then L.chooseCategory({owner=owner,worker=worker},current); return end
    owner:menu(current.title .. " · 书架", {
        {text="更改分类",callback=function() L.chooseCategory({owner=owner,worker=worker},current) end},
        {text="移出书架",callback=function()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text="将此漫画移出书架？阅读进度和已下载图片保留。",
                ok_callback=function()
                    if App.syncing then message("正在同步，请完成后再操作。"); return end
                    local ok, err = pcall(App.setFavorite,App,current,false)
                    if not ok then message(tostring(err):gsub("^.-:%d+: ", "")); return end
                    message("已移出书架。"); L.autoSync(owner)
                end,
            })
        end},
    })
end

function L.refresh(owner, m, worker)
    local kind, id = m.url:match("/api/v1/([%w]+)/([%w_-]+)$")
    request(worker,function()
        return C.prepare(App.config,{source=m.source,url=m.url},{kind=kind,id=id,title=m.title})
    end,function(fresh)
        App:remember(fresh)
        owner:chapters(App:find(fresh.key) or fresh)
    end,"正在刷新漫画与章节…")
end

return L
