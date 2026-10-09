local time = require("ui/time")
local logger = require("logger")
local Screen = require("device").screen
local util = require("util")
local LuaSettings = require("luasettings")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local Spore = require("Spore")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local load_script = require("Legado.Helper.Loader").load_script
local errHandler = require("Legado.Helper.Error")

local M = {
    name = "base",
    client = nil,
    settings = nil,
    _need_login = false,
    tokenManager = nil,
}

local AuthToken = {}
function AuthToken:new(key)
    local o = { key = key or "r3k", _memory_token = nil }
    setmetatable(o, self)
    self.__index = self
    return o
end

function AuthToken:_getConfig()
    return LuaSettings:open(Env.getTempDirectory() .. '/cache.lua')
end

function AuthToken:get()
    if self._memory_token then return self._memory_token end
    local token = self:_getConfig():readSetting(self.key)
    if H.is_str(token) and token ~= "" then
        self._memory_token = token
    end
    return self._memory_token
end

function AuthToken:set(token)
    if not H.is_str(token) or token == "" then
        return self:clear()
    end
    self._memory_token = token
    self:_getConfig():saveSetting(self.key, token):flush()
end

function AuthToken:clear()
    self._memory_token = nil
    self:_getConfig():delSetting(self.key):flush()
end

function M:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function M:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function M:init()
    local spec_name = tostring(self.name) .. "_spec"
    local _spec, err_msg = load_script("Legado.spore." .. spec_name)
    if not _spec then
        logger.err("LegadoSpec loading failed", err_msg)
        return 
    end
    local is_debug = false
    if is_debug then
        Spore.debug = {
            write = function(def, ...)
                logger.info(table.concat({...}))
            end  
        }
    end
    self.client = Spore.new_from_lua(_spec, { base_url = self.settings.server_address .. '/' })
    self._need_login = H.is_func(self.client.login) and (self.settings.reader3_un or "") ~= ""
    
    if self._need_login then
        self.tokenManager = AuthToken:new(self:getTokenKey())
        package.loaded["Spore.Middleware.Legado3Auth"] = require("Legado.spore.Middleware.Legado3Auth")
    end
    package.loaded["Spore.Middleware.FixJSON"] = require("Legado.spore.Middleware.FixJSON")
    package.loaded["Spore.Middleware.Format.UrlEncoded"] = require("Legado.spore.Middleware.Format.UrlEncoded")
end

function M:getTokenKey()
    local addr = H.is_str(self.settings.server_address) and self.settings.server_address or ""
    local user = H.is_str(self.settings.reader3_un) and self.settings.reader3_un or ""
    return string.format("%s_%s", self.name, H.md5(addr .. "|" .. user))
end

function M:ensureTokenManager()
    if not self.tokenManager then
        self.tokenManager = AuthToken:new(self:getTokenKey())
    end
    return self.tokenManager
end

function M:getLuaConfig(path)
    return LuaSettings:open(path)
end

function M:isNeedLogin(response)
    if not ( self._need_login == true and H.is_tbl(response)) then return false end
    local err_msg = response.data or response.errorMsg
    return H.is_str(err_msg) and string.find(err_msg, 'NEED_LOGIN', 1, true) ~= nil
end

function M:reader3Login()
    return nil, "reader3Login 函数未重写"
end

function M:ensureLogin()
    if not self._need_login then return true end

    local cache_token = self.tokenManager:get()
    if cache_token then
        return true, cache_token
    end
    return self:reader3Login()
end

function M:resetAndEnableMiddlewares(includeAuth)
    self.client:reset_middlewares()
    if includeAuth and self._need_login == true then
        self.client:enable("Legado3Auth", { app = self })
    end
    self.client:enable("Format.UrlEncoded")
    self.client:enable("Format.JSON")
    self.client:enable("FixJSON")
    self.client:enable("UserAgent", { 
        useragent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" 
    })
end

--[[
    与 Helper/Error.lua 的 pcall 同一套消息清洗，但多留一份 traceback。
    Error.lua 为了给用户看，把「文件:行号:」前缀正则剥掉了，只剩纯消息 —— 网络
    请求里最要的恰恰是这个行号，出过一次「attempt to compare number with nil」却
    完全不知道是谁比的。这里在错误还没栈展开时先把 traceback 抓下来。
]]
-- 最近一次失败的完整栈。LuaJIT 的 xpcall 只把错误处理器的第一个返回值带回来
-- （实测 b=nil），所以用上值把它捎出来，由 handleResponse 决定何时落盘。
-- 不存在跨调用的脏读：只在 pcall 返回后立刻读；重试那一支不读它，成功那一支清掉它。
local _last_trace = nil

local function pcall_with_trace(logName, f)
    local ok, res = xpcall(f, function(e)
        local err_msg = tostring(e or "unknown error")
        _last_trace = debug.traceback(err_msg, 3)
        local first_line = err_msg:match("^(.-)\n%s*stack traceback:") or err_msg:match("^(.-)\r?\n") or err_msg
        return (first_line:match("^.-:%d+:%s*(.+)$") or first_line):match("^%s*(.-)%s*$")
    end)
    if ok then _last_trace = nil end
    return ok, res
end

