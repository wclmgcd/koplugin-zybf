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
M.SUFFIX = "-pc4"
-- 关掉段评时用的后缀（同样不能留空，见 cache_suffix）
M.SUFFIX_OFF = "-pc0"
-- 占位符不含 < > & " 等字符，可安全穿过 ContentParser 的剥标签 / 转义 / 首字下沉流程
local PH_PATTERN = "\001CMT(%d+)\001"

local KEYWORDS = { "评论", "段评", "章评", "讨论", "说两句", "抢沙发", "热评", "神评", "吐槽", "回复" }

local HREF_P  = "[hH][rR][eE][fF]%s*=%s*['\"](.-)['\"]"
local IDENT_P = "[iI][dD][eE][nN][tT]%s*=%s*['\"](.-)['\"]"
local ID_P    = "[iI][dD]%s*=%s*['\"](.-)['\"]"
local COUNT_P = "[cC][oO][uU][nN][tT]%s*=%s*['\"]?(%d+)"

-- 起点（段评）这类书源只在正文里留三个号（bid/cid/pid），接口和凭证都要现场拼：
-- 评论接口固定在 <书源站>/novel/comment/v2/paragraph_list，凭证就藏在服务器发来的
-- bookUrl 尾巴那段 JSON 里（"headers":{"authorization":"Bearer …"}），照抄即可。
local QID_API = "/novel/comment/v2/paragraph_list"
local AUTH_VAL_P = '[aA][uU][tT][hH][oO][rR][iI][zZ][aA][tT][iI][oO][nN]["\']?%s*:%s*["\']([^"\']+)'

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
-- @return content 处理后的正文,
--         list 序号 -> { count = 气泡数字, label = 显示值, url = 评论接口, qid = {bid,cid,pid} }
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

    -- 2) 图片形式的段评标记。三种来源：
    --    a. <img src="dp:comment/9">，轻阅读类书源的段评图，没有 HTTP 等价接口；
    --    b. 大灰狼把 <comment> 换成的 SVG 气泡图，评论接口藏在图后面的
    --       {"js":"showCmt('URL',...)"} 点击负载里。该负载自带双引号，写在双引号属性里
    --       本身就是畸形 HTML，所以只能整段匹配 <img> 再从里面抠。
    --    c. 起点（段评）的气泡图：{"style":"TEXT","type":"qd","click":"showCmt(bid,cid,pid,ts)"}
    --       —— 参数全是不带引号的数字，接口地址一个字节都没给，只能记下前三个号，
    --       点击时按 bookUrl 的站子拼 paragraph_list（第 4 个参数是服务器生成的时间戳，无用）。
    --       计数同样只在图里的 <text> 上。
    --    神评卡片、本章说卡片不在这个之列：它们是整幅卡片图（起点章评卡写作 "style":"full"，
    --    大灰狼写作 "FULL"；神评卡片第一行是「神评论」角标，没有数字可显示），
    --    墨水屏上又大又糊，用户要求完全屏蔽，直接丢掉。
    content = content:gsub("<[iI][mM][gG][^>]->", function(tag)
        if tag:find("dp:", 1, true) then
            return push({ count = 0 })
        end
        if tag:find("showFanqieComment", 1, true) or tag:find("showChapterCmt", 1, true)
            or tag:find('"FULL"', 1, true) or tag:find('"full"', 1, true)
            or tag:find("god_card_svg", 1, true) then
            return ""
        end
        local b64 = tag:match("data:image/svg%+xml;base64,([%w%+%/=]+)")
        local url = tag:match("showCmt%('([^']*)'")
        if url then
            local label = b64 and svg_display_text(b64) or tag:match("count=(%d+)")
            return push({
                label = label,
                count = tonumber(label and label:match("^%d+")) or 0,
                url = url:find("^https?://") and url or nil,
            })
        end
        local bid, cid, pid = tag:match("showCmt%((%d+),%s*(%d+),%s*(%d+)")
        if bid then
            local label = b64 and svg_display_text(b64)
            return push({
                -- 没有数字可显示时写「评」而不是 0：0 会让人以为这段没人说话
                label = label or "评",
                count = tonumber(label and label:match("^%d+")) or 0,
                qid = { bid = bid, cid = cid, pid = pid },
            })
        end
        -- 认不出的 SVG 点击负载一律丢掉：留着只会把那截畸形 HTML 原样印进正文
        if tag:find("data:image/svg+xml;base64,", 1, true) then return "" end
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

--- 索引文件名不带段评后缀，所以老文件必须还能读：第二格 bookUrl 是后加的，缺了就当没有
-- @param book_url 服务器给该书源拼的 bookUrl（尾巴上那段 JSON 里带着评论接口要用的凭证），可为 nil
function M.save_index(book_cache_id, chapters_index, list, book_url)
    local path = M.index_path(book_cache_id, chapters_index)
    if not path then return end
    if not (H.is_tbl(list) and #list > 0) then
        if util.fileExists(path) then pcall(util.removeFile, path) end
        return
    end
    local ok, blob = pcall(buffer.encode, { list, H.is_str(book_url) and book_url or nil })
    if not ok or type(blob) ~= "string" then
        logger.warn("ParaComment: 段评索引序列化失败", tostring(blob))
        return
    end
    local fp = io.open(path, "wb")
    if not fp then return end
    fp:write(blob)
    fp:close()
end

--- @return list, book_url
function M.load_index(book_cache_id, chapters_index)
    local path = M.index_path(book_cache_id, chapters_index)
    if not path or not util.fileExists(path) then return {}, nil end
    local fp = io.open(path, "rb")
    if not fp then return {}, nil end
    local blob = fp:read("*a")
    fp:close()
    local ok, tbl = pcall(buffer.decode, blob)
    if not ok or not H.is_tbl(tbl) or not H.is_tbl(tbl[1]) then return {}, nil end
    return tbl[1], H.is_str(tbl[2]) and tbl[2] or nil
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
    -- 站点用 200 + code≠0 表达业务错误（起点那句「获取段评失败」就是这么回来的），
    -- 不记下 msg 的话只能回一句「暂无可见数据」，什么也看不出来
    if type(data.code) == "number" and data.code ~= 0 then
        out.err = tostring(data.msg or data.error or ("code=" .. tostring(data.code)))
    end

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

    -- 起点返回里带 paragraph（这段被评论的原文），拿它当标题比只有序号有用
    local function paragraph_of(root)
        if not H.is_tbl(root) then return nil end
        local v = root.paragraph or (H.is_tbl(root.data) and root.data.paragraph)
        if type(v) ~= "string" then return nil end
        v = v:gsub("<[^>]->", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
        if v == "" then return nil end
        if #v > 240 then v = v:sub(1, 240) .. "…" end
        return v
    end
    out.paragraph = paragraph_of(data)

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
            -- 用户口径：墨水屏上只要文字段评，图片一个字节都不取。
            -- 带图的评论只留它自己的文字，imageUrl 根本不看；
            -- 纯图片评论（没有文字）直接跳过，只数一个「已屏蔽」；
            -- 纯语音评论留一行说明，不去下那个 m4a。
            local text = deep_pick(raw, TEXT_KEYS, 3)
            if type(text) ~= "string" then text = nil end
            local has_img = H.is_str(raw.imageUrl) and raw.imageUrl ~= ""
            local has_audio = H.is_str(raw.audioUrl) and raw.audioUrl ~= ""
            local entry
            if text and text ~= "" then
                entry = { text = text:gsub("<[^>]->", " "):gsub("%s+", " "):match("^%s*(.-)%s*$") }
            elseif has_img then
                out.skipped = (out.skipped or 0) + 1
            elseif has_audio then
                entry = { text = "(语音评论)" }
            end
            if entry then
                entry.user  = tostring(deep_pick(raw, USER_KEYS, 3) or "匿名")
                entry.like  = tonumber(deep_pick(raw, LIKE_KEYS, 3)) or 0
                entry.reply = tonumber(deep_pick(raw, REPLY_KEYS, 3)) or 0
                entry.time  = format_time(deep_pick(raw, TIME_KEYS, 3))
                out.comments[#out.comments + 1] = entry
            end
        end
    end

    out.total = tonumber(pick(data, TOTAL_KEYS))
        or (H.is_tbl(data.data) and tonumber(pick(data.data, TOTAL_KEYS)))
        or #out.comments
    if out.total == 0 then out.total = #out.comments end
    return out
end

--- 书源给的评论地址有两种形态，只改写其中一种：
---   给人看的页面（/get_para_review、/fanqie_comment?mode=paragraph…）——
---     同一台服务器上换到 /para_review 才是 JSON，参数原样保留（实测无需任何登录 Cookie）；
---   本来就是 JSON 接口的（起点 /novel/comment/v2/paragraph_list）—— 原样用，改写就打不开。
function M.resolve_api_url(url)
    local host, path, query = url:match("^(https?://[^/]+)(/[^?]*%?)(.*)$")
    if not host then return url end
    local p = path:sub(1, -2) -- 去掉结尾那个 ?
    if p:find("paragraph_", 1, true) or p:find("comment/v2", 1, true) then return url end
    if p:find("review", 1, true) or p:find("comment", 1, true) then
        return host .. "/para_review?" .. query
    end
    return url
end

function M:fetch(url, count, callback, extra_headers)
    local Backend = require("Legado/Backend")
    url = M.resolve_api_url(url)
    local auth = H.is_tbl(extra_headers) and extra_headers.Authorization or nil
    Backend:launchProcess(function()
        local httpReq = require("Legado.Helper.Http")
        local headers = {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            ["Accept"] = "application/json, text/plain, */*",
        }
        -- 段评接口要的那条 Authorization 只在主进程拿得着（藏在 bookUrl 里），
        -- 由调用方算好传进来；这里只当一个普通字符串头使
        if type(auth) == "string" and auth ~= "" then headers.Authorization = auth end
        local status, res = httpReq({
            url = url,
            timeout = 30,
            headers = headers,
        }, true)
        if not status then
            -- 带着凭证还被拒，八成是 bookUrl 里那个 token 过期了，说人话
            if type(auth) == "string" and auth ~= "" and tostring(res):find("Remote server error", 1, true) then
                error("段评凭证已失效（站点返回非 2xx），换个章节重进或重新搜这本书")
            end
            error(tostring(res))
        end
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
        local why = H.is_tbl(result) and H.is_str(result.err) and result.err ~= ""
            and ("（站点说：" .. result.err .. "）") or ""
        MessageBox:info(string.format("本条段评共 %d 条评论，暂无可见数据%s", total, why))
        return
    end

    local parts = {}
    -- 起点这类接口一次只给一页（20 条），总数在 total 里；不说清会被当成「就这么几条」
    if total > #comments then
        parts[#parts + 1] = string.format("共 %d 条，先显示前 %d 条", total, #comments)
    end
    local skipped = H.is_tbl(result) and tonumber(result.skipped) or 0
    if skipped > 0 then
        parts[#parts + 1] = string.format("另有 %d 条图片评论已屏蔽（墨水屏不显示图片）", skipped)
    end
    if H.is_str(result.paragraph) and result.paragraph ~= "" then
        parts[#parts + 1] = "原文：" .. result.paragraph
    end
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

--- 只给 bookUrl 里没写的东西：起点类书源留下的三个号 -> 评论接口 + 那条码在 bookUrl 里的凭证
-- @return url, authorization_header_value ；取不到就返回 nil, 说明
function M.qid_request(qid, book_url)
    if not H.is_tbl(qid) then return nil, "bad_qid" end
    if not (qid.bid and qid.cid and qid.pid) then return nil, "bad_qid" end
    if not H.is_str(book_url) or book_url == "" then return nil, "no_book_url" end
    local host = book_url:match("^(https?://[^/,%s]+)")
    if not host then return nil, "bad_host" end
    local auth = book_url:match(AUTH_VAL_P)
    if not auth then return nil, "no_token" end
    -- 起点这类书源的 bookUrl 里写的就是 "Bearer xxx"，整条值已经带前缀了。
    -- 别在这再补一次：站点把 "Bearer Bearer xxx" 当非法凭证，回 401 Unauthorized。
    -- （早先那条模式把 Bearer 的第二个 r 漏写了，前缀永远判不出来，就是这么炸的）
    if not auth:lower():match("^%s*bearer%s") then auth = "Bearer " .. auth end
    local url = string.format("%s%s?bid=%s&cid=%s&pid=%s&page=1&size=20",
        host, QID_API, tostring(qid.bid), tostring(qid.cid), tostring(qid.pid))
    return url, auth
end

local QID_FAIL = {
    no_book_url = "本地没有该书源的 bookUrl，拼不出评论接口",
    bad_host    = "该书源的 bookUrl 里没有站点地址，拼不出评论接口",
    no_token    = "该书源没把段评凭证（token）交给设备，点不出评论",
    bad_qid     = "段评索引缺少 bid/cid/pid",
}

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

    local list, book_url = M.load_index(chapter.book_cache_id, chapter.chapters_index)
    local item = list[index]
    if not H.is_tbl(item) then
        MessageBox:info("段评索引缺失，请清缓存后重新下载本章")
        return false
    end

    local url, headers
    if H.is_str(item.url) and item.url:match("^https?://.+") then
        -- 大灰狼类：书源在正文里就把评论接口写全了
        url = item.url
    elseif H.is_tbl(item.qid) then
        -- 起点类：索引里只有号；凭证优先用本章下载时存下的 bookUrl，再退回内存里那份
        local sources = {}
        if H.is_str(book_url) then sources[#sources + 1] = book_url end
        local alt = require("Legado/PlgState"):readingChapter()
        if H.is_tbl(alt) and H.is_str(alt.bookUrl) then sources[#sources + 1] = alt.bookUrl end
        local reason
        for _, src in ipairs(sources) do
            url, reason = M.qid_request(item.qid, src)
            if url then break end
        end
        if not url then
            -- 成功时第二个返回值是凭证，失败时是失败原因
            MessageBox:info(string.format("第 %d 段：%s", index,
                QID_FAIL[reason] or "该书源未提供段评接口"))
            return false
        end
        headers = { Authorization = reason }
    end
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
    end, headers)
    return true
end

return M
