local UI=require('ui/uimanager');local Geom=require('ui/geometry');local BB=require('ffi/blitbuffer')
local QR=require('ui/widget/container/inputcontainer'):extend{covers_fullscreen=true,modal=true}
function QR:build()
    if self.image then self.image:free()end
    if self.text then self.text:free()end
    if self.cancelText then self.cancelText:free()end
    local screen=require('device').screen;local s=function(n)return screen:scaleBySize(n)end
    self.dimen=Geom:new{x=0,y=0,w=screen:getWidth(),h=screen:getHeight()}
    local side=s(24);local width=self.dimen.w-2*side
    self.text=require('ui/widget/textboxwidget'):new{text='请用微信扫一扫\n并在手机上确认登录',
        face=require('ui/font'):getFace('cfont',18),width=width,alignment='center'}
    self.cancelRect=Geom:new{x=side,y=self.dimen.h-side-s(48),w=width,h=s(48)}
    self.cancelText=require('ui/widget/textwidget'):new{text='取消登录，返回 ReadInk',face=require('ui/font'):getFace('cfont',18),max_width=width-s(16)}
    local textHeight=self.text:getSize().h
    local available=self.cancelRect.y-3*side-textHeight
    local edge=math.max(1,math.floor(math.min(width,available,math.min(self.dimen.w,self.dimen.h)*0.68)))
    self.image=require('ui/widget/imagewidget'):new{file=self.path,width=edge,height=edge,scale_factor=0,file_do_cache=false}
    local groupHeight=edge+side+textHeight
    local top=side+math.max(0,math.floor((self.cancelRect.y-side-groupHeight)/2))
    self.imageRect=Geom:new{x=math.floor((self.dimen.w-edge)/2),y=top,w=edge,h=edge}
    self.textRect=Geom:new{x=side,y=top+edge+side,w=width,h=textHeight}
    self.ges_events={Tap={require('ui/gesturerange'):new{ges='tap',range=self.dimen}}}
end
function QR:init()
    self:build();self.key_events={Cancel={{'Back'}}}
end
function QR:paintTo(bb,x,y)
    bb:paintRect(0,0,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
    self.image:paintTo(bb,self.imageRect.x,self.imageRect.y)
    self.text:paintTo(bb,self.textRect.x,self.textRect.y)
    local r=self.cancelRect;bb:paintBorder(r.x,r.y,r.w,r.h,math.max(1,require('device').screen:scaleBySize(1)),BB.COLOR_BLACK)
    local size=self.cancelText:getSize();self.cancelText:paintTo(bb,math.floor(r.x+(r.w-size.w)/2),math.floor(r.y+(r.h-size.h)/2))
end
function QR:onShow()UI:setDirty(self,'full',self.dimen)end
function QR:onSetDimensions()self:build();UI:setDirty(self,'full',self.dimen);return true end
function QR:onTap(_,gesture)
    local p=gesture and gesture.pos
    if p and require('readinknative/layout').contains(self.cancelRect,p.x,p.y)then self:onCancel()end
    return true
end
function QR:onCancel()self.cancel();return true end
function QR:onSuspend()self.cancel()end
function QR:onCloseWidget()
    for _,key in ipairs({'image','text','cancelText'})do if self[key]then self[key]:free();self[key]=nil end end
    UI:setDirty(nil,'full',self.dimen)
end
return QR
