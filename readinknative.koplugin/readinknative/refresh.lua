-- Follow KOReader's CRe refresh policy while leaving an unchanged header alone.
local R={}
local function integer(value)
    return type(value)=='number'and value==value and value~=math.huge and value~=-math.huge and value==math.floor(value)
end
function R.capture(view,bb)
    local buffer
    local ok,result=pcall(function()
        local dimen=view.dimen;local body=view.layout and view.layout.body
        local w,h,top=dimen and dimen.w,dimen and dimen.h,body and body.y
        assert(integer(w)and integer(h)and integer(top)and w>0 and top>0 and top<h)
        assert((dimen.x or 0)==0 and(dimen.y or 0)==0)
        -- A viewport's raw stride may still address the whole screen. Copy
        -- logical pixels into a tightly owned buffer before serializing it.
        assert(bb:getWidth()==w and bb:getHeight()==h)
        local kind,rotation,inverse=bb:getType(),bb:getRotation(),bb:getInverse()
        local BB=require('ffi/blitbuffer');local screen=require('device').screen
        buffer=BB.new(w,top,kind)
        buffer:fill(BB.COLOR_WHITE)
        buffer:blitFrom(bb,0,0,0,0,w,top)
        local pixels=BB.tostring(buffer)
        assert(type(pixels)=='string'and #pixels>0)
        return{w=w,h=h,top=top,pixels=pixels,
            stamp=table.concat({w,h,top,tostring(kind),tostring(rotation),tostring(inverse),
                tostring(screen.night_mode),tostring(screen.sw_dithering)},':')}
    end)
    -- blit/tostring errors must not leak the temporary allocation.
    if buffer then pcall(buffer.free,buffer)end
    if ok then return result end
end
function R.painted(view,mode,key,coverage,imagesRefresh,overlay,bb)
    coverage=coverage or 0
    local previous=view.lastPaint or{}
    -- An intervening paint without take() might have been submitted by some
    -- other widget's full refresh, or might never have reached the header at
    -- all. Neither possibility lets us reuse the older comparison baseline.
    local unsubmitted=view.pendingPaint and view.pendingPaint~=view.lastPaint and view.pendingPaint
    if unsubmitted then previous.header=nil end
    -- The external refresh may also have displayed an image. Carry this hint
    -- through any number of unsubmitted paints, until our own update cleans it.
    local imageCleanup=unsubmitted and((unsubmitted.coverage or 0)>=0.075 or unsubmitted.imageCleanup)or nil
    local changed=previous.mode~=mode or previous.key~=key
    local refresh='ui'
    if mode=='reader' and(changed or imageCleanup)then
        refresh='partial'
        if imagesRefresh~=false and(imageCleanup or coverage>=0.075 or math.abs(coverage-(previous.coverage or 0))>=0.075)then refresh='full'end
    elseif mode=='reader' and previous.overlay and not overlay then
        refresh='flashui'
    elseif mode~='reader'and((previous.mode=='reader'and(previous.coverage or 0)>=0.075)or imageCleanup)then
        refresh='flashui'
    end
    view.dithered=mode=='reader' and coverage>=0.075 or nil
    -- paintTo may be called by somebody else's regional refresh. Until take()
    -- submits our update, this header is not known to be on the display.
    view.pendingPaint={mode=mode,key=key,coverage=mode=='reader'and coverage or 0,overlay=overlay,imageCleanup=imageCleanup,
        header=mode=='reader'and R.capture(view,bb)or nil}
    view.paintRefresh=refresh
end
local function uncovered(view,UI)
    if type(UI.getTopmostVisibleWidget)=='function'then
        local ok,top=pcall(UI.getTopmostVisibleWidget,UI)
        if not ok or top~=view then return false end
    end
    return true
end
local function sameHeader(previous,current)
    if not previous or not current or previous.mode~='reader'or current.mode~='reader'
        or previous.overlay or current.overlay then return false end
    local a,b=previous.header,current.header
    return a and b and a.stamp==b.stamp and a.pixels==b.pixels
end
local function regionalPartial(UI)
    -- Preserve the host's once-per-repaint counter, including its live night
    -- rate. Unknown host contracts retain the original full-screen path.
    local rate,count=UI.FULL_REFRESH_COUNT,UI.refresh_count
    if type(UI._refresh)~='function'or not integer(rate)or rate<0 or not integer(count)or count<0
        or(UI.refresh_counted~=nil and type(UI.refresh_counted)~='boolean')then return false end
    if UI.currently_scrolling then return true end -- the host will choose fast
    if not(G_reader_settings and type(G_reader_settings.isTrue)=='function')then return false end
    local ok,avoid=pcall(G_reader_settings.isTrue,G_reader_settings,'avoid_flashing_ui')
    if not ok then return false end
    if rate>0 and not UI.refresh_counted then
        local nextCount=(count+1)%rate
        -- No region lets the original UIManager promote this very request to
        -- full, rather than merely flashing the smaller rectangle.
        if nextCount==rate-1 then return false end
        if avoid then
            -- UIManager downgrades a regional partial to ui *before* counting.
            -- Account for exactly the update it would otherwise miss; do not
            -- alter its setting, promotion logic or any other repaint's count.
            UI.refresh_count=nextCount;UI.refresh_counted=true
        end
    end
    return true
end
function R.take(view,requestedMode)
    local refresh=requestedMode or view.paintRefresh or'ui';view.paintRefresh=nil
    local UI=require('ui/uimanager');local pending=view.pendingPaint
    local visible=uncovered(view,UI)
    local region
    if visible and sameHeader(view.lastPaint,pending)and(refresh=='partial'or refresh=='ui'or refresh=='fast')then
        if refresh~='partial'or regionalPartial(UI)then
            local header=pending.header
            region=require('ui/geometry'):new{x=0,y=header.top,w=header.w,h=header.h-header.top}
        end
    end
    require('readinknative/pageeffects').consume(view,refresh)
    -- Keep pending for duplicate callbacks following the same paint: consuming
    -- it would make the second callback request an unnecessary whole screen.
    -- When another widget is above us, its pixels may cover our captured band.
    if visible then view.lastPaint=pending else view.lastPaint=nil end
    return refresh,region,view.dithered
end
return R
