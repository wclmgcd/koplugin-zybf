-- A bounded snapshot keeps CRe out of slider repainting. The sheet owns all
-- contacts while open; it never forwards a dismissal tap to the reading page.
local UI=require('ui/uimanager');local Geom=require('ui/geometry');local BB=require('ffi/blitbuffer')
local C=require('readinknative/quickcontrols');local Q={}
local Sheet=require('ui/widget/container/inputcontainer'):extend{covers_fullscreen=true,stop_events_propagation=true}
function Sheet:valid()
    return not self.closed and not self.app.closed and not self.app.suspended and self.app.state==self.owner
        and self.app.client.data.vid==self.vid and self.app.quickMenu==self
end
function Sheet:init()
    self.owner=self.app.state;self.vid=self.app.client.data.vid
    self.dimen=Geom:new{x=0,y=0,w=self.app.view.dimen.w,h=self.app.view.dimen.h}
    self.layout=C.layout(self.dimen.w,self.dimen.h,self.app.view.fontScale);self.objects={};self.icons={}
    self.current=C.state()
    local Range=require('ui/gesturerange');local rate=require('device').screen.low_pan_rate and 5 or 12
    self.ges_events={Touch={{ges='touch',range=self.dimen}},Tap={{ges='tap',range=self.dimen}},
        Pan={{ges='pan',range=self.dimen,rate=rate}},Release={{ges='pan_release',range=self.dimen},{ges='hold_release',range=self.dimen}},
        HoldPan={{ges='hold_pan',range=self.dimen,rate=rate}},Hold={{ges='hold',range=self.dimen}},
        Swipe={{ges='swipe',range=self.dimen}},Cancel={{ges='two_finger_tap',range=self.dimen},{ges='two_finger_pan',range=self.dimen},{ges='pinch',range=self.dimen},{ges='spread',range=self.dimen},{ges='rotate',range=self.dimen}}}
    for _,ranges in pairs(self.ges_events)do for i,r in ipairs(ranges)do ranges[i]=Range:new(r)end end
    self.key_events={Back={{'Back'},{'Esc'}},Dismiss={{'Left'},{'Right'},{'PgFwd'},{'PgBack'},{'LPgFwd'},{'LPgBack'},{'RPgFwd'},{'RPgBack'}}}
end
function Sheet:clearText()
    for _,o in ipairs(self.objects)do o:free()end;self.objects={}
