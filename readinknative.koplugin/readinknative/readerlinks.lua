-- Book-owned, local reader interactions. No URL fetches or account writes.
local L={MAX_NOTE=65536}
local function owner(a)return{state=a.state,book=a.book,chapter=a.chapter,document=a.document}end
local function same(a,o)return o and o.state==a.state and o.book==a.book and o.chapter==a.chapter and o.document==a.document end
function L.noteText(html)
    if type(html)~='string'or #html>L.MAX_NOTE then return end
    if html:find('%z')or require('util').fixUtf8(html,'')~=html then return end
    html=html:gsub('<!%-%-.-%-%->',''):gsub('<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>','')
        :gsub('<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>','')
    local text=require('util').htmlToPlainText(html)
    if text:find('%S')then return text end
end
function L.inlineNote(url)
    if type(url)~='string'or url:sub(1,11)~='footnote://'or #url>3*L.MAX_NOTE then return end
    local body=url:sub(12)
    if body:gsub('%%%x%x',''):find('%%')then return end
    body=body:gsub('%+',' '):gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
    if body:find('%z')then return end
    return L.noteText(body)
end
function L.currentNote(a)
    if same(a,a.footnote)then return a.footnote end
    a.footnote=nil
end
function L.dismiss(a,silent)
    a.footnote=nil
    if a.readerOverlay then a.readerOverlay.silent=silent;a.readerOverlay:onClose()end
end
function L.reset(a)L.dismiss(a,true);a.linkHistory=nil end
function L.back(a)
    if a.readerOverlay then a.readerOverlay:onClose();return true end
    if L.currentNote(a)then a.footnote=nil;a:draw();return true end
    local history=a.linkHistory or{}
    while #history>0 do
        local previous=table.remove(history)
        if same(a,previous)and a.document:restorePosition(previous.position)then a:savePosition();a:draw();return true end
    end
    return false
end
function L.tap(a,point)
    if a.closed or a.suspended or a.mode~='reader'or a.panel or a.toolbar or a.textSelection or a.readerOverlay or not a.document then return false end
    local link=a.document:linkAt(point)
    if link then
        if link.kind=='footnote'then
            local note=owner(a);note.text=link.text;note.point=point;note.page=1;a.footnote=note;a:draw()
        elseif link.kind=='anchor'then
            local previous=owner(a);previous.position=a.document:position()
            if a.document:gotoPointer(link.target)then
                a.linkHistory=a.linkHistory or{};table.insert(a.linkHistory,previous)
                if #a.linkHistory>16 then table.remove(a.linkHistory,1)end
                a:savePosition();a:draw()
            end
        else a:message('此链接的内容不在当前已缓存章节中。')end
        return true
    end
    if not require('readinknative/preferences').normalize(a.state.preferences).tapImages then return false end
    local image=a.document:imageAt(point)
    if not image then return false end
    local ok,widget=pcall(function()return require('readinknative/imagepreview'):new{app=a,image=image}end)
    if not ok then image:free();a:message('此图片暂时无法预览，正文位置已保留。');return true end
    a.readerOverlay=widget
    require('ui/uimanager'):show(widget)
    return true
end
function L.paint(v,bb)
    local a,l=v.app,v.layout;local note=L.currentNote(a);if not note then return end
    local s=l.s;local w=math.min(l.w-s(16),s(l.w/s(1)>=600 and 344 or 304))
    local horizontal,top,bottom=s(16),s(14),s(12);local size=s(17)
    local maxText=math.min(math.floor(size*1.45*8),math.floor(l.h*0.45))
    local Box=require('ui/widget/textboxwidget');local Font=require('ui/font')
    local measure=Box:new{text=note.text,face=Font:getFace('cfont',size/v.fontScale),width=w-2*horizontal,height=maxText,height_adjust=true,height_overflow_show_ellipsis=false}
    local textHeight=math.min(maxText,measure:getSize().h,8*measure:getLineHeight());measure:free()
    local h=textHeight+top+bottom
    local anchorX,anchorY=l.body.x+note.point.x,l.body.y+note.point.y
    local x=math.max(s(8),math.min(l.w-w-s(8),math.floor(anchorX-w/2)))
    local y=anchorY-h-s(15);local above=y>=l.body.y
    if not above then y=math.min(l.h-l.bottom-h,anchorY+s(15))end
    y=math.max(l.body.y,y)
    local BB=require('ffi/blitbuffer')
    v:hit({x=0,y=0,w=l.w,h=l.h},function()a.footnote=nil;a:draw()end)
    bb:paintRoundedRect(x,y,w,h,BB.COLOR_WHITE,s(16));bb:paintBorder(x,y,w,h,s(1),BB.COLOR_BLACK,s(16))
    local arrowX=math.max(x+s(18),math.min(x+w-s(34),anchorX-s(8)))
    v:icon(bb,'icon_general_bubble_arrow',arrowX,above and y+h-s(1)or y-s(9),s(16),s(10),nil,nil,{w=16,h=10,rotation=above and 0 or 180})
    note.page,note.pages=v:pageText(bb,note.text,x+horizontal,y+top,w-2*horizontal,textHeight,size,note.page)
    v:hit({x=x,y=y,w=w,h=h},function()end)
end
return L
