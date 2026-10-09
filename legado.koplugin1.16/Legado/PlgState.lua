local time = require("ui/time")

local M = {
    _selected_book = nil,
    _displayed_chapter = nil,
    _chapter_direction = nil,
    _readerui_is_showing = nil,
    _switch_since = nil,
    _switch_target = nil,

    last_page_turn_time = nil,
    last_reader_ready_time = nil,
    last_refresh_chapter_time = nil,
    ui_refresh_time = nil,
    
    book_links_homedir = nil, 
    shared_meta_data = nil, 
    shared_meta_data_directory = nil,
    
    plg_name = nil,
    plg_path = nil,
    is_low_version = nil,
    last_search_input = nil,
}

local is_str = function(s)
    return "string" == type(s)
end

local is_tbl = function(t)
    return "table" == type(t)
end

local is_boolean = function(t)
    return "boolean" == type(t)
end

function M:readingChapter(chapter)
    if is_tbl(chapter) and chapter.book_cache_id then
        M._displayed_chapter = chapter
        return M._displayed_chapter
    else
        local current = M._displayed_chapter
        if is_tbl(current) and current.book_cache_id then
            return current
        end
    end
end

function M:currentSelectedBook(book)
    if is_tbl(book) and book.cache_id then
        M._selected_book = book
    end
    return M._selected_book
end

function M:chapterDirection(direction)
    if is_str(direction) then
        if direction == "prev" or direction == "next" then
            M._chapter_direction = direction
        elseif direction == "nil" then
            M._chapter_direction = nil
        end
    end
    return M._chapter_direction
end

function M:readerUiVisible(is_showing)
    if is_boolean(is_showing) then
        M._readerui_is_showing = is_showing
    end
    return M._readerui_is_showing
end

-- 一次切章（下载 + 渲染）从触发到阅读器就绪要好几秒。这段窗口里再来一次触发，就会在
-- 正在拆除的阅读器上重复 switchDocument —— 叠两次就是整个 KOReader 崩回系统界面。
-- 判据用时间戳而不是布尔量：万一这轮切换半路失败、再没人来清标记，到点也必须自己
-- 放行，不能把翻页永久锁死。
-- target 是这轮要换到的文档路径；下载还没回来时不知道路径，留 nil —— 留 nil 表示
-- 「忙，但谁也不知道要换到哪」，那种情况下本轮的收尾渲染照样放行。
local SWITCH_PENDING_MAX_S = 8

function M:switchPending(mark, target)
    if mark == true then
        M._switch_since = time.now()
        M._switch_target = target
        return M._switch_since
    elseif mark == false then
        M._switch_since = nil
        M._switch_target = nil
        return nil
    end
    local since = M._switch_since
    if not since then return nil end
    if time.since(since) >= time.s(SWITCH_PENDING_MAX_S) then
        M._switch_since = nil
        M._switch_target = nil
        return nil
    end
    return since, M._switch_target
end

function M:sharedMetaData(dir, meta_data)
    if dir and meta_data then
        M.shared_meta_data_directory = dir
        M.shared_meta_data = meta_data
    end
    if is_str(M.shared_meta_data_directory) and M.shared_meta_data_directory == dir then
        return M.shared_meta_data
    end
    return nil
end

return M
