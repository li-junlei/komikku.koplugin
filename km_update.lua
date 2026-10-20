local H = require("km_http")
local F = require("km_files")
local U = { repository = "li-junlei/komikku.koplugin" }

function U.newer(candidate, current)
    local function parts(s)
        local a, b, c = s:match("^v?(%d+)%.(%d+)%.(%d+)$")
        assert(a, "更新版本号格式无效")
        return { tonumber(a), tonumber(b), tonumber(c) }
    end
    local a, b = parts(candidate), parts(current)
    for i = 1, 3 do if a[i] ~= b[i] then return a[i] > b[i] end end
    return false
end

function U.get(config, address, destination)
    for _ = 1, 6 do
        local parsed = require("socket.url").parse(address)
        assert(parsed and parsed.scheme == "https" and not parsed.userinfo and not parsed.fragment
            and (parsed.host == "api.github.com" or parsed.host == "github.com"
                or parsed.host == "release-assets.githubusercontent.com" or parsed.host == "objects.githubusercontent.com"),
            "更新下载地址不是受支持的 GitHub HTTPS 地址")
        local value, code, headers = H.request(config, "github", "GET", address, nil,
            { ["User-Agent"] = "komikku-koplugin", Accept = "application/vnd.github+json" }, destination)
        if code == 200 then return value end
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            address = assert(headers.location, "GitHub 跳转缺少地址")
        elseif code == 403 or code == 429 then error("GitHub 请求受限，请稍后重试")
        elseif code == 404 then error("GitHub 暂无可用正式版本")
        else error("GitHub 请求失败（HTTP " .. tostring(code) .. "）") end
    end
    error("GitHub 下载跳转次数过多")
end

function U.check(config, current)
    local bytes = U.get(config, "https://github.com/" .. U.repository .. "/releases/latest/download/update.json")
    local release = require("json").decode(bytes)
    assert(type(release) == "table" and type(release.tag_name) == "string"
        and not release.draft and not release.prerelease, "GitHub 版本信息无效")
    if not U.newer(release.tag_name, current) then return { available = false } end
    local version = release.tag_name:gsub("^v", "")
    local name = "komikku-koplugin-" .. version .. ".zip"
    for _, asset in ipairs(release.assets or {}) do
        if asset.name == name then
            assert(type(asset.size) == "number" and asset.size > 0 and asset.size <= 32 * 1024 * 1024,
                "更新安装包大小无效")
            assert(type(asset.digest) == "string" and asset.digest:match("^sha256:%x+$") and #asset.digest == 71,
                "Release 缺少有效的安装包 SHA256")
            local address = "https://github.com/" .. U.repository .. "/releases/download/" .. release.tag_name .. "/" .. name
            assert(asset.browser_download_url == address, "更新安装包地址无效")
            return { available = true, version = version, size = asset.size, url = address,
                sha256 = asset.digest:sub(8):lower() }
        end
    end
    error("该版本尚未上传插件安装包")
end

function U.paths(plugin)
    assert(type(plugin) == "string" and plugin:match("/komikku%.koplugin$"), "无法确定插件安装目录")
    return plugin .. ".update", plugin .. ".previous"
end

