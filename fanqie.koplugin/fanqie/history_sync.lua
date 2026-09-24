-- history_sync.lua — 把番茄书籍桥接进 KOReader 的 ReadHistory，
-- 使主页类插件（如 simpleui.koplugin）能显示番茄正在阅读的书。
-- 做法与 legado.koplugin 相同：为每本书维护一个持久的“链接文件”
-- （<koreader data>/fanqie/links/<书名>-<作者>.html），把它加入阅读历史，
-- 并在其侧车（.sdr/metadata.html.lua）中同步书名、作者、阅读进度，
-- 同时把已下载的封面注册为 KOReader 自定义封面（simpleui 支持该通道）。
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local util = require("util")
local H = require("fanqie.helper")

local M = {
    -- 最近一次同步的 "book_id:chapter_index"，用于节流（每章同步一次）
    _last_key = nil,
}

local function safe_name(s)
    if not H.is_str(s) or s == "" then return "book" end
    return string.gsub(s, "[/\\:%*%?\"<>|]", "_")
end

M.get_links_dir = function()
    local dir = DataStorage:getFullDataDir() .. "/fanqie/links"
    H.make_dir(dir)
    return dir
end

M.link_path_for = function(book)
    if not (H.is_tbl(book) and book.book_id and book.title) then return nil end
    return M.get_links_dir() .. "/" .. safe_name(book.title)
        .. "-" .. safe_name(book.author) .. ".html"
end

local function write_link_blob(lnk, book)
    local f = io.open(lnk, "w")
    if not f then return false end
    f:write(string.format(
        "return {\n  book_id=%q,\n  title=%q,\n  authors=%q,\n  description=%q,\n}\n",
        tostring(book.book_id), tostring(book.title),
        tostring(book.author or ""), tostring(book.desc or "")))
    f:close()
    return true
end

-- sync(book, settings, percent) — 幂等；任何一步失败都不影响阅读主流程
M.sync = function(book, settings, percent)
    if not (H.is_tbl(book) and book.book_id and book.title) then return end
    local ok, err = pcall(function()
        local lnk = M.link_path_for(book)
        if not lnk then return end
        if not util.fileExists(lnk) then
            if not write_link_blob(lnk, book) then return end
        end
        if not util.fileExists(lnk) then return end

        local ReadHistory = require("readhistory")
        ReadHistory:addItem(lnk)

        local ds = DocSettings:open(lnk)
        ds:saveSetting("doc_props", {
            title = book.title,
            authors = book.author or "",
        })
        local p = tonumber(percent) or tonumber(book.progress)
        if p then
            if p < 0 then p = 0 end
            if p > 1 then p = 1 end
            ds:saveSetting("percent_finished", p)
        end
        ds:flush()

        if not DocSettings:findCustomCoverFile(lnk)
            and settings and settings.get_download_dir then
            local cover = settings:get_download_dir()
                .. "/covers/" .. safe_name(book.title) .. ".jpg"
            if util.fileExists(cover) then
                pcall(function() DocSettings:flushCustomCover(lnk, cover) end)
            end
        end
    end)
    if not ok then
        local ok_l, Log = pcall(require, "fanqie.logger")
        if ok_l and Log and Log.warn then
            Log.warn("[FanQie] history_sync failed:", tostring(err))
        end
    end
end

-- syncCurrent(plugin, force) — 同步当前正在阅读的书。
-- 默认按 "book_id:chapter_index" 节流（每章打开同步一次）；force 用于关书时。
M.syncCurrent = function(plugin, force)
    local ok_s, State = pcall(require, "fanqie.state")
    if not ok_s or not State then return end
    local book = State.current_book
    if not (H.is_tbl(book) and book.book_id and book.title) then return end
    local idx = tonumber(State.current_chapter_index) or 0
    local key = tostring(book.book_id) .. ":" .. tostring(idx)
    if not force and M._last_key == key then return end
    M._last_key = key

    local percent = tonumber(book.progress)
    local ok_c, calc = pcall(function()
        local chapters = State.current_chapters
        if not (chapters and #chapters > 0 and idx >= 1) then return nil end
        if not (plugin and plugin.getCurrentPageProgress) then return nil end
        local page_p = tonumber(plugin:getCurrentPageProgress()) or 0
        local v = ((idx - 1) + page_p) / #chapters
        if v >= 0 and v <= 1 then return v end
        return nil
    end)
    if ok_c and calc then percent = calc end

    M.sync(book, plugin and plugin.settings, percent)
end

-- findBookById(settings, book_id) — 从书架持久缓存中按 book_id 取书籍信息，
-- 供链接文件被点击时恢复阅读使用
M.findBookById = function(settings, book_id)
    if not (settings and settings.get_download_dir) then return nil end
    local path = settings:get_download_dir() .. "/shelf_cache.lua"
    if not util.fileExists(path) then return nil end
    local ok, books = pcall(dofile, path)
    if not ok or type(books) ~= "table" then return nil end
    for _, b in ipairs(books) do
        if tostring(b.book_id) == tostring(book_id) then return b end
    end
    return nil
end

-- prune(books) — 书架刷新后清理 links/ 下的孤儿链接。
-- books 是本次刷新得到的完整书架列表；其中不再存在的 book_id，对应的链接文件、
-- 侧车目录（含自定义封面）和阅读历史条目一并删除，作用等同 legado 的
-- BookLinks:verifyBooksMetadata()。
-- 番茄没有"删除书籍"这个本地操作（书架只读地跟随服务端），所以在服务端删书后，
-- 这里是唯一的清理时机。列表为空时不清理（可能是接口异常返回），避免误删全部。
-- 注意：书名/作者改名会改变链接路径，旧文件因 book_id 仍在书架里而被保留，
-- 点开仍正常，只是历史中会多一条旧标题的条目。
M.prune = function(books)
    if not (H.is_tbl(books) and #books > 0) then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs) then return end
    local ok, err = pcall(function()
        local alive = {}
        for _, b in ipairs(books) do
            if b and b.book_id then alive[tostring(b.book_id)] = true end
        end

        local dir = M.get_links_dir()
        local ReadHistory = require("readhistory")
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." and entry:match("%.html$") then
                local lnk = dir .. "/" .. entry
                local ok_r, conf = pcall(dofile, lnk)
                local book_id = ok_r and H.is_tbl(conf) and conf.book_id
                if not book_id or not alive[tostring(book_id)] then
                    if ReadHistory.removeItemByPath then
                        pcall(ReadHistory.removeItemByPath, ReadHistory, lnk)
                    end
                    local ok_d, ds = pcall(DocSettings.open, DocSettings, lnk)
                    if ok_d and ds and ds.purge then pcall(ds.purge, ds) end
                    os.remove(lnk)
                end
            end
        end
    end)
    if not ok then
        local ok_l, Log = pcall(require, "fanqie.logger")
        if ok_l and Log and Log.warn then
            Log.warn("[FanQie] history_sync prune failed:", tostring(err))
        end
    end
end

return M
