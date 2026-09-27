-- 段评：把书源正文里的各类评论标记归一化成 fanqie 的上标气泡样式，
-- 点击气泡时直接请求书源自带的评论 URL（抓不到只提示，不做任何猜测）。
local buffer = require("string.buffer")
local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")

local M = {}

M.PROTO = "legado-para"
M.CLASS = "para-comment"
-- normalize() 的匹配规则一变就要递增：章节缓存靠它判新旧，否则旧缓存里的书源气泡图会一直留着
M.SUFFIX = "-pc3"
-- 关掉段评时用的后缀（同样不能留空，见 cache_suffix）
M.SUFFIX_OFF = "-pc0"
-- 占位符不含 < > & " 等字符，可安全穿过 ContentParser 的剥标签 / 转义 / 首字下沉流程
local PH_PATTERN = "\001CMT(%d+)\001"

local KEYWORDS = { "评论", "段评", "章评", "讨论", "说两句", "抢沙发", "热评", "神评", "吐槽", "回复" }

local HREF_P  = "[hH][rR][eE][fF]%s*=%s*['\"](.-)['\"]"
local IDENT_P = "[iI][dD][eE][nN][tT]%s*=%s*['\"](.-)['\"]"
local ID_P    = "[iI][dD]%s*=%s*['\"](.-)['\"]"
local COUNT_P = "[cC][oO][uU][nN][tT]%s*=%s*['\"]?(%d+)"

local TEXT_KEYS  = { "content", "text", "commentContent", "replyContent", "comment", "body", "msg", "message" }
local USER_KEYS  = { "userName", "user_name", "nickName", "nickname", "nick_name", "username", "author", "by" }
local LIKE_KEYS  = { "likeCount", "like_count", "diggCount", "digg_count", "praise", "zan", "likes", "up" }
local REPLY_KEYS = { "replyCount", "reply_count", "subCommentCount", "childrenCount", "total" }
local TOTAL_KEYS = { "total", "totalCount", "total_count", "totalNum", "count" }
local TIME_KEYS  = { "createTime", "create_time", "createTimestamp", "create_timestamp", "timestamp", "time",
                     "addDate", "add_date", "created_at", "createdAt" }

function M.is_enabled(settings)
    -- 未设置视为开启：用户要求“不管什么书源都强制改成段评样式”
    if not H.is_tbl(settings) then return true end
    return settings.para_comment ~= false
end

function M.cache_suffix(settings)
    -- 两种状态都要有后缀：留空会撞上「段评功能上线前」那份老缓存文件，
    -- 一关开关就把书源自带的气泡又翻出来，正是要避免的现象
    return M.is_enabled(settings) and M.SUFFIX or M.SUFFIX_OFF
end

local function get_attr(attrs, pattern)
    if type(attrs) ~= "string" then return nil end
    return attrs:match(pattern)
end

local function has_keyword(s)
    if type(s) ~= "string" or s == "" then return false end
    for _, word in ipairs(KEYWORDS) do
        if s:find(word, 1, true) then return true end
    end
    return false
end

local function pick(t, keys)
    if not H.is_tbl(t) then return nil end
    for _, key in ipairs(keys) do
        local v = t[key]
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then
            if v ~= "" and v ~= false then return v end
        end
    end
    return nil
end

-- 各书源评论接口的字段嵌套深度不一，往下找几层比写死路径耐用
local function deep_pick(t, keys, depth)
    local v = pick(t, keys)
    if v ~= nil then return v end
    if not H.is_tbl(t) or depth <= 0 then return nil end
    for _, child in pairs(t) do
        if H.is_tbl(child) then
            local cv = deep_pick(child, keys, depth - 1)
            if cv ~= nil then return cv end
        end
    end
    return nil
end

-- 只为抠 SVG 里的 <text> 计数，不做通用解码；KOReader 侧没有现成的 base64 解码
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64_CHARS do
    B64_INDEX[B64_CHARS:sub(i, i)] = i - 1
end