function U.clean(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.symlinkattributes(path) then
        assert(lfs.symlinkattributes(path, "mode") == "directory", "更新暂存路径不是目录")
        assert(require("ffi/util").purgeDir(path), "无法清理更新暂存目录")
    end
end

function U.stage(config, release, zip, plugin)
    local size = U.get(config, release.url, zip)
    assert(size == release.size, "更新下载不完整，原插件未修改")
    local bytes = assert(F.read(zip), "无法读取更新安装包")
    assert(require("ffi/sha2").sha256(bytes) == release.sha256, "更新 SHA256 校验失败，原插件未修改")
    local stage = U.paths(plugin)
    U.clean(stage)
    require("util").makePath(stage)
    local arc = require("ffi/archiver").Reader:new()
    assert(arc:open(zip), "无法打开更新安装包")
    local ok, err = pcall(function()
        local seen, total, count = {}, 0, 0
        for entry in arc:iterate() do
            local name = entry.path:match("^komikku%.koplugin/(.+)$")
            if entry.mode == "directory" then
                assert(entry.path == "komikku.koplugin/" or entry.path == "komikku.koplugin/docs/", "更新包含意外目录")
            else
                assert(entry.mode == "file" and name and (name:match("^[%w_]+%.lua$")
                    or name == "README.md" or name:match("^docs/[%w_-]+%.md$")), "更新包含不安全路径或文件类型")
                assert(not seen[name], "更新包含重复文件")
                count, total = count + 1, total + tonumber(entry.size)
                assert(count <= 256 and entry.size >= 0 and entry.size <= 1024 * 1024 and total <= 8 * 1024 * 1024,
                    "更新解压大小超限")
                local content = assert(arc:extractToMemory(entry.path), "更新文件解压失败")
                if name:match("%.lua$") then assert(loadstring(content, "@" .. name), "更新包含无效 Lua 文件") end
                if name == "_meta.lua" then
                    assert(content:match('version%s*=%s*"([%d.]+)"') == release.version, "安装包版本与 Release 不一致")
                end
                if name:find("/", 1, true) then require("util").makePath(stage .. "/docs") end
                F.write(stage .. "/" .. name, content)
                seen[name] = true
            end
        end
        assert(not arc.err, "更新安装包损坏")
        assert(seen["main.lua"] and seen["_meta.lua"] and seen["km_update.lua"], "更新缺少必要文件")
        for name in pairs(seen) do
            if name:match("%.lua$") then
                for module in F.read(stage .. "/" .. name):gmatch('require%("(km_[^"]+)"%)') do
                    assert(seen[module .. ".lua"], "更新缺少依赖模块")
                end
            end
        end
    end)
    arc:close()
    if not ok then U.clean(stage); error(err) end
    return true
end

function U.install(plugin)
    local stage, backup = U.paths(plugin)
    assert(F.read(stage .. "/main.lua") and F.read(stage .. "/_meta.lua"), "更新尚未准备完成")
    U.clean(backup)
    assert(os.rename(plugin, backup), "无法备份旧插件，原插件未修改")
    if not os.rename(stage, plugin) then
        assert(os.rename(backup, plugin), "更新回退失败，请将 .previous 目录改回 komikku.koplugin")
        error("更新替换失败，已恢复旧插件")
    end
    require("ffi/util").fsyncDirectory(plugin .. "/main.lua")
end

function U.download(owner, worker, release)
    local App = require("km_app")
    local UI = require("ui/uimanager")
    local function message(text) UI:show(require("ui/widget/infomessage"):new{ text = text }) end
    if App.updating then return end
    if (owner.document and owner.document.is_komikku and owner.document.is_open) or App.syncing then
        message("请先返回文件管理器，并等待书架同步完成后再更新。") return
    end
    local zip = App.root .. "/update.zip"
    local stage = U.paths(owner.path)
    App.updating = true
    local Progress = require("ui/widget/progressbardialog")
    local dialog = Progress:new{ title = "下载更新 " .. release.version, subtitle = "准备连接 GitHub…",
        progress_max = release.size, refresh_time_seconds = 1 }
    local closed = false
    function dialog:onCloseWidget() closed = true; return Progress.onCloseWidget(self) end
    -- shortcut: subtitle position follows KOReader 2026.07.2; recheck when its dialog layout changes.
    local group, poll = dialog[1][1]
    local function cleanup()
        UI:unschedule(poll)
        dialog.dismiss_callback = nil
        if not closed then dialog:close() end
        os.remove(zip .. ".part"); os.remove(zip)
        App.updating = nil
        U.clean(stage)
    end
    os.remove(zip .. ".part"); os.remove(zip)
    poll = function()
        if closed then return end
        local lfs = require("libs/libkoreader-lfs")
        local size = lfs.attributes(zip, "size") or lfs.attributes(zip .. ".part", "size") or 0
        local done = math.min(size, release.size)
        local text = string.format("%.0f / %.0f KiB（%d%%）· 点击取消", done / 1024, release.size / 1024,
            math.floor(done * 100 / release.size))
        if done == release.size then text = "下载完成，正在校验并准备安装…" end
        group[2]:setText(text); group:resetLayout()
        dialog.progress_bar:setPercentage(done / release.size)
        UI:setDirty(dialog, "ui")
        UI:scheduleIn(1, poll)
    end
    dialog:show(); poll()
    local ok, result = pcall(worker, function() return U.stage(App.config, release, zip, owner.path) end, dialog)
    if ok and result then
        -- Directory replacement runs in the parent without a cancellation point.
        ok, result = pcall(U.install, owner.path)
        if ok then result = true end
    end
    cleanup()
    if not ok then message(tostring(result):gsub("^.-:%d+: ", ""))
    elseif result then
        UI:show(require("ui/widget/confirmbox"):new{
            text = "插件已更新至 " .. release.version .. "，重启 KOReader 后生效。",
            ok_text = "现在重启", ok_callback = function() UI:restartKOReader() end,
        })
    end
end

function U.show(owner, worker)
    local App = require("km_app")
    local UI = require("ui/uimanager")
    if App.updating then return end
    require("ui/network/manager"):runWhenConnected(function()
        require("ui/trapper"):wrap(function()
            local current = assert(loadfile(owner.path .. "/_meta.lua"))().version
            local release = worker(function() return U.check(App.config, current) end, "正在检查 GitHub Release…")
            if not release then return end
            if not release.available then
                UI:show(require("ui/widget/infomessage"):new{ text = "当前已是最新版本（" .. current .. "）。" })
                return
            end
            UI:show(require("ui/widget/confirmbox"):new{
                text = string.format("发现新版本 %s（当前 %s，%.0f KiB）。下载并安装？", release.version, current, release.size / 1024),
                ok_text = "下载更新", ok_callback = function()
                    require("ui/network/manager"):runWhenConnected(function()
                        require("ui/trapper"):wrap(function() U.download(owner, worker, release) end)
                    end)
                end,
            })
        end)
    end)
end

return U
