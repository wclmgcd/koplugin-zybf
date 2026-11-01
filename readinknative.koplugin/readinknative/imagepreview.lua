-- Official ImagePreviewView gestures, adapted to an e-ink viewport. Resample
-- only the visible crop, never a five-times full-screen allocation.
local UI=require('ui/uimanager');local BB=require('ffi/blitbuffer');local Geom=require('ui/geometry')
local I=require('ui/widget/container/inputcontainer'):extend{covers_fullscreen=true,disable_double_tap=false}
function I:init()
    local screen=require('device').screen;self.dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()}
    assert(self.image and self.image.w>0 and self.image.h>0 and tonumber(self.image.stride)*tonumber(self.image.h)<=16*1024*1024,'IMAGE_PREVIEW_SIZE_LIMIT')
    self.zoom=1;self.dx=0;self.dy=0;self.owner={state=self.app.state,book=self.app.book,document=self.app.document}
    local G=require('ui/gesturerange');self.ges_events={}
    for name,ges in pairs{Tap='tap',DoubleTap='double_tap',Pan='pan',PanRelease='pan_release',Swipe='swipe',Spread='spread',Pinch='pinch'}do
        self.ges_events[name]={G:new{ges=ges,range=self.dimen}}
    end
    self.key_events={Close={{'Back'}},ZoomIn={{'PgFwd'},{'RPgFwd'},{'LPgFwd'}},ZoomOut={{'PgBack'},{'RPgBack'},{'LPgBack'}}}
end
function I:valid()
    local a,o=self.app,self.owner
    return not self.closed and not a.closed and not a.suspended and a.state==o.state and a.book==o.book and a.document==o.document
end
function I:clearFrame()
    if self.frameWidget then self.frameWidget:free();self.frameWidget=nil end
    if self.frame then self.frame:free();self.frame=nil end
end
function I:geometry()
    local w,h=self.dimen.w,self.dimen.h
    local factor=math.min(w/self.image.w,h/self.image.h)*self.zoom
    local sw,sh=self.image.w*factor,self.image.h*factor
    self.dx=math.max(-math.max(0,(sw-w)/2),math.min(math.max(0,(sw-w)/2),self.dx))
    self.dy=math.max(-math.max(0,(sh-h)/2),math.min(math.max(0,(sh-h)/2),self.dy))
    return factor,(w-sw)/2+self.dx,(h-sh)/2+self.dy,sw,sh
end
function I:renderFrame()
    self:clearFrame()
    local factor,left,top,sw,sh=self:geometry();local w,h=self.dimen.w,self.dimen.h
    local x,y=math.max(0,math.floor(left)),math.max(0,math.floor(top))
    local dw,dh=math.max(1,math.min(w-x,math.ceil(left+sw)-x)),math.max(1,math.min(h-y,math.ceil(top+sh)-y))
    local sx,sy=math.max(0,math.floor((x-left)/factor)),math.max(0,math.floor((y-top)/factor))
    local cw,ch=math.min(self.image.w-sx,math.max(1,math.ceil(dw/factor))),math.min(self.image.h-sy,math.max(1,math.ceil(dh/factor)))
    local crop=BB.new(cw,ch,self.image:getType());crop:blitFrom(self.image,0,0,sx,sy,cw,ch)
    local ok,scaled=pcall(require('ui/renderimage').scaleBlitBuffer,require('ui/renderimage'),crop,dw,dh,false)
    if not ok then crop:free();error('IMAGE_PREVIEW_RENDER_FAILED')end
    if scaled~=crop then crop:free()end
    self.frame=scaled;self.frameX=x;self.frameY=y
    self.frameWidget=require('ui/widget/imagewidget'):new{image=scaled,image_disposable=false,scale_factor=1,alpha=true}
end
function I:paintTo(bb)
    if not self:valid()then self:onClose();return end
    bb:paintRect(0,0,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
    if not self.frame then self:renderFrame()end
    self.frameWidget:paintTo(bb,self.frameX,self.frameY)
    self.dithered=true
end
function I:onShow()UI:setDirty(self,'full',nil,true);return true end
function I:redraw()self:clearFrame();UI:setDirty(self,'ui',nil,true)end
function I:setZoom(value,point)
    if not self:valid()then self:onClose();return true end
    local nextZoom=math.max(1,math.min(5,value));local ratio=nextZoom/self.zoom
    local x=(point and point.x or self.dimen.w/2)-self.dimen.w/2
    local y=(point and point.y or self.dimen.h/2)-self.dimen.h/2
    self.dx=x-(x-self.dx)*ratio;self.dy=y-(y-self.dy)*ratio;self.zoom=nextZoom
    if nextZoom==1 then self.dx=0;self.dy=0 end
    self:geometry();self:redraw();return true
end
function I:onDoubleTap(_,ges)return self:setZoom(self.zoom<=1 and 2 or 1,ges and ges.pos)end
function I:onZoomIn()return self:setZoom(self.zoom*1.5)end
function I:onZoomOut()return self:setZoom(self.zoom/1.5)end
function I:onSpread(_,ges)return self:setZoom(self.zoom*(1+(ges.distance or 0)/math.min(self.dimen.w,self.dimen.h)),ges.pos)end
function I:onPinch(_,ges)return self:setZoom(self.zoom/(1+(ges.distance or 0)/math.min(self.dimen.w,self.dimen.h)),ges.pos)end
function I:onPan(_,ges)self.pan=ges.relative;return true end
function I:onPanRelease()
    if self.pan and self.zoom>1 then self.dx=self.dx+self.pan.x;self.dy=self.dy+self.pan.y;self:geometry();self:redraw()end
    self.pan=nil;return true
end
function I:onSwipe(_,ges)
    if self.zoom>1 then
        local delta={east={1,0},west={-1,0},north={0,-1},south={0,1}};local d=delta[ges.direction]
        if d then self.dx=self.dx+d[1]*ges.distance;self.dy=self.dy+d[2]*ges.distance;self:geometry();self:redraw()end
    end
    return true
end
function I:onSetDimensions()
    local screen=require('device').screen;self.dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()}
    for _,events in pairs(self.ges_events)do events[1].range=self.dimen end
    self:geometry();self:redraw();return true
end
function I:onTap()return self:onClose()end
function I:onClose()
    if self.closed then return true end
    self.closed=true;UI:close(self);return true
end
function I:onSuspend()self.app:suspend();return true end
function I:onCloseWidget()
    self.closed=true;self:clearFrame()
    if self.image then self.image:free();self.image=nil end
    if self.app.readerOverlay==self then self.app.readerOverlay=nil end
    if not self.silent and not self.app.closed and not self.app.suspended then self.app:draw();UI:setDirty(self.app.view,'full',nil,true)end
end
return I