local function b64_decode(data)
    if type(data) ~= "string" or data == "" then return nil end
    local s = (data:gsub("[^" .. B64_CHARS .. "]", ""))
    local out, acc, bits, n = {}, 0, 0, 0
    for i = 1, #s do
        local v = B64_INDEX[s:sub(i, i)]
        if v then
            acc = acc * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                n = n + 1
                out[n] = string.char(math.floor(acc / 2 ^ bits) % 256)
                acc = acc % 2 ^ bits
            end
        end
    end
    return table.concat(out)
end

--- 大灰狼类书源把 <comment> 换成了 data:image/svg+xml;base64 气泡图，
--- 计数只存在于图里的 <text>，解码后取出来；只要纯数字（可带 +），防止把别的内容当文字塞进正文
local function svg_display_text(b64)
    local svg = b64_decode(b64)
    if not svg then return nil end
    local text = svg:match("<text[^>]->%s*(.-)%s*</text>")
    if type(text) ~= "string" then return nil end
    if text:match("^%d+$") or text:match("^%d+%+$") then return text end
    return nil
end

--- 把正文中的段评标记替换成占位符
-- @return content 处理后的正文, list 序号 -> { count = 气泡数字, url = 评论接口或 nil }
function M.normalize(content)
    local list = {}
    if type(content) ~= "string" or content == "" then return content, list end

    local function push(item)
        list[#list + 1] = item
        return "\001CMT" .. #list .. "\001"
    end

    -- 1) <comment ident="..." count="..." /> ，ident 在多数书源里就是评论接口 URL
    content = content:gsub("<%??%s*[cC][oO][mM][mM][eE][nN][tT]([^>]-)%/?>", function(attrs)
        return push({
            count = tonumber(get_attr(attrs, COUNT_P)) or 0,
            url = get_attr(attrs, HREF_P) or get_attr(attrs, IDENT_P) or get_attr(attrs, ID_P),
        })
    end)

    -- 2) 图片形式的段评标记。两种来源：
    --    a. <img src="dp:comment/9">，轻阅读类书源的段评图，没有 HTTP 等价接口；
    --    b. 大灰狼把 <comment> 换成的 SVG 气泡图，评论接口藏在图后面的
    --       {"js":"showCmt('URL',...)"} 点击负载里。该负载自带双引号，写在双引号属性里
    --       本身就是畸形 HTML，所以只能整段匹配 <img> 再从里面抠。
    --    神评卡片、本章说卡片不在这个之列：它们是 style=FULL 的整幅卡片图（神评卡片第一行
    --    是「神评论」角标，没有数字可显示），墨水屏上又大又糊，用户要求完全屏蔽，直接丢掉。
    content = content:gsub("<[iI][mM][gG][^>]->", function(tag)
        if tag:find("dp:", 1, true) then
            return push({ count = 0 })
        end
        if tag:find("showFanqieComment", 1, true) or tag:find('"FULL"', 1, true)
            or tag:find("god_card_svg", 1, true) then
            return ""
        end
        local url = tag:match("showCmt%('([^']*)'")
        if not url then return end
        local b64 = tag:match("data:image/svg%+xml;base64,([%w%+%/=]+)")
        local label = b64 and svg_display_text(b64) or tag:match("count=(%d+)")
        return push({
            label = label,
            count = tonumber(label and label:match("^%d+")) or 0,
            url = url:find("^https?://") and url or nil,
        })
    end)

    -- 3) <a href="...">[37]</a> 或 <a href="...">37</a>；#锚点是脚注/目录，原样保留
    content = content:gsub("<a([^>]-)>%s*%[?%s*(%d+)%s*%]?%s*</a>", function(attrs, num)
        local href = get_attr(attrs, HREF_P)
        if href and href:find("^#") then return end
        return push({ count = tonumber(num) or 0, url = href })
    end)

    -- 4) <a href="...">37条评论</a> / <a href="...">说两句</a>
    content = content:gsub("<a([^>]-)>([^<>]-)</a>", function(attrs, text)
        local trimmed = util.trim(text)
        if trimmed == "" or not has_keyword(trimmed) then return end
        local href = get_attr(attrs, HREF_P)
        if href and href:find("^#") then return end
        return push({ count = tonumber(trimmed:match("(%d+)")) or 0, url = href })
    end)

    -- 5) 纯文本形式 [37条评论] / [说两句] ，只能改样式，点不出内容
    -- 只吃短方括号，避免误伤正文里的引语或拟声
    content = content:gsub("%[(.-)%]", function(inner)
        if #inner > 24 or not has_keyword(inner) then return end
        return push({ count = tonumber(inner:match("(%d+)")) or 0 })
    end)

    return content, list
