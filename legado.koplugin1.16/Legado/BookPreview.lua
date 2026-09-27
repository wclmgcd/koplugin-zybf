local UIManager = require("ui/uimanager")
local util = require("util")

local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local PlgState = require("Legado/PlgState")
local PreviewTopBar = require("Legado/PreviewTopBar")
local H = require("Legado/Helper")
local TaskProg = require("Legado.task.Progress")

--[[
    BookPreview - 试读

    搜索结果里的书还没入库，先用内存里的目录读一读：
    目录缓存在 session 表里，翻页走 session，不查数据库。
]]

local M = {}

local session = nil

local function library_view()
    return require("Legado/LibraryView"):getInstance()
end

local function preview_cache_id(bookinfo)
    if H.is_str(bookinfo.cache_id) then return bookinfo.cache_id end
    local name = H.is_str(bookinfo.name) and util.trim(bookinfo.name) or ""
    local author = tostring(bookinfo.author or "")
    bookinfo.cache_id = tostring(H.md5(("%s (%s)"):format(name, author)))
    return bookinfo.cache_id
end

-- 书源目录字段不统一：index 为章节序号，isVolume 是卷标题
local function normalize_chapters(body)
    if not H.is_tbl(body) then return {} end

    local raw = body
    if not H.is_num(raw[1] and raw[1].index) and H.is_tbl(raw.data) then
        raw = raw.data
    end

    local chapters = {}
    for _, ch in pairs(raw) do
        if H.is_tbl(ch) and H.is_num(ch.index) and ch.isVolume ~= true then
            table.insert(chapters, {
                index = math.floor(ch.index),
                title = H.is_str(ch.title) and ch.title or string.format("第%s章", tostring(ch.index)),
            })
        end
    end
    table.sort(chapters, function(a, b) return a.index < b.index end)
    return chapters
end

function M.active()
    return session
end

-- 菜单可见性用这个而不是 active()：会话刚建立、第一章还在下载时，
-- 屏幕上仍是原来的章节，此时不该把「试读中」当成可用项点亮。
function M.showing()
    if not session then return false end
    local current = PlgState:readingChapter()
    return H.is_tbl(current) and current.is_preview == true
end

function M.clear()
    PreviewTopBar.hide()
    session = nil
end

-- 正式阅读（非试读）接管阅读器时，试读会话作废
function M.adopt(chapter)
    if H.is_tbl(chapter) and chapter.is_preview == true then return end
    M.clear()
end

local function build_chapter(pos)
    if not session then return nil end
    local ch = session.chapters[pos]
    if not ch then return nil end

    local bookinfo = session.bookinfo
    local total = tonumber(bookinfo.totalChapterNum) or 0
    if total <= 0 then total = #session.chapters end

    return {
        is_preview = true,
        book_cache_id = session.cache_id,
        chapters_index = ch.index,
        title = ch.title,
        name = util.trim(bookinfo.name or ""),
        author = bookinfo.author,
        bookUrl = bookinfo.bookUrl,
        origin = bookinfo.origin,
        originName = bookinfo.originName,
        originOrder = bookinfo.originOrder or 0,
        totalChapterNum = total,
    }
end

function M.open(pos)
    if not (session and session.chapters[pos]) then return end
    session.pos = pos
    library_view():loadAndRenderChapter(build_chapter(pos))
end

-- 阅读时翻到章节头尾：用内存目录续读，返回 true 表示已处理
function M.turn(direction)
    if not session then return false end

    local current = PlgState:readingChapter()
    if not (H.is_tbl(current) and current.is_preview == true) then
        M.clear()
        return false
    end

    -- 以屏幕上真正显示的那一章为准，下载失败时不会错位
    local pos = session.by_index[current.chapters_index] or session.pos or 1
    local next_pos = pos + (direction == "prev" and -1 or 1)
    if not session.chapters[next_pos] then
        if direction ~= "prev" and not session.notified_end then
            session.notified_end = true
            MessageBox:info("试读结束：该书源目录已到末尾，加入书架后可读全部内容")
        elseif direction == "prev" and not session.notified_start then
            session.notified_start = true
            MessageBox:info("已是试读第一章")
        end
        return true
    end
    -- 续读位置由 onReaderReady 依据方向决定
    PlgState:chapterDirection(direction)
    M.open(next_pos)
    return true
