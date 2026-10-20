local H = {}

function H.validateBase(base)
    assert(type(base) == "string", "请先配置 HTTPS 地址")
    local u = require("socket.url").parse(base)
    assert(u and u.scheme == "https" and u.host and not u.userinfo and not u.query and not u.fragment
        and not base:find("[%z\1-\32\127]"), "请输入 HTTPS 地址，不要包含账号、查询参数或片段")
    return base:gsub("/+$", "")
end

function H.escape(s)
    return (s:gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end))
end

function H.webdavUrl(config)
    local base = H.validateBase(config.webdav_url)
    local folder = config.webdav_folder or ""
    for part in folder:gmatch("[^/]+") do
        assert(part ~= "." and part ~= "..", "同步目录不能包含 . 或 ..")
        base = base .. "/" .. H.escape(part)
    end
    return base .. "/backup.proto"
end

function H.matchesHost(host, names)
    host = host:lower()
    for _, name in ipairs(names) do
        name = name:lower()
        if not name:find("%z") then
            if name == host then return true end
            local tail = name:match("^%*%.(.+)$")
            if tail and host:match("^[^.]+%.(.+)$") == tail then return true end
        end
    end
    return false
end

local function verifiedSocket(cafile)
    return function()
        local conn = require("ssl.https").tcp{ verify = "peer", cafile = cafile,
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" } }()
        local connect = conn.connect
        function conn:connect(host, port)
            local ok, err = connect(self, host, port)
            if not ok then return nil, err end
            local cert = self.sock:getpeercertificate()
            local san = cert and cert:extensions()["2.5.29.17"]
            local names = {}
            if san then
                local entries = host:match("^[%d%.]+$") and san.iPAddress or san.dNSName
                for _, name in ipairs(entries or {}) do names[#names + 1] = name end
            end
            -- Require SAN; modern public certificates have one. Never fall back to unverified TLS.
            if not H.matchesHost(host, names) then self:close(); return nil, "TLS 主机名不匹配" end
            return 1
        end
        return conn
    end
end

function H.request(config, service, method, address, body, extra, destination)
    local url = require("socket.url")
    local parsed = url.parse(address)
    assert(parsed and parsed.scheme == "https" and parsed.host and not parsed.userinfo
        and not address:find("[%z\1-\32\127]"), "请求地址必须为 HTTPS")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local headers = { ["Accept-Encoding"] = "identity", ["Connection"] = "close" }
    local user, password = config[service .. "_user"] or "", config[service .. "_password"] or ""
    assert(not user:find(":"), "用户名不能包含冒号")
    if service ~= "github" then headers.Authorization = "Basic " .. require("mime").b64(user .. ":" .. password) end
    local timeout = service == "github" and destination and 600 or 45
    if body then headers["Content-Length"] = tostring(#body); headers["Content-Type"] = "application/octet-stream" end
    for k, v in pairs(extra or {}) do headers[k] = v end
    local parts, size, limit = {}, 0, destination and 32 * 1024 * 1024 or 64 * 1024 * 1024
    local started = os.time()
    local file = destination and assert(io.open(destination .. ".part", "wb"), "无法创建下载文件")
    local sink = function(chunk)
        if chunk then
            if os.time() - started > timeout then return nil, "网络请求超时" end
            size = size + #chunk
            if size > limit then return nil, "响应超出大小限制" end
            if file then return file:write(chunk) and 1 or nil, "存储空间不足" end
            parts[#parts + 1] = chunk
        end
        return 1
    end
    local host = parsed.host
    local port = parsed.port or 443
    headers.Host = host .. (tostring(port) ~= "443" and (":" .. port) or "")
    -- LuaSocket handles HTTP framing; the custom socket performs verified TLS before sending headers.
    parsed.scheme, parsed.port = "http", port
    socketutil:set_timeout(10, timeout)
    local ok, result, code, response_headers = pcall(require("socket.http").request, {
        url = url.build(parsed), method = method, headers = headers, redirect = false,
        create = verifiedSocket(config.ca_file ~= "" and config.ca_file or "data/ca-bundle.crt"),
        source = body and ltn12.source.string(body) or nil, sink = sink,
    })
    socketutil:reset_timeout()
    if file then
        if ok and result and tonumber(code) == 200 then require("ffi/util").fsyncOpenedFile(file) end
        local closed = file:close()
        if not closed then result = nil end
    end
    if not ok or not result then
        if destination then os.remove(destination .. ".part") end
        error("网络、TLS 或写入失败；请检查地址、证书、设备时间及存储空间")
    end
    code = tonumber(code)
    if destination then
        if code == 200 and size > 0 then
            assert(os.rename(destination .. ".part", destination), "无法保存下载文件")
        else os.remove(destination .. ".part") end
    end
    local normalized = {}
    for k, v in pairs(response_headers or {}) do normalized[k:lower()] = v end
    return destination and size or table.concat(parts), code, normalized
end

return H