end

--- 还原占位符：as_html 为真时生成气泡链接，否则（txt）直接丢弃
function M.restore(html, list, as_html)
    if type(html) ~= "string" or html == "" then return html end
    if not as_html or not H.is_tbl(list) then
        return (html:gsub(PH_PATTERN, ""))
    end
    return (html:gsub(PH_PATTERN, function(idx_str)
        local idx = tonumber(idx_str)
        local item = idx and list[idx]
        if not item then return "" end
        -- label 是书源气泡图里写死的显示值（可能是 "99+"），没有就退回数字
        local label = (H.is_str(item.label) and item.label) or tostring(item.count or 0)
        return string.format('<a class="%s" href="%s:%d">%s</a>', M.CLASS, M.PROTO, idx, label)
    end))
end

function M.css()
    -- 墨水屏黑白兼容：无动画、无倾斜、无 hover 底色
    return string.format([[
a.%s {
  font-size: 0.5em !important;
  vertical-align: super;
  text-decoration: none;
  margin-left: 2px;
  color: inherit !important;
  background: transparent !important;
}
]], M.CLASS)
end

function M.index_path(book_cache_id, chapters_index)
    if not (H.is_str(book_cache_id) and H.is_num(chapters_index)) then return nil end
    local dir = FS.joinPath(Env.getBookCachePath(book_cache_id), "para")
    FS.checkAndCreateFolder(dir)
    return FS.joinPath(dir, tostring(math.floor(chapters_index)) .. ".dat")
end

