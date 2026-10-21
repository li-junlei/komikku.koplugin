local P = {}

function P.stop(owner)
    if owner.page_wait then owner.page_wait.finish(false) end
end

function P.start(owner)
    local App = require("km_app")
    local UI = require("ui/uimanager")
    local doc = owner.document
    if not doc or not doc.is_open then return end
    local page = owner.ui:getCurrentPage()
    local cache, dir = App.cache, doc.km_dir
    if owner.blocked_page ~= page then owner.blocked_page = nil end
    if owner.page_wait then
        if owner.page_wait.page == page then return end
        P.stop(owner)
    end
    if cache:hasPage(dir, page) then return true end
    if owner.blocked_page == page then return end
    if doc.km_bad_page == page then
        owner.blocked_page = page
        UI:show(require("ui/widget/infomessage"):new{ text = "图片无法解码。请从目录重试当前章节，或检查服务器中的原图。" })
        return
    end
    local Progress = require("ui/widget/progressbardialog")
    local dialog = Progress:new{ title = "正在加载第 " .. page .. " 页", subtitle = "连接服务器…（点击可取消）",
        progress_max = 1, refresh_time_seconds = 1 }
    local task = { page = page }
    owner.page_wait = task
    local poll
    local function redraw()
        if owner.document ~= doc or not doc.is_open then return end
        doc.km_load_revision = (doc.km_load_revision or 0) + 1
        doc.mod_time = (doc.km_original_mod_time or doc.mod_time) .. ":load" .. doc.km_load_revision
        if owner.ui:getCurrentPage() == page then
            owner.ui:handleEvent(require("ui/event"):new("RedrawCurrentPage"))
            UI:setDirty(owner.ui.dialog, "full")
        end
    end
    function task.finish(success, error_text, cancelled)
        if task.finished then return end
        task.finished = true
        if poll then UI:unschedule(poll) end
        if owner.page_wait == task then owner.page_wait = nil end
        if not success then cache:stopPrefetch() end
        if error_text or cancelled then
            owner.blocked_page = page
            doc.km_page_status = doc.km_page_status or {}
            doc.km_page_status[page] = cancelled and "cancelled" or "failed"
        end
        dialog.dismiss_callback = nil
        if task.shown and not task.closed then task.closed = true; dialog:close() end
        if success or cancelled or error_text then redraw() end
        if error_text then
            UI:show(require("ui/widget/infomessage"):new{ text = error_text .. " 可从目录重试当前章节。" })
        end
    end
    function dialog:onCloseWidget()
        task.closed = true
        if not task.finished then task.finish(false, nil, true) end
        return Progress.onCloseWidget(self)
    end
    -- Keep a download already serving this page; otherwise give the visible page priority.
    local running = cache.pid and cache.prefetch_dir == dir and cache.prefetch_pages and cache.prefetch_pages[page]
    if running and cache.prefetch_order then
        for _, number in ipairs(cache.prefetch_order) do
            if not cache:hasPage(dir, number) then running = number == page; break end
        end
    end
    if doc.km_page_status then doc.km_page_status[page] = nil end
    if not running then
        local pages = {}
        for number = page, math.min(page + 2, #doc.km_manifest.pages) do
            if not cache:hasPage(dir, number) then pages[#pages + 1] = number end
        end
        local ok, result = pcall(cache.startPages, cache, doc.km_manifest, dir, pages)
        if not ok or not result then
            task.finish(false, "无法启动页面下载，请检查网络和设备资源。")
            return
        end
    end
    local group = dialog[1][1]
    local started, last_text = os.time(), nil
    poll = function()
        if task.finished then return end
        if owner.document ~= doc or not doc.is_open or owner.ui:getCurrentPage() ~= page then task.finish(false); return end
        local bytes, total, complete = cache:pageProgress(dir, page)
        if complete then task.finish(true); return end
        if not cache.pid or os.time() - started > 315 then
            task.finish(false, "页面下载失败或超时，请检查网络。")
            return
        end
        local text
        if total and total > 0 then
            text = string.format("%.0f / %.0f KiB（%d%%）", bytes / 1024, total / 1024, math.min(99, math.floor(bytes * 100 / total)))
            dialog.progress_bar:setPercentage(math.min(0.99, bytes / total))
        else
            text = string.format("已下载 %.0f KiB（服务器未提供总大小）", bytes / 1024)
        end
        text = text .. " · 点击取消"
        if last_text ~= text then
            last_text = text
            group[2]:setText(text); group:resetLayout()
            UI:setDirty(dialog, "ui")
        end
        UI:scheduleIn(1, poll)
    end
    task.shown = true
    dialog:show()
    poll()
end

return P
