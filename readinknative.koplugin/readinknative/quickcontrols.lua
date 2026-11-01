-- Device controls are deliberately independent of WeRead credentials. All
-- hardware actions use KOReader APIs; no shell commands or Android bridges.
local C={}
function C.clamp(value,lo,hi)
    value=tonumber(value);if not value or value~=value then return lo end
    return math.max(lo,math.min(hi,math.floor(value+0.5)))
end
function C.layout(w,h,scale)
    local function s(v)return math.max(1,math.floor(v*(scale or 1)+0.5))end
    local side,gap=s(18),s(10);local cw=math.floor((w-2*side-2*gap)/3)
    local cards={};for i=1,3 do cards[i]={x=side+(i-1)*(cw+gap),y=s(28),w=cw,h=s(106)}end
    local rows={}
    for i,kind in ipairs{'light','refresh'}do
        local y=s(150+(i-1)*72)
        rows[i]={kind=kind,x=side,y=y,w=w-2*side,h=s(64),low=side+s(68),high=w-side-s(54),trackY=y+s(37)}
    end
    return{w=w,h=h,s=s,cards=cards,rows=rows,sheetH=math.min(s(310),h-s(24)),side=side}
end
function C.edge(view,g,pan)
    if not g or g.direction~='south'or view.sliderDrag then return false end
    local p=pan and g.start_pos or g.pos;local a=view.app
    if not p or type(p.x)~='number'or type(p.y)~='number'or p.x~=p.x or p.y~=p.y
        or not a or a.closed or a.suspended or a.activeInput or a.textSelection then return false end
    local s=view.layout.s
    if p.x<0 or p.x>view.dimen.w or p.y<0 or p.y>s(22)then return false end
    local finish=g.end_pos or(pan and g.pos)
    local distance=finish and finish.y-p.y or g.distance or 0
    return distance>=s(40)
end
function C.openGesture(view,g,pan)
    if not C.edge(view,g,pan)then return false end
    return require('readinknative/quickmenu').open(view.app,pan)
end
function C.state()
    local D=require('device');local N=require('ui/network/manager');local UI=require('ui/uimanager')
    local light=D:hasFrontlight();local power=light and D:getPowerDevice()
    local day,night=UI:getRefreshRate();local dark=G_reader_settings:isTrue('night_mode')
    return{wifiSupported=D:hasWifiToggle(),wifiOn=N:isWifiOn()==true,connected=N:isConnected()==true,
        wifiPending=N.pending_connection==true,night=dark,lightSupported=light,
        light=power and power:frontlightIntensity()or 0,lightMin=power and power.fl_min or 0,lightMax=power and power.fl_max or 24,
        refresh=dark and night or day,canSuspend=D:canSuspend()}
end
function C.setLight(value)
    local D=require('device');if not D:hasFrontlight()then return false end
    local p=D:getPowerDevice();value=C.clamp(value,p.fl_min,p.fl_max)
    p:setIntensity(value);p:updateResumeFrontlightState();return value
end
function C.setRefresh(value)
    value=C.clamp(value,1,30);local UI=require('ui/uimanager')
    if G_reader_settings:isTrue('night_mode')then UI:setRefreshRate(nil,value)else UI:setRefreshRate(value,nil)end
    UI.refresh_count=0;G_reader_settings:flush();return value
end
function C.refreshLabel(value)
    if value==0 then return'仅按需全刷'end
    return'每 '..tostring(value)..' 页全刷'
end
function C.night(app)
    -- DeviceListener is KOReader's own night-mode action. Our independent CRe
    -- document is not ReaderUI.document, so invalidate its frame cache too.
    require('device/devicelistener').onToggleNightMode({ui=app.host})
    local d=app.document
    if d then d:clearPageImages();if d.doc and d.doc.resetCallCache then d.doc:resetCallCache()end end
    G_reader_settings:flush()
end
function C.wifi(enabled,callback)
    local D=require('device');if not D:hasWifiToggle()then return false end
    local N=require('ui/network/manager')
    if enabled then return N:toggleWifiOn(callback,false,true)end
    return N:toggleWifiOff(callback,true)
end
return C