end

function M:begin(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl) and bookinfo.bookUrl ~= "") then
        return MessageBox:error("该书源缺少书籍链接，无法试读")
    end

    local cache_id = preview_cache_id(bookinfo)

    return TaskProg.loading("正在获取试读目录 ", function()
        return Backend:getChaptersList(bookinfo)
    end, function(state, response)
        if state ~= true then return end
        Backend:HandleResponse(response, function(body)
            local chapters = normalize_chapters(body)
            if #chapters == 0 then
                return MessageBox:error("该书源没有可用目录，无法试读")
            end
            local by_index = {}
            for i, ch in ipairs(chapters) do
                if not by_index[ch.index] then by_index[ch.index] = i end
            end
            session = {
                bookinfo = bookinfo,
                cache_id = cache_id,
                chapters = chapters,
                by_index = by_index,
                pos = 1,
                added = false,
            }
            UIManager:nextTick(function()
                PlgState:chapterDirection("nil")
                M.open(1)
            end)
        end, function(err_msg)
            MessageBox:error("获取目录失败:", err_msg)
        end)
    end, nil, true)
end

-- 试读中直接入库：和搜索结果里的「添加」走同一条路，阅读继续留在试读会话里
function M.add_to_shelf()
    if not session then return end
    if session.added then
        return MessageBox:notice("该书已在书架中")
    end
    local bookinfo = session.bookinfo
    Backend:closeDbManager()
    return TaskProg.loading("加入书架 ", function()
        return Backend:addBookToLibrary(bookinfo)
    end, function(state, response)
        if state ~= true then return end
        Backend:HandleResponse(response, function()
            session.added = true
            -- 先换顶栏再弹提示：反过来会把顶栏顶到提示框上面
            M.ensure_top_bar(true)
            MessageBox:notice("已加入书架，可继续阅读")
            UIManager:nextTick(function()
                -- 只书架界面已经打开过时才自动排序，别为这事把 LibraryView 建出来
                local obj = package.loaded["Legado/LibraryView"]
                if obj and obj.instance then
                    obj.instance:syncRemoteOrder(true)
                end
            end)
        end, function(err_msg)
            MessageBox:error(err_msg or '操作失败')
        end)
    end, nil, true)
end

-- 退出试读：清会话 + 关阅读器。阅读器下面就是书架（crash.log 里
-- close ReaderUI 紧跟着 painting library_view），所以只要关掉这一层就够了；
-- 别改成 openLegadoFolder，那条会把文件浏览器盖到书架上面去。
-- 关闭排在 nextTick 里：顶栏的点击回调还在 UIManager 遍历这条窗口的点击区，
-- 那时同步 onClose 就是在拆自己站着的地板。
function M.exit()
    M.clear()
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
        end
    end)
end

-- 屏幕顶部常驻的两个方框：左「返回」右「加入书架」。试读时阅读菜单要三跳才能点到，
-- 而这两件事恰恰是翻着翻着就想做的，所以直接摆在页面上。
-- force 用来重建（换章后文案变了，或者顶栏被文档切换冲掉了）
function M.ensure_top_bar(force)
    if not session then return end
    local spec = {
        back_text = "返回",
        action_text = session.added and "已在书架" or "加入书架",
        on_back = M.exit,
        on_action = function()
            UIManager:nextTick(M.add_to_shelf)
        end,
    }
    if force then
        PreviewTopBar.refresh(spec)
    else
        PreviewTopBar.show(spec)
    end
end

return M
