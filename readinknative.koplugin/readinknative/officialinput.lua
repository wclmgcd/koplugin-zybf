-- Native InputText/keyboard with the observed official search page and reader
-- editor geometry. Rebuilt by input.lua on keyboard changes and wake.
local Input=require('ui/widget/inputdialog');local Container=require('ui/widget/container/inputcontainer')
local Geom=require('ui/geometry');local BB=require('ffi/blitbuffer');local UI=require('ui/uimanager')
local P=Container:extend{}
local function text(bb,value,x,y,width,size,bold,color,center)
    local w=require('ui/widget/textwidget'):new{text=value or'',face=require('ui/font'):getFace('cfont',size),bold=bold,max_width=math.max(1,width),fgcolor=color or BB.COLOR_BLACK}
    local z=w:getSize();w:paintTo(bb,math.floor(x+(center and(width-z.w)/2 or 0)),math.floor(y));w:free();return z
end
function P:init()
    self.dimen=Geom:new{w=self.w,h=self.h};self.hits={}
    self.ges_events={Tap={require('ui/gesturerange'):new{ges='tap',range=self.dimen}}}
end
function P:hit(x,y,w,h,action)self.hits[#self.hits+1]={x=x,y=y,w=w,h=h,action=action}end
function P:onTap(_,ges)
    if not ges or not ges.pos then return end
    local x,y=ges.pos.x-self.dimen.x,ges.pos.y-self.dimen.y
    for _,r in ipairs(self.hits)do if x>=r.x and x<r.x+r.w and y>=r.y and y<r.y+r.h then r.action();return true end end
end
function P:icon(bb,name,x,y,w,h)
    self.icons=self.icons or{};local key=name..':'..w..':'..h
    local i=self.icons[key]
    if not i then i=require('ui/widget/imagewidget'):new{file=self.dialog.app.path..'/resources/official/'..name..'.svg',width=w,height=h,scale_factor=0,alpha=true};self.icons[key]=i end
    i:paintTo(bb,math.floor(x),math.floor(y))
end
function P:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y;self.hits={}
    local d,s=self.dialog,self.s;local o=d.official
    bb:paintRect(x,y,self.w,self.h,BB.COLOR_WHITE)
    local function label(value,l,t,w,size,bold,color,center)return text(bb,value,x+l,y+t,w,size,bold,color,center)end
    if o.kind=='search'then
        local side=s(20);local top=s(6);local height=s(48);local width=self.w-2*side
        bb:paintBorder(x+side,y+top,width,height,s(1),BB.COLOR_BLACK,s(24))
        self:icon(bb,'abc_ic_search_api_material',x+side+s(12),y+top+s(14),s(20),s(20))
        self[1]:paintTo(bb,x+side+s(42),y+top+math.floor((height-self[1]:getSize().h)/2))
        if d:getInputText()~=''then label('×',self.w-side-s(33),top+s(9),s(28),23,false,nil,true)end
        self:hit(self.w-side-s(36),top,s(36),height,function()d:setInputText('');UI:setDirty(d,'ui')end)
        local cy=s(76);local hint=o.hint
        if type(hint)=='string'and hint~=''then
            local z=label(hint,side+s(12),cy+s(8),width-s(24),16,true)
            bb:paintBorder(x+side,y+cy,math.min(width,z.w+s(24)),s(38),s(1),BB.COLOR_BLACK,s(19))
            self:hit(side,cy,math.min(width,z.w+s(24)),s(38),function()o.submit(hint)end);cy=cy+s(64)
        end
        label('搜索历史',side,cy,width-s(70),17,true)
        label('清空',self.w-side-s(54),cy,s(54),16,true)
        self:hit(self.w-side-s(64),cy-s(8),s(64),s(40),function()if o.clear then o.clear()end;UI:setDirty(d,'ui')end)
        cy=cy+s(44)
        for _,q in ipairs(o.history and o.history()or{})do
            if cy+s(42)>self.h-s(54)then break end
            self:icon(bb,'abc_ic_search_api_material',x+side+s(5),y+cy+s(7),s(18),s(18))
            label(q,side+s(36),cy+s(5),width-s(42),18,true)
            self:hit(side,cy,width,s(42),function()o.submit(q)end);cy=cy+s(48)
        end
        bb:paintRect(x,y+self.h-s(52),self.w,s(1),BB.COLOR_LIGHT_GRAY)
        self:icon(bb,'icon_toolbar_back',x+side,y+self.h-s(42),s(28),s(28))
        self:hit(0,self.h-s(52),s(90),s(52),function()UI:close(d)end)
    else
        bb:paintRect(x,y,self.w,s(1),BB.COLOR_LIGHT_GRAY)
        local left,right=s(66),s(100);local top=s(16)
        bb:paintRect(x+left,y+s(44),s(1),self.h-s(64),BB.COLOR_LIGHT_GRAY)
        self:icon(bb,'icon_toolbar_back',x+s(20),y+s(54),s(28),s(28))
        label('返回',s(8),s(88),left-s(16),14,true,nil,true)
        self:hit(0,0,left,self.h,function()UI:close(d)end)
        self:icon(bb,o.kind=='comment'and'icon_review_detail_comment'or'icon_newidea',x+left+s(14),y+top,s(24),s(24))
        self[1]:paintTo(bb,x+left+s(50),y+s(12))
        local action=o.action or'发表';local ax=self.w-right
        label(action,ax+s(6),s(38),right-s(20),18,true,nil,true)
        self:hit(ax,0,right,s(80),function()o.submit(d:getInputText())end)
        if o.visibility then
            bb:paintBorder(x+ax+s(6),y+s(86),right-s(20),s(28),s(1),BB.COLOR_DARK_GRAY,s(14))
            label(o.visibility()..' ›',ax+s(10),s(89),right-s(28),12,false,BB.COLOR_DARK_GRAY,true)
            self:hit(ax,s(78),right,s(48),o.pickVisibility)
        end
        if o.quote and o.quote~=''then
            local q=require('readinknative/annotations').summary(o.quote);local qx=left+s(18)
            bb:paintRect(x+qx,y+s(94),s(2),s(23),BB.COLOR_BLACK)
            label(q,qx+s(10),s(94),self.w-right-qx-s(24),14,false,BB.COLOR_DARK_GRAY)
        end
    end
end
function P:free()
    for _,i in pairs(self.icons or{})do i:free()end;self.icons=nil
    Container.free(self)
end
local D=Input:extend{}
function D:init()
    local screen=require('device').screen;local s=function(v)return screen:scaleBySize(v)end
    local o=self.official;self.width=screen:getWidth();self.is_movable=false;self.border_size=0;self.condensed=true
    self.input_padding=0;self.input_margin=0;self.button_padding=0;self.title=''
    self.multiline=o.kind~='search';self.allow_newline=self.multiline
    self.condensed=false -- InputDialog's condensed mode overwrites text_width.
    self.text_height=s(o.kind=='search'and 28 or 72)
    self.text_width=self.width-s(o.kind=='search'and 120 or 234)
    self.input_hint=o.kind=='search'and'搜索' or o.kind=='comment'and'写评论…'or'写下这一刻的想法…'
    self.inputtext_class=require('ui/widget/inputtext'):extend{bordersize=0,padding=0,margin=0}
    self.buttons={{{id='close',text='返回',callback=function()UI:close(self)end},{text=o.action or'发表',is_enter_default=true,callback=function()o.submit(self:getInputText())end}}}
    if o.kind=='search'then self.enter_callback=function()o.submit(self:getInputText())end end
    Input.init(self)
    local available=screen:getHeight()-(self.keyboard_visible and self._input_widget:getKeyboardDimen().h or 0)
    local panel=P:new{w=self.width,h=o.kind=='search'and available or math.min(available,s(136)),s=s,dialog=self,self._input_widget}
    self.officialPanel=panel;self.covers_fullscreen=o.kind=='search';self.deny_keyboard_hiding=o.kind=='search'
    self.dialog_frame=panel;self.layout={{self._input_widget}}
    local Outer=require(o.kind=='search'and'ui/widget/container/topcontainer'or'ui/widget/container/bottomcontainer')
    self[1]=Outer:new{dimen=Geom:new{w=self.width,h=available},panel}
end
function D:onCloseDialog()UI:close(self);return true end
function D:onTap(_,ges)
    if not ges or not ges.pos then return end
    local kb=self._input_widget.keyboard
    if kb and kb.dimen and ges.pos:intersectWith(kb.dimen)then return true end
    local r=self.officialPanel.dimen
    if ges.pos:intersectWith(r)then return true end
    if self.official.kind~='search'then UI:close(self);return true end
end
function D:onCloseWidget()
    Input.onCloseWidget(self)
    for _,i in pairs(self.officialPanel.icons or{})do i:free()end;self.officialPanel.icons=nil
end
return D
