-- Pixel scrolling is owned by one touch and one document. A bottom-edge
-- contact waits for release so the formatting gesture cannot move the book.
local R={}
local function finite(n)return type(n)=='number'and n==n and n~=math.huge and n~=-math.huge end
local function owned(v,c)
    local a=v.app
    return a and c and a.document==c.document and a.state==c.state and a.book==c.book and c.document.format==c.format
end
function R.ready(v)
    local a=v.app;local d=a and a.document
    if not a or a.closed or a.suspended or a.mode~='reader'or not d or not d.doc
        or not d.isScroll or not d:isScroll()or not a.scrollBy or a.chapterLoading
        or a.toolbar or a.panel or a.textSelection or a.activeInput or a.readerOverlay
        or a.footnote or a.quickMenu or a.nativeFormatPanel or v.sliderDrag then return false end
    local UI=require('ui/uimanager')
    if UI.getTopmostVisibleWidget then local top=UI:getTopmostVisibleWidget();if top and top~=v then return false end end
    return true
end
local function clear(v)
    v.scrollContact=nil
    if v.scrollDrag then v.scrollDrag=nil;require('ui/uimanager').currently_scrolling=false end
end
function R.cancel(v,save)
    local c=v.scrollContact;local active=c and(c.moved or c.attempted)
    clear(v)
    if save and c and c.moved and owned(v,c)and v.app.finishScroll then
        v.scrollFinishRefresh=true;v.app:finishScroll()
    end
    return active or false
end
function R.abortNative(v)
    local c=v.scrollContact
    clear(v)
    if c and c.moved and not c.crossed and owned(v,c)then
        -- Like ReaderRolling:onHandledAsSwipe, a late native gesture cancels
        -- speculative motion. The saved reading position was never committed.
        local moved=c.document:scrollTo(c.initial)
        if moved then v.scrollFinishRefresh=true;v:refresh()end
    end
    return c~=nil
end
function R.begin(v,g)
    R.cancel(v,true)
    if not R.ready(v)then return false end
    local p=g and(g.start_pos or g.pos);local body=v.layout.body
    if not p or not finite(p.x)or not finite(p.y)or not require('readinknative/layout').contains(body,p.x,p.y)then return false end
    local a=v.app;local d=a.document;local edge=math.max(v.layout.s(22),math.floor(v.dimen.h*0.15))
    v.scrollContact={document=d,state=a.state,book=a.book,format=d.format,start={x=p.x,y=p.y},
        initial=d:scrollPos(),maximum=d:scrollMax(),previousY=0,reserved=p.y>=v.dimen.h-edge,
        deferBoundary=v.nativeGesturesActive==true}
    return false -- Raw touch does not consume the later tap or hold.
end
local function relative(c,g)
    if not g then return end
    if g.relative and finite(g.relative.y)then return g.relative.y end
    if g.end_pos and finite(g.end_pos.y)then return g.end_pos.y-c.start.y end
    if finite(g.distance)and(g.direction=='north'or g.direction=='south')then return(g.direction=='north'and -1 or 1)*g.distance end
end
local function move(v,c,y)
    local pixels=c.previousY-y;c.previousY=y
    if pixels==0 then return true end
    c.attempted=true
    local boundary=not c.moved and((pixels<0 and c.initial<=0)or(pixels>0 and c.initial>=c.maximum))
    c.pendingBoundary=boundary and pixels or nil
    v.scrollDrag=c;require('ui/uimanager').currently_scrolling=true
    local moved=v.app:scrollBy(pixels,{continuous=true,allowBoundary=boundary and not c.deferBoundary})
    c.moved=c.moved or moved==true
    if not owned(v,c)or v.app.chapterLoading then c.crossed=true end
    return true
end
function R.move(v,g)
    if not g or(g.direction~='north'and g.direction~='south')then return false end
    if not v.scrollContact then R.begin(v,{pos=g.start_pos or g.pos})end
    local c=v.scrollContact
    if not c then return false end
    if c.crossed then return true end
    if not owned(v,c)or not R.ready(v)then return R.cancel(v,true)end
    local y=relative(c,g);if not finite(y)then return false end
    c.lastY=y
    if c.reserved then return true end
    return move(v,c,y)
end
function R.finish(v,g)
    local c=v.scrollContact;if not c then return false end
    local y=relative(c,g)or c.lastY or c.previousY
    if not owned(v,c)or c.crossed or not R.ready(v)then
        local consumed=c.attempted or c.crossed;clear(v)
        if consumed then v.scrollGestureConsumed=true end
        return consumed or false
    end
    local vertical=g and(g.direction=='north'or g.direction=='south')or c.lastY~=nil
    if not vertical or not finite(y)then clear(v);return false end
    if c.reserved and y<0 then
        local gesture={direction='north',start_pos=c.start,pos=c.start,distance=-y,
            end_pos={x=c.start.x,y=c.start.y+y}}
        if v:formatPanelSwipe(gesture)then clear(v);return true end
    end
    if c.moved or math.abs(y)>=v.layout.s(8)then move(v,c,y)end
    if c.deferBoundary and c.pendingBoundary and not c.moved and not c.crossed then
        -- A second finger or a multiswipe may still claim a drag while it is
        -- down. Crossing chapters is irreversible here, so wait for release.
        v.app:scrollBy(c.pendingBoundary,{continuous=true,allowBoundary=true})
        if not owned(v,c)or v.app.chapterLoading then c.crossed=true end
    end
    local consumed=c.attempted or c.moved
    clear(v)
    if consumed then
        v.scrollGestureConsumed=true;v.scrollFinishRefresh=true
        if owned(v,c)and not c.crossed and v.app.finishScroll then v.app:finishScroll()end
    end
    return consumed or false
end
function R.swipe(v,g)
    if not g or(g.direction~='north'and g.direction~='south')then
        if v.scrollContact and v.scrollContact.moved then return R.finish(v,g)end
        R.cancel(v,false);return false
    end
    if not v.scrollContact then R.begin(v,{pos=g.start_pos or g.pos})end
    return R.finish(v,g)
end
return R