-- 服务端偶发返回 200 + application/json 但 body 为空。dkjson 的 scanvalue 会先做
-- c >= 48 比较，之后才轮到它自己那句「读到结尾」的兜底，于是抛
-- "attempt to compare number with nil"。这属于残响应，补试一次基本就有内容。
-- 下面几条是 dkjson 的报错原文，命中即视为可重试。
local JSON_DECODE_ERRORS = {
    "attempt to compare number with nil",
    "no valid json value",
    "unexpected character at position",
}

-- 只重试「等不到数据」和「响应体残缺」这两类。域名解析失败、连接被拒、服务不在，
-- 重试只是让人多等一倍时间。
local function is_transient_error(err_msg)
    if type(err_msg) ~= "string" then return false end
    local lower = err_msg:lower()
    if lower:match("wantread") or lower:match("timeout")
        or lower:match("closed") or lower:match("eof") then
        return true
    end
    for _, pattern in ipairs(JSON_DECODE_ERRORS) do
        if lower:find(pattern, 1, true) then return true end
    end
    return false
end

function M:handleResponse(requestFunc, callback, opts, logName, isRetry)
    local server_address = self.settings.server_address
    logName = logName or 'handleResponse'
    opts = opts or {}
  
    local timeouts = opts.timeouts
    if not H.is_tbl(timeouts) or not H.is_num(timeouts[1]) or not H.is_num(timeouts[2]) then
        timeouts = {8, 12}
    end
  
    self:resetAndEnableMiddlewares(true)
  
    socketutil:set_timeout(timeouts[1], timeouts[2])
    local status, res = pcall_with_trace(logName, requestFunc)
    socketutil:reset_timeout()
  
    if not (status and H.is_tbl(res) and H.is_tbl(res.body)) then
        logger.err(logName, "requestFunc err:", tostring(res))
        -- opts.retries：请求失败时补试的次数，超时预算由 opts.timeouts 自己管
        local left = H.is_num(opts.retries) and opts.retries or 0
        if left > 0 and is_transient_error(res) then
            local next_opts = {}
            for k, v in pairs(opts) do next_opts[k] = v end
            next_opts.retries = left - 1
            logger.info(logName, "请求失败，1 秒后重试，剩余次数", left - 1, "| 原因:", tostring(res))
            socket.sleep(1)
            return self:handleResponse(requestFunc, callback, next_opts, logName)
        end
        -- 只有「重试也用完了」才落盘完整栈。否则像 200+空 body 这类抖动，明明已经
        -- 自动救回来，却每天往 crash.log 灌十几段 traceback，看着像故障没修好。
        -- 反过来，日志里一旦出现 traceback 就说明这次是真没救回来。
        if _last_trace then
            logger.err(logName, "traceback:", _last_trace)
            _last_trace = nil
        end
        local err_msg = errHandler.map_message(res)
        return nil, string.format("Web 服务: %s", err_msg)
    end
  
    if isRetry ~= true and res.body.isSuccess == false and self:isNeedLogin(res.body) then
        if self.tokenManager then
            self.tokenManager:clear()
        end
        self:ensureLogin()
        logger.err("Need login, refreshed session and retrying")
        return self:handleResponse(requestFunc, callback, opts, logName, true)
    end

    if res.body.isSuccess == true then
          if not res.body.data then res.body.data = {} end
          if H.is_func(callback)  then
              return callback(res.body) 
           end
          return res.body.data
    else
        return nil, (res.body and res.body.errorMsg) and res.body.errorMsg or '出错'
    end
end

function M:unimplementedMethod(methodName)
    return nil, (methodName or "该功能") .. " 暂不支持"
end

function M:getBookshelf(callback)
    return self:unimplementedMethod("getBookshelf")
end

function M:saveBook(bookinfo, callback)
    return self:unimplementedMethod("saveBook")
end

function M:deleteBook(bookinfo)
    return self:unimplementedMethod("deleteBook")
end

function M:getChapterList(bookinfo, callback)
    return self:unimplementedMethod("getChapterList")
end

function M:getBookContent(chapter, callback)
    return self:unimplementedMethod("getBookContent")
end

function M:refreshBookContent(chapter, callback)
    return self:unimplementedMethod("refreshBookContent")
end

function M:saveBookProgress(chapter, callback)
    return self:unimplementedMethod("saveBookProgress")
end

function M:getProxyCoverUrl(coverUrl)
    return coverUrl
end

function M:getProxyImageUrl(bookUrl, img_src)
    return img_src
end

function M:getProxyEpubUrl(bookUrl, htmlUrl)
    return htmlUrl
end

function M:getAvailableBookSource(options, callback)
    return self:unimplementedMethod("getAvailableBookSource")
end

function M:changeBookSource(new_book_source, callback)
    return self:unimplementedMethod("changeBookSource")
end

function M:searchBookMulti(options, callback)
    return self:unimplementedMethod("searchBookMulti")
end

function M:searchBookSingle(options, callback)
    return self:unimplementedMethod("searchBookSingle")
end

function M:autoChangeBookSource(bookinfo, callback)
    return self:unimplementedMethod("autoChangeBookSource")
end

function M:getChaptersList(bookinfo)
    return self:unimplementedMethod("getChaptersList")
end

function M:getBookSourcesList(callback)
    return self:unimplementedMethod("getBookSourcesList")
end

function M:exploreBook(options, callback)
    return self:unimplementedMethod("exploreBook")
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    return self:unimplementedMethod("getBookSourcesExploreUrl")
end

return M
