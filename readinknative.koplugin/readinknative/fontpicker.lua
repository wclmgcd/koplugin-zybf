-- Categorized native font sheet traced from the supplied official screenshot.
local M={};local BB=require('ffi/blitbuffer')
local function text(v,bb,value,x,y,w,h,size,bold,color,file)
 local Font=require('ui/font');local obj=require('ui/widget/textwidget'):new{text=value,face=Font:getFace(file or'cfont',size)or Font:getFace('cfont',size),max_width=w,bold=bold or false,fgcolor=color or BB.COLOR_BLACK}
 v.objects[#v.objects+1]=obj;local z=obj:getSize();obj:paintTo(bb,math.floor(x+(w-z.w)/2),math.floor(y+(h-z.h)/2))
end
function M.geometry(l)
 local s=l.s;local height=math.min(l.h-l.bottom,math.max(s(442),math.floor(l.h*0.68)))
 local y=math.max(0,l.h-l.bottom-height);local grid=y+s(116);local bottom=l.h-l.bottom-s(54)
 local rows=math.max(1,math.floor((bottom-grid)/s(59)));return{y=y,height=height,grid=grid,rows=rows,count=rows*3,footer=bottom}
end
function M.turn(a,delta)
 local g=M.geometry(a.view.layout);local items=require('readinknative/readerfonts').filtered(a.document,a.fontCategory)
 local pages=math.max(1,math.ceil(#items/g.count));a.fontPage=math.max(1,math.min(pages,(a.fontPage or 1)+delta));a:draw()
end
function M.tile(v,bb,item,x,y,w,h,selected)
 local a,l=v.app,v.layout;local s=l.s;local fonts=require('readinknative/readerfonts')
 local busy=a.fontDownload and item.font and a.fontDownload.font==item.font
 local color=selected and BB.COLOR_WHITE or BB.COLOR_BLACK
 bb:paintRoundedRect(x,y,w,h,selected and BB.COLOR_BLACK or BB.COLOR_LIGHT_GRAY,s(10))
 text(v,bb,fonts.caption(item),x+s(5),y,w-s(10),busy and math.floor(h*0.6)or h,14,selected,color,item.face and fonts.preview(a.document,item.face))
 if busy then text(v,bb,'下载中',x+s(5),y+math.floor(h*0.56),w-s(10),math.floor(h*0.4),11,false,color)
 elseif item.font and not item.face and not item.bundled and item.creSupported~=false and item.url and item.url~=''then
  v:icon(bb,'icon_toolbar_download',x+w-s(22),y+s(2),s(18),s(18),nil,nil,{w=12,h=12})
 end
 v:hit({x=x,y=y,w=w,h=h},function()
  if item.system then require('readinknative/fontprogress').cancel(a);a:changeFormat{face=false};a:draw()
  else require('readinknative/fontfetch').select(a,item)end
 end)
end
function M.paint(v,bb)
 local a,l=v.app,v.layout;local s=l.s;local fonts=require('readinknative/readerfonts');local g=M.geometry(l)
 require('readinknative/readerpanels').sheet(v,bb,g.height/(s(100)/100))
 v:icon(bb,'icon_me_arrow',l.side,g.y,s(45),s(52),function()a:backFromFontFaces()end,nil,{w=32,h=32,rotation=270})
 text(v,bb,'字体',l.side+s(50),g.y,l.w-2*l.side-s(100),s(38),22,true)
 local f=a.state:format(a.book)
 text(v,bb,'当前选择 · '..fonts.name(f.face),l.side,g.y+s(38),l.w-2*l.side,s(28),14,true)
 local categories=fonts.categories();local tabY=g.y+s(77);local tabH=s(34);local tabW=(l.w-2*l.side)/4
 bb:paintRoundedRect(l.side,tabY,l.w-2*l.side,tabH,BB.COLOR_WHITE,math.floor(tabH/2))
 bb:paintBorder(l.side,tabY,l.w-2*l.side,tabH,s(1),BB.COLOR_LIGHT_GRAY,math.floor(tabH/2))
 for i,q in ipairs(categories)do
  local selected=(a.fontCategory or'全部')==q.name;local x=l.side+(i-1)*tabW
  if selected then bb:paintRoundedRect(x,tabY,tabW,tabH,BB.COLOR_BLACK,math.floor(tabH/2))end
  text(v,bb,q.name..'['..q.count..']',x+s(3),tabY,tabW-s(6),tabH,15,selected,selected and BB.COLOR_WHITE or BB.COLOR_BLACK)
  v:hit({x=x,y=tabY,w=tabW,h=tabH},function()a.fontCategory=q.name;a.fontPage=1;a:draw()end)
 end
 local items=fonts.filtered(a.document,a.fontCategory);local pages=math.max(1,math.ceil(#items/g.count));a.fontPage=math.max(1,math.min(a.fontPage or 1,pages))
 local gap=s(8);local w=math.floor((l.w-2*l.side-2*gap)/3)
 for i=1,g.count do
  local item=items[(a.fontPage-1)*g.count+i]
  if item then M.tile(v,bb,item,l.side+((i-1)%3)*(w+gap),g.grid+math.floor((i-1)/3)*s(59),w,s(51),item.system and not f.face or item.face~=nil and item.face==f.face)end
 end
 v:button(bb,'本机字体',l.side,g.footer,s(110),s(48),function()a.fontCategory='本机';a.fontPage=1;a:draw()end,a.fontCategory=='本机')
 v:button(bb,'排版选项',l.side+s(110),g.footer,s(110),s(48),function()require('readinknative/readingmenu').extraFormat(a)end)
 v:button(bb,'‹',l.w-s(180),g.footer,s(48),s(48),function()M.turn(a,-1)end)
 text(v,bb,a.fontPage..' / '..pages,l.w-s(132),g.footer,s(64),s(48),14)
 v:button(bb,'›',l.w-s(68),g.footer,s(48),s(48),function()M.turn(a,1)end)
end
return M