function M.save_index(book_cache_id, chapters_index, list)
    local path = M.index_path(book_cache_id, chapters_index)
    if not path then return end
    if not (H.is_tbl(list) and #list > 0) then
        if util.fileExists(path) then pcall(util.removeFile, path) end
        return
    end
    local ok, blob = pcall(buffer.encode, { list })
    if not ok or type(blob) ~= "string" then
        logger.warn("ParaComment: 段评索引序列化失败", tostring(blob))
        return
    end
    local fp = io.open(path, "wb")
    if not fp then return end
    fp:write(blob)
    fp:close()
end

function M.load_index(book_cache_id, chapters_index)
    local path = M.index_path(book_cache_id, chapters_index)
    if not path or not util.fileExists(path) then return {} end
    local fp = io.open(path, "rb")
    if not fp then return {} end
    local blob = fp:read("*a")
    fp:close()
    local ok, tbl = pcall(buffer.decode, blob)
    if not ok or not H.is_tbl(tbl) or not H.is_tbl(tbl[1]) then return {} end
    return tbl[1]
end

-- 书源评论接口的返回结构五花八门：广度优先找第一个“元素带正文的数组”
local function find_comment_array(root)
    local queue = { { v = root, d = 0 } }
    local i = 1
    while i <= #queue and i <= 200 do
        local node = queue[i]
        i = i + 1
        local t = node.v
        if H.is_tbl(t) then
            if #t > 0 and H.is_tbl(t[1]) and deep_pick(t[1], TEXT_KEYS, 3) ~= nil then
                return t
            end
            if node.d < 4 then
                for _, child in pairs(t) do
                    if H.is_tbl(child) then
                        queue[#queue + 1] = { v = child, d = node.d + 1 }
                    end
                end
            end
        end
    end
    return nil
end

local function format_time(raw)
    local num = tonumber(raw)
    if num then
        if num > 1e11 then num = math.floor(num / 1000) end
        if num > 0 then return os.date("%Y-%m-%d %H:%M", num) end
        return ""
    end
    if raw then return tostring(raw):sub(1, 32) end
    return ""
end

--- 在子进程里调用，返回值必须可 buffer.encode
function M.parse_comments(data, fallback_total)
    local out = { comments = {}, total = tonumber(fallback_total) or 0 }
    if not H.is_tbl(data) then return out end

    -- /para_review 这类服务器已经归一化过的返回：条目就在 comments（或 data.comments）里，
    -- 总数在 data.total，别让 BFS 先撞见 hot_comments
    local named = { "comments", "data_list", "list", "records", "rows" }
    local function named_list(root)
        if not H.is_tbl(root) then return nil end
        for _, key in ipairs(named) do
            local v = root[key]
            if H.is_tbl(v) and #v > 0 and H.is_tbl(v[1]) then return v end
        end
    end

    local arr = named_list(data)
        or (H.is_tbl(data.data) and named_list(data.data))
        or find_comment_array(data) or (#data > 0 and data or nil)
    if not arr then
        out.total = tonumber(pick(data, TOTAL_KEYS))
            or (H.is_tbl(data.data) and tonumber(pick(data.data, TOTAL_KEYS))) or 0
        return out
    end

    for _, raw in ipairs(arr) do
        if H.is_tbl(raw) then
            local text = deep_pick(raw, TEXT_KEYS, 3)
            if text and tostring(text) ~= "" then
                out.comments[#out.comments + 1] = {
                    user  = tostring(deep_pick(raw, USER_KEYS, 3) or "匿名"),
                    text  = tostring(text):gsub("<[^>]->", " "):gsub("%s+", " "):match("^%s*(.-)%s*$"),
                    like  = tonumber(deep_pick(raw, LIKE_KEYS, 3)) or 0,
                    reply = tonumber(deep_pick(raw, REPLY_KEYS, 3)) or 0,
                    time  = format_time(deep_pick(raw, TIME_KEYS, 3)),
                }
            end
        end
    end

    out.total = tonumber(pick(data, TOTAL_KEYS))
        or (H.is_tbl(data.data) and tonumber(pick(data.data, TOTAL_KEYS)))
        or #out.comments
    if out.total == 0 then out.total = #out.comments end
    return out
end

function M:fetch(url, count, callback)
    local Backend = require("Legado/Backend")
    -- 书源给的 ident 是给人看的页面（/get_para_review、/fanqie_comment?mode=paragraph…），
    -- 同一台服务器上换到 /para_review 才是 JSON，参数原样保留即可（实测无需任何登录 Cookie）。
    local host, path, query = url:match("^(https?://[^/]+)(/[^?]*%?)(.*)$")
    if host and (path:find("review", 1, true) or path:find("comment", 1, true)) then
        url = host .. "/para_review?" .. query
    end
    Backend:launchProcess(function()
        local httpReq = require("Legado.Helper.Http")
        local status, res = httpReq({
            url = url,
            timeout = 30,
            headers = {
                ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                ["Accept"] = "application/json, text/plain, */*",
            },
        }, true)
        if not status then error(tostring(res)) end
        local json = require("json")
        local ok, decoded = pcall(json.decode, res.data or "", json.decode.simple)
        if not ok or not H.is_tbl(decoded) then
            return { comments = {}, total = tonumber(count) or 0 }
        end
        return M.parse_comments(decoded, count)
    end, callback, 45)
end

function M:render(index, review_total, result)
    local UIManager = require("ui/uimanager")
    local MessageBox = require("Legado/MessageBox")
    local comments = (H.is_tbl(result) and H.is_tbl(result.comments)) and result.comments or {}
    local total = (H.is_tbl(result) and tonumber(result.total)) or #comments

    if #comments == 0 then
        MessageBox:info(string.format("本条段评共 %d 条评论，暂无可见数据", total))
        return
    end

    local parts = {}
    for i, comment in ipairs(comments) do
        local header = string.format("%d. %s (赞%d 回复%d)", i,
            tostring(comment.user or "匿名"), tonumber(comment.like) or 0, tonumber(comment.reply) or 0)
        if H.is_str(comment.time) and comment.time ~= "" then
            header = header .. "  " .. comment.time
        end
        parts[#parts + 1] = header .. "\n" .. tostring(comment.text or "")
    end

    local nav_row = {}
    if index > 1 then
        nav_row[#nav_row + 1] = {
            text = "上一段",
            callback = function()
                UIManager:close(M._viewer)
                M:show(index - 1)
            end,
        }
    end
    if index < review_total then
        nav_row[#nav_row + 1] = {
            text = "下一段",
            callback = function()
                UIManager:close(M._viewer)
                M:show(index + 1)
            end,
        }
    end

    local buttons_table = {}
    if #nav_row > 0 then buttons_table[#buttons_table + 1] = nav_row end
    buttons_table[#buttons_table + 1] = { {
        text = "关闭",
        callback = function() UIManager:close(M._viewer) end,
    } }

    local ok_tv, TextViewer = pcall(require, "ui/widget/textviewer")
    if not ok_tv or not TextViewer then
        MessageBox:info(table.concat(parts, "\n\n"))
        return
    end

    M._viewer = TextViewer:new{
        title = string.format("段评 %d/%d (共%d条)", index, review_total, total),
        text = table.concat(parts, "\n\n"),
        text_type = "book_info",
        justified = false,
        buttons_table = buttons_table,
    }
    UIManager:show(M._viewer)
end

--- 当前章节定位：内存态优先，取不到时退回章节文件自己的 DocSettings。
--- 阅读器重启、或从 simpleui/历史直接进书时 PlgState 是空的，
--- 但 doc_props 里存着 book_cache_id 和 chapters_index（LibraryView 用的是同一套兜底）。
local function chapter_context()
    local PlgState = require("Legado/PlgState")
    local chapter = PlgState:readingChapter()
    if H.is_tbl(chapter) and H.is_str(chapter.book_cache_id) and H.is_num(chapter.chapters_index) then
        return chapter
    end
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok_ui and ReaderUI and ReaderUI.instance and ReaderUI.instance.ui
    local file = ui and ui.document and ui.document.file
    if not H.is_str(file) then return nil end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return nil end
    local ok, doc_settings = pcall(DocSettings.open, DocSettings, file)
    local props = ok and doc_settings and doc_settings.data and doc_settings.data.doc_props
    if not (H.is_tbl(props) and H.is_str(props.book_cache_id) and H.is_num(props.chapters_index)) then
        return nil
    end
    return { book_cache_id = props.book_cache_id, chapters_index = props.chapters_index }
end

--- 点击气泡入口：index 为段评在本章内的序号
function M:show(index)
    local MessageBox = require("Legado/MessageBox")

    index = tonumber(index)
    if not index then return false end

    local chapter = chapter_context()
    if not H.is_tbl(chapter) then
        MessageBox:info("无法定位当前章节，段评不可用")
        return false
    end

    local list = M.load_index(chapter.book_cache_id, chapter.chapters_index)
    local item = list[index]
    if not H.is_tbl(item) then
        MessageBox:info("段评索引缺失，请清缓存后重新下载本章")
        return false
    end

    local url = H.is_str(item.url) and item.url:match("^https?://.+") or nil
    if not url then
        MessageBox:info(string.format("第 %d 段：该书源未提供段评接口", index))
        return false
    end

    MessageBox:info("正在获取段评...", 2)
    M:fetch(url, item.count, function(ok, result)
        if not ok then
            MessageBox:error("段评获取失败:", tostring(result))
            return
        end
        M:render(index, #list, result)
    end)
    return true
end

return M
