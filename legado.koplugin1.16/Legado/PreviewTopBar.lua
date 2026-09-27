--[[--
试读顶栏：阅读页最上方一条自己的地盘，左边「返回」右边「加入书架」，下面一根细线，
细线以下才是正文。

要正文下移就得动文档的上页边距：顶栏本身只是覆盖层，不占版面，直接压在正文上会把第一行
吃掉。所以这里在 crengine 的页边距上垫出一条带子（每份文档只垫一次，换章是新文档要重垫），
再把自己的窗口摆在空出来的那条里。

整块窗口只有这两个方框认领点击。注意 KOReader 的 `UIManager:sendEvent` **不会**把未认领的事件
继续往窗口栈下面传（只轮到 top 的 active_widgets 和标了 is_always_active 的窗口），所以这里挂一个
指向当前阅读器的转发器：两个角之外的手势、按键才会回到阅读器，翻页、段评气泡、状态栏不受影响。
]]

local Blitbuffer = require("ffi/blitbuffer")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Screen = require("device").screen
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")

local M = {}

local bar
local strip_h
local last_spec
-- 已经让出过空白的文档。换章是新文档，要重新让一次，所以只能按文档对象判重，
-- 不能用「顶栏在不在」判（顶栏窗口是可以跨文档活下来的）。
-- 弱键：文档被回收时这条记录跟着走，不用管地址复用，也不会攒垃圾。
local strip_docs = setmetatable({}, { __mode = "k" })
-- 带子的几何（屏幕像素）：转发器要靠它认出「这一下是落在带子里的」。
local band = { h = 0, back_w = 0, action_x = 0 }

local function reader_ui()
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    return type(ui) == "table" and ui or nil
end

-- 递给事件的是转发器，不是阅读器对象本身。这条窗口是跨文档、甚至跨阅读器实例活着的
-- （退出试读时真正的关闭排在 nextTick 里），把 ui 直接塞进 active_widgets，那个已经没有
-- document 的死阅读器就还在窗口栈里收事件 —— crash.log 里 readertoc:getTitle 索引
-- nil document 崩溃就是这么来的。
--
-- 它还兼一件更要紧的事：带子里起手的点击/滑动不许递给阅读器。设置面板（ConfigDialog）自己是
-- 顶层窗口，它一开，顶栏就成了「栈里靠下的普通窗口」，而 sendEvent 在栈里轮到我们之前**先问
-- 我们的 active_widgets** —— 也就是这个转发器；我们自己的点击区这时根本没机会说话。于是面板开着
-- 的时候在带子里再滑一下，阅读器又收到一次顶边手势，面板就一层层叠出去
-- （crash.log 21:22:22→21:22:24 连着两个 ConfigDialog）。
local event_router = {}
function event_router:handleEvent(event)
    if event.handler == "onGesture" then
        local ges = event.args and event.args[1]
        local pos = type(ges) == "table" and ges.pos or nil
        -- swipe 的 pos 是**起点**（其它手势是终点/抬起点），按起点判就是「这一下落在带子里」
        if type(pos) == "table" and pos.y and pos.y >= 0 and pos.y < band.h then
            local spec = last_spec
            if spec and ges.ges == "tap" and pos.x then
                if pos.x < band.back_w then
                    spec.on_back()
                    return true
                elseif pos.x >= band.action_x then
                    spec.on_action()
                    return true
                end
            end
            return true
        end
    end
    local ui = reader_ui()
    if not (ui and ui.document) then return end
    return ui:handleEvent(event)
end

local function in_stack(widget)
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for i = 1, #stack do
        if stack[i] and stack[i].widget == widget then
            return true
        end
    end
    return false
end

local function chip(text)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.button,
        margin = 0,
        radius = 0,
        padding_top = Size.padding.small,
        padding_bottom = Size.padding.small,
        padding_left = Size.padding.default,
        padding_right = Size.padding.default,
        TextWidget:new{
            text = text,
            face = Font:getFace("smalltfont"),
        },
    }
end

local function reserve_strip()
    local ui = reader_ui()
    local doc = ui and ui.document or nil
    if not (type(doc) == "table" and doc.getPageMargins and doc.setPageMargins) then return end
    if strip_docs[doc] then return end
    local ok, margins = pcall(function()
        return doc:getPageMargins()
    end)
    if not (ok and type(margins) == "table") then return end
    strip_docs[doc] = true
    pcall(function()
        doc:setPageMargins(margins["left"] or 0, (margins["top"] or 0) + strip_h,
            margins["right"] or 0, margins["bottom"] or 0)
        ui:handleEvent(Event:new("UpdatePos"))
    end)
end