end
function Sheet:text(bb,text,x,y,w,size,color,bold,align)
    local o=require('ui/widget/textwidget'):new{text=text,face=require('ui/font'):getFace('cfont',size/self.app.view.fontScale),max_width=w,
        fgcolor=color or BB.COLOR_BLACK,bold=bold or false}
    self.objects[#self.objects+1]=o;local z=o:getSize()
    o:paintTo(bb,math.floor(align=='center'and x+(w-z.w)/2 or align=='right'and x+w-z.w or x),math.floor(y));return o
end
function Sheet:icon(bb,name,x,y,size,white)
    local key=name..':'..size..':'..tostring(white);local o=self.icons[key]
    if not o then
        o=require('ui/widget/imagewidget'):new{file=self.app.path..'/resources/quick/'..name..(white and'-on'or'')..'.svg',
            width=size,height=size,scale_factor=0,alpha=true,is_icon=true}
        o:getSize();self.icons[key]=o
    end
    o:paintTo(bb,math.floor(x),math.floor(y))
end
function Sheet:redraw(mode,region)
    if self:valid()then UI:setDirty(self,mode or'ui',region or Geom:new{x=0,y=0,w=self.dimen.w,h=self.layout.sheetH})end
end
function Sheet:paintTo(bb)
    if not self.snapshot then return end
    self:clearText();bb:blitFrom(self.snapshot,0,0,0,0,self.dimen.w,self.dimen.h)
    local l=self.layout;local s=l.s;local state=self.current
    bb:paintRoundedRect(0,-s(16),l.w,l.sheetH+s(16),BB.COLOR_WHITE,s(12))
    bb:paintBorder(0,-s(16),l.w,l.sheetH+s(16),s(1),BB.COLOR_GRAY,s(12))
    self:icon(bb,'up',(l.w-s(26))/2,0,s(26))
    local cards={{'wifi','Wi-Fi',self.wifiBusy and(self.wifiTarget and'开启中…'or'关闭中…')or not state.wifiSupported and'不可用'or state.wifiOn and(state.connected and'已连接'or'已开启')or'已关闭',state.wifiOn},
        {'moon','夜间模式',state.night and'已开启'or'已关闭',state.night},{'power','电源','点按菜单',false}}
    for i,q in ipairs(cards)do local r=l.cards[i];local ink=q[4]and BB.COLOR_WHITE or BB.COLOR_BLACK
        bb:paintRoundedRect(r.x,r.y,r.w,r.h,q[4]and BB.COLOR_DARK_GRAY or BB.COLOR_LIGHT_GRAY,s(12))
        self:icon(bb,q[1],r.x+(r.w-s(34))/2,r.y+s(12),s(34),q[4])
        self:text(bb,q[2],r.x+s(4),r.y+s(53),r.w-s(8),s(18),ink,false,'center')
        self:text(bb,q[3],r.x+s(4),r.y+s(79),r.w-s(8),s(13),ink,false,'center')
    end
    bb:paintRect(l.side,s(142),l.w-2*l.side,s(1),BB.COLOR_GRAY)
    for _,r in ipairs(l.rows)do
        local light=r.kind=='light';local supported=not light or state.lightSupported
        local value=light and state.light or state.refresh
        if self.drag and self.drag.kind==r.kind then value=self.drag.value end
        local low,high=light and state.lightMin or 1,light and state.lightMax or 30
        local ratio=math.max(0,math.min(1,(value-low)/math.max(1,high-low)))
        if self.drag and self.drag.kind==r.kind then ratio=self.drag.ratio end
        self:icon(bb,light and'sun'or'refresh',r.x,r.y+s(12),s(34))
        self:text(bb,light and'灯光亮度'or'屏幕刷新',r.low,r.y,r.high-r.low,s(16))
        self:text(bb,supported and(light and tostring(value)or C.refreshLabel(value))or'本机无前光',r.low,r.y,r.high-r.low,s(13),BB.COLOR_DARK_GRAY,false,'right')
        local yy=r.trackY;local height=s(10);local knob=r.low+(r.high-r.low)*ratio
        bb:paintRoundedRect(r.low,yy,r.high-r.low,height,BB.COLOR_LIGHT_GRAY,height/2)
        if supported then
            if knob>r.low then bb:paintRoundedRect(r.low,yy,math.max(height,knob-r.low),height,BB.COLOR_DARK_GRAY,height/2)end
            bb:paintCircle(knob,yy+height/2,s(11),BB.COLOR_WHITE);bb:paintCircle(knob,yy+height/2,s(11),BB.COLOR_BLACK,s(1))
            self:text(bb,tostring(low),r.x+s(38),yy-s(7),s(16),s(13),BB.COLOR_DARK_GRAY,false,'center')
            self:text(bb,tostring(high),r.high+s(10),yy-s(7),s(30),s(13),BB.COLOR_DARK_GRAY,false,'center')
        end
        bb:paintRect(l.side,r.y+r.h+s(2),l.w-2*l.side,s(1),BB.COLOR_GRAY)
    end
    bb:paintRoundedRect((l.w-s(40))/2,l.sheetH-s(13),s(40),s(4),BB.COLOR_DARK_GRAY,s(2))
end
function Sheet:close()
    if self.closed then return end
    self.closed=true;self.drag=nil
    if self.poll then UI:unschedule(self.poll);self.poll=nil end
    if self.powerDialog and UI:isWidgetShown(self.powerDialog)then UI:close(self.powerDialog)end
    self.powerDialog=nil
    if self.app.quickMenu==self then self.app.quickMenu=nil end
    UI:close(self)
    if not self.app.closed and not self.app.suspended then
        if self.app.state==self.owner and self.app.client.data.vid==self.vid then
            require('readinknative/readingstats').update(self.app);require('readinknative/readingstats').schedule(self.app)
        end
        UI:setDirty(self.app.view,'flashui',self.app.view.dimen)
    end
end
function Sheet:onCloseWidget()
    if not self.closed then self:close()end
    if self.snapshot then self.snapshot:free();self.snapshot=nil end
    self:clearText();for _,o in pairs(self.icons)do o:free()end;self.icons={}
end
function Sheet:onBack()self:close();return true end
Sheet.onDismiss=Sheet.onBack
function Sheet:onSuspend()self:close()end
function Sheet:onSetDimensions()self:close();return false end
function Sheet:onNetworkConnected()self.wifiBusy=nil;self.current=C.state();self:redraw();return false end
function Sheet:onNetworkDisconnected()self.wifiBusy=nil;self.current=C.state();self:redraw();return false end
function Sheet:onFrontlightStateChanged()self.current=C.state();self:redraw();return false end
function Sheet:toggleWifi()
    if not self:valid()or self.wifiBusy or not C.state().wifiSupported then return end
    self.wifiTarget=not C.state().wifiOn;self.wifiBusy=true;self:redraw();UI:forceRePaint()
    local ok,err=pcall(C.wifi,self.wifiTarget,function()if self:valid()then self.wifiBusy=nil;self.current=C.state();self:redraw()end end)
    if not ok or err==false then self.wifiBusy=nil;if not ok then self.app:failure(err)end;self:redraw();return end
    local attempts=0
    self.poll=function()
        if not self:valid()then self:close();return end
        local state=C.state();self.current=state;attempts=attempts+1
        if(not state.wifiPending and(state.wifiOn==self.wifiTarget or attempts>=3))or attempts>=90 then self.wifiBusy=nil end
        self:redraw();if self.wifiBusy then UI:scheduleIn(1,self.poll)end
    end
    if self.wifiBusy then UI:scheduleIn(1,self.poll)end
end
function Sheet:power()
    if not self:valid()then return end
    local dialog;local function action(fn)
        if not self:valid()then UI:close(dialog);return end
        UI:close(dialog);self.powerDialog=nil;self:close();fn()
    end
    dialog=require('ui/widget/buttondialog'):new{title='电源',title_align='center',modal=true,buttons={
        {{id='sleep',text='休眠',enabled=C.state().canSuspend,callback=function()action(function()UI:suspend()end)end}},
        {{id='exit',text=require('readinknative/preferences').exitButtonLabel(),callback=function()action(function()self.app:exit()end)end}},
        {{id='cancel',text='取消',callback=function()UI:close(dialog);self.powerDialog=nil end}}}}
    self.powerDialog=dialog;UI:show(dialog)
end
function Sheet:toggleNight()
    C.night(self.app)
    -- Rebuild the background once when the mode changes so CRe can preserve
    -- illustration colors. Slider paints continue to use only this snapshot.
    self.snapshot:setInverse(require('device').screen.bb:getInverse())
    self.app.view:paintTo(self.snapshot,0,0)
    self.current=C.state();self:redraw('full')
end
local function contains(r,p)return p and p.x>=r.x and p.y>=r.y and p.x<r.x+r.w and p.y<r.y+r.h end
function Sheet:onTouch(_,g)
    self.openingGesture=nil;self.sliderConsumed=nil
    if self.drag then self:onCancel();return true end
    if not self:valid()then self:close();return true end
    local state=C.state();local p=g.pos
    for _,r in ipairs(self.layout.rows)do
        if contains(r,p)and p.y>=r.trackY-self.layout.s(18)and(not(r.kind=='light')or state.lightSupported)and p.x>=r.low-self.layout.s(14)and p.x<=r.high+self.layout.s(14)then
            local low,high=r.kind=='light'and state.lightMin or 1,r.kind=='light'and state.lightMax or 30
            local original=r.kind=='light'and state.light or state.refresh
            local knob=r.low+(r.high-r.low)*math.max(0,math.min(1,(original-low)/math.max(1,high-low)))
            self.drag={kind=r.kind,row=r,lo=low,hi=high,value=original,original=original,
                ratio=math.max(0,math.min(1,(original-low)/math.max(1,high-low))),
                offset=math.abs(p.x-knob)<=self.layout.s(16)and p.x-knob or 0}
            self:onPan(nil,g);return true
        end
    end
    return true
end
function Sheet:onPan(_,g)
    if self.openingGesture then return true end
    local d=self.drag;if not d then return true end
    if not self:valid()then self:close();return true end
    local p=g.end_pos or g.pos;if not p then return true end
    local ratio=(p.x-d.offset-d.row.low)/math.max(1,d.row.high-d.row.low)
    d.ratio=math.max(0,math.min(1,ratio))
    local value=C.clamp(d.lo+ratio*(d.hi-d.lo),d.lo,d.hi)
    if value~=d.value then d.value=value;if d.kind=='light'then C.setLight(value)end end
    self:redraw('fast',Geom:new(d.row));return true
end
Sheet.onHoldPan=Sheet.onPan
function Sheet:onRelease(_,g)
    if self.openingGesture then self.openingGesture=nil;return true end
    local d=self.drag;if not d then return true end
    self:onPan(nil,g);self.drag=nil;self.sliderConsumed=true
    if not self:valid()then return true end
    if d.kind=='refresh'then C.setRefresh(d.value)else C.setLight(d.value)end
    self.current=C.state()
    self:redraw();return true
end
function Sheet:onCancel()
    if self.drag and self.drag.kind=='light'and self:valid()then C.setLight(self.drag.original)end
    self.drag=nil;self.sliderConsumed=true;self:redraw();return true
end
function Sheet:onHold()return true end
function Sheet:onTap(_,g)
    if self.drag then return self:onRelease(nil,g)end
    if self.sliderConsumed then self.sliderConsumed=nil;return true end
    if not self:valid()then self:close();return true end
    local p=g.pos;local l=self.layout
    if p.y>l.sheetH or p.y<l.s(28)or p.y>l.sheetH-l.s(22)then self:close();return true end
    for i,r in ipairs(l.cards)do if contains(r,p)then
        if i==1 then self:toggleWifi()elseif i==2 then self:toggleNight()else self:power()end
        return true
    end end
    return true
end
function Sheet:onSwipe(_,g)
    if self.openingGesture then self.openingGesture=nil;return true end
    if self.drag then return self:onRelease(nil,g)end
    if g.direction=='north'then self:close()end;return true
end
function Q.open(app,openingGesture)
    if app.closed or app.suspended or app.activeInput or app.textSelection then return false end
    if app.quickMenu then return true end
    require('readinknative/readersliders').cancel(app.view);require('readinknative/pagepreload').stop(app)
    -- Drain an already pending parent repaint before capturing it. A rapid
    -- reopen must not capture the previous sheet or an old night-mode frame.
    UI:forceRePaint()
    require('readinknative/pagepreload').stop(app)
    local snapshot=require('device').screen.bb:copy()
    local ok,sheet=pcall(Sheet.new,Sheet,{app=app,snapshot=snapshot,openingGesture=openingGesture})
    if not ok then snapshot:free();app:failure(sheet);return true end
    app.quickMenu=sheet
    require('readinknative/readingstats').update(app);require('readinknative/readingstats').schedule(app)
    UI:show(sheet,'ui');return true
end
function Q.close(app)if app.quickMenu then app.quickMenu:close()end end
return Q
