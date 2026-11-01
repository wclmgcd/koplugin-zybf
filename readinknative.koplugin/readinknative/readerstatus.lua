-- Small read-only device indicators in the existing header margin.
local R={}
function R.width(app)
    -- Reserve the widest percentage even while its value is unknown, so the
    -- chapter title and download badge never move as the battery changes.
    return not app.toolbar and require('readinknative/preferences').normalize(app.state.preferences).showDeviceStatus and app.view.layout.s(96)or 0
end
function R.paint(v,bb)
    local width=R.width(v.app);if width==0 then return 0 end
    local l=v.layout;local s=l.s;local BB=require('ffi/blitbuffer');local x=l.w-l.side-width;local y=s(7)
    local N=require('ui/network/manager');local D=require('device')
    local connected=N:isWifiOn()and N:isConnected()
    local image=require('ui/widget/imagewidget'):new{file=v.app.path..'/resources/quick/wifi.svg',width=s(18),height=s(18),scale_factor=0,alpha=true,is_icon=true}
    v.objects[#v.objects+1]=image;image:paintTo(bb,x,y)
    if not connected then
        for i=3,14 do bb:paintRect(x+s(i),y+s(i),s(3),s(3),BB.COLOR_WHITE)end
        for i=3,14 do bb:paintRect(x+s(i),y+s(i),s(1),s(1),BB.COLOR_BLACK)end
    end
    local ok,power=pcall(D.getPowerDevice,D);local valid,capacity=false,nil
    if ok and power then valid,capacity=pcall(power.getCapacity,power)end
    if not valid or type(capacity)~='number'or capacity~=capacity or capacity==math.huge or capacity==-math.huge then capacity=nil
    else capacity=math.floor(math.max(0,math.min(100,capacity))+0.5)end
    local bw=s(22);local bh=s(12);local bx=x+width-bw-s(2);local by=y+s(3)
    bb:paintBorder(bx,by,bw,bh,s(1),BB.COLOR_BLACK)
    bb:paintRect(bx+bw,by+s(4),s(2),s(4),BB.COLOR_BLACK)
    if capacity then
        local fill=math.floor((bw-2*s(2))*capacity/100)
        if fill>0 then bb:paintRect(bx+s(2),by+s(2),fill,bh-2*s(2),BB.COLOR_BLACK)end
    else v:text(bb,'?',bx+s(5),by-s(2),s(12),s(9))end
    if ok and power and power.isCharging then
        local charging,on=pcall(power.isCharging,power)
        if charging and on then
            bb:paintRect(bx+s(8),by+s(3),s(6),s(6),BB.COLOR_WHITE)
            bb:paintRect(bx+s(10),by+s(3),s(2),s(6),BB.COLOR_BLACK)
            bb:paintRect(bx+s(8),by+s(5),s(6),s(2),BB.COLOR_BLACK)
        end
    end
    local textWidth=width-s(58)
    v:text(bb,capacity~=nil and tostring(capacity)..'%'or'--%',bx-s(6)-textWidth,y,textWidth,s(12),false,1,nil,nil,nil,'right')
    return width
end
return R