--- 已经显示就只补页边距（换章），否则重建一条
function M.show(spec)
    if not (bar and in_stack(bar)) then
        M.hide()

        local screen = Screen:getSize()
        local back_chip = chip(spec.back_text)
        local action_chip = chip(spec.action_text)
        local back_w = back_chip:getSize().w
        local action_w = action_chip:getSize().w
        local line_h = Size.line.medium
        local band_h = math.max(back_chip:getSize().h, action_chip:getSize().h) + Size.padding.small
        strip_h = band_h + line_h
        band.h = strip_h
        band.back_w = back_w
        band.action_x = screen.w - action_w

        local root = VerticalGroup:new{
            align = "left",
            OverlapGroup:new{
                dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = band_h },
                allow_mirroring = false,
                LeftContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = band_h },
                    allow_mirroring = false,
                    back_chip,
                },
                RightContainer:new{
                    dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = band_h },
                    allow_mirroring = false,
                    action_chip,
                },
            },
            LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = line_h },
            },
        }

        local ui = reader_ui()
        local widget = InputContainer:new{
            name = "LegadoPreviewTopBar",
            -- 顶栏不是模态框。KOReader 的 sendEvent 只把事件给最上面那个非 toast 窗口，
            -- 它不认领时才轮到它的 active_widgets —— 转发器挂在这儿，我们没认领的
            -- 按键和手势才回得到阅读器（否则翻页、状态栏、自定义手势全被这条窗口吃掉）。
            active_widgets = ui and { event_router } or nil,
            -- show() 会按最上面这个窗口的字段关掉双击：不显式给 false，双击翻页就没了
            disable_double_tap = false,
            -- 只占自己那条带子：窗口尺寸决定首次刷新范围，别顺手全屏刷一次
            dimen = Geom:new{ x = 0, y = 0, w = screen.w, h = strip_h },
            root,
        }

        -- 点击区取整条带子的高度（比方框本身高一点），墨水屏上角点要好评
        widget:registerTouchZones({
            {
                -- 带子整条都是顶栏的：KOReader 顶部 8% 是「菜单/设置面板」点击区，而这条带子
                -- 只有 6%，落在里面。不拦下来，点在两个方框之间就会把阅读菜单或底部设置面板
                -- 掀开 —— 顶栏关掉、阅读器跟着关掉之后，那个面板还留在窗口栈里收事件。
                id = "legado_preview_bar_strip",
                ges = "tap",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = 1, ratio_h = strip_h / screen.h,
                },
                handler = function() return true end,
            },
            {
                -- 下滑同理。crash.log 20:52:39 那次就是手指落在 (562,38) 带子里、往下拖了
                -- 139px：swipe 事件的 pos 是**起点**，所以按起点拦，正文里起手、拖到带子上
                -- 结束的手势照旧归阅读器。
                id = "legado_preview_bar_swipe",
                ges = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = 1, ratio_h = strip_h / screen.h,
                },
                handler = function() return true end,
            },
            {
                id = "legado_preview_bar_back",
                overrides = { "legado_preview_bar_strip" },
                ges = "tap",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0,
                    ratio_w = back_w / screen.w, ratio_h = strip_h / screen.h,
                },
                handler = function()
                    spec.on_back()
                    return true
                end,
            },
            {
                id = "legado_preview_bar_action",
                overrides = { "legado_preview_bar_strip" },
                ges = "tap",
                screen_zone = {
                    ratio_x = (screen.w - action_w) / screen.w, ratio_y = 0,
                    ratio_w = action_w / screen.w, ratio_h = strip_h / screen.h,
                },
                handler = function()
                    spec.on_action()
                    return true
                end,
            },
        })

        -- 转屏后带子的宽度、方框和点击区都得按新屏幕重算；不认领这个事件，
        -- 阅读器那份处理照旧跑，我们只是排一次重建。
        function widget:onScreenResize()
            UIManager:nextTick(function()
                if bar == widget and last_spec then
                    M.refresh(last_spec)
                end
            end)
        end

        bar = widget
        last_spec = spec
        UIManager:show(bar, "ui", Geom:new{ x = 0, y = 0, w = screen.w, h = strip_h })
    end
    reserve_strip()
    return true
end

--- 换过文案（比如书已经加进书架）时强制重建
function M.refresh(spec)
    if bar and in_stack(bar) then
        M.hide()
    end
    return M.show(spec)
end

function M.hide()
    local widget = bar
    bar = nil
    if not widget then return end
    -- 已经不在栈上了就别再 close 一次：CloseWidget 跑两遍是野指针。
    -- （退出阅读器时 ReaderUI.onClose 那层也会收一次顶栏，和 BookPreview.exit
    -- 自己的 hide 撞在一起是常态。）
    if not in_stack(widget) then return end
    -- 只 close，不要 free()：这条常常是在自己的点击区回调里跑的，UIManager 还在遍历
    -- 这条窗口的点击区/脏区，提前把子控件的缓冲释放掉就是野指针（Lua 层报错只会弹
    -- traceback，这种是直接整个 KOReader 崩回系统界面）。引用断了交给 GC 就行。
    UIManager:close(widget)
end

function M.visible()
    return bar ~= nil and in_stack(bar)
end

return M
