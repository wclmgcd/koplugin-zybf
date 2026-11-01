-- Official E-Ink sheet hierarchy; font faces come from the local CRe engine.
local BB=require('ffi/blitbuffer');local M={}
M.rows={{'size','小','大',16,56,2},{'weight','细','粗',0,3,0.5},{'line','紧','松',100,220,5},{'margin','小','大',8,56,4}}
function M.value(row,ratio)
 local value=row[4]+math.max(0,math.min(1,ratio))*(row[5]-row[4])
 return math.max(row[4],math.min(row[5],math.floor(value/row[6]+0.5)*row[6]))
end
function M.step(row,current,delta)
 local low,high,step=row[4],row[5],row[6]
 -- Native controls can retain values outside this simpler control's range.
 -- Never make a + button reduce such a value, or a - button increase it.
 if current<low then return delta>0 and math.min(low,current+step)or current end
 if current>high then return delta<0 and math.max(high,current-step)or current end
 local tick=(current-low)/step
 local nextTick=delta>0 and math.floor(tick+1e-9)+1 or math.ceil(tick-1e-9)-1
 return math.max(low,math.min(high,low+nextTick*step))
end
function M.thumbText(row,f)
 local key=row[1]
 if key=='size'then return tostring(f.size)end
 if key=='weight'then
  local level=f.weight*2;local rounded=math.floor(level+0.5)
  if f.weight<row[4]or f.weight>row[5]or math.abs(level-rounded)>1e-6 then return'自定'end
  return tostring(rounded)
 end
 if key=='line'then return'行距'end
 if f.margin_left~=nil and f.margin_right~=nil and f.margin_left~=f.margin_right then return'自定'end
 return'边距'
end
function M.sheet(v,bb,height,preview)
 local l,s=v.layout,v.layout.s;local y=math.max(0,l.h-l.bottom-s(height));local h=l.h-l.bottom-y
 bb:paintRect(0,y,l.w,h,BB.COLOR_WHITE);bb:paintRect(0,y,l.w,s(1),BB.COLOR_LIGHT_GRAY)
 if not preview then v:hit({x=0,y=0,w=l.w,h=y},function(x)v:readerTap(x)end)
 v:hit({x=0,y=y,w=l.w,h=h},function()end)end;return y,h
end
local function label(v,bb,text,x,y,w,size,bold,color,height,fontFile,fit)
 local Text=require('ui/widget/textwidget');local Font=require('ui/font');local object
 -- The thumb holds two Chinese glyphs. Measure their real fallback-font
 -- width before applying a width cap, otherwise TextWidget adds an ellipsis.
 local logical=size/v.fontScale
 repeat
  if object then object:free()end
  object=Text:new{text=text,face=Font:getFace(fontFile or'cfont',logical)or Font:getFace('cfont',logical),max_width=not fit and w or nil,bold=bold or false,fgcolor=color or BB.COLOR_BLACK}
  if not fit or object:getSize().w<=w or logical<=8 then break end
  logical=logical-0.5
 until false
 v.objects[#v.objects+1]=object;local z=object:getSize();object:paintTo(bb,math.floor(x+(w-z.w)/2),math.floor(y+(height and(height-z.h)/2 or 0)))
end
function M.faces(document)return require('readinknative/readerfonts').faces(document)end
-- Render the capsule as a single SVG: thin FFI white strokes can widen after
-- repeated high-DPI paints. Reuse the view's bounded image LRU and lifecycle.
local function trackImage(v,bb,x,y,w,h,r,width,knob,divisions)
 local key=table.concat({'font-track',w,h,width,knob,divisions or 10},':');local entry=v.iconObjects[key]
 if not entry then
  local lines={};for i=divisions and 0 or 1,divisions and divisions-1 or 9 do
   local tick=math.floor((divisions and v.layout.s(58)+(w-v.layout.s(116))*i/divisions or r+(w-h)*i/10)+0.5)
   if tick<width-r then lines[#lines+1]=string.format('<path d="M%d 0V%d" stroke="white" stroke-width="%d"/>',tick,h,v.layout.s(1))end
  end
  local svg=string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"><rect width="%d" height="%d" rx="%d" fill="#ccc"/><rect width="%d" height="%d" rx="%d" fill="black"/>%s<circle cx="%d" cy="%d" r="%d" fill="white" stroke="black" stroke-width="%d"/></svg>',w,h,w,h,w,h,r,math.min(w,width+r),h,r,table.concat(lines),knob,r,r-v.layout.s(1),v.layout.s(1))
  local buffer=assert(require('ui/renderimage'):renderSVGImageDataWithCRengine(svg,#svg,w,h),'FONT_TRACK_IMAGE_FAILED')
  local object=require('ui/widget/imagewidget'):new{image=buffer,alpha=true};local bytes=w*h*4
  while #v.iconOrder>0 and(#v.iconOrder>=48 or v.iconBytes+bytes>4*1024*1024)do
   local old=table.remove(v.iconOrder,1);local item=v.iconObjects[old];v.iconBytes=v.iconBytes-item.bytes;item.object:free();v.iconObjects[old]=nil
  end
  entry={object=object,bytes=bytes};v.iconObjects[key]=entry;v.iconBytes=v.iconBytes+bytes
 else for i,k in ipairs(v.iconOrder)do if k==key then table.remove(v.iconOrder,i);break end end end
 v.iconOrder[#v.iconOrder+1]=key;entry.object:paintTo(bb,x,y)
end
function M.track(v,bb,row,y,preview)
 local a,l=v.app,v.layout;local s=l.s;local f=a.state:format(a.book);local key=row[1]
 local x,w,h=l.side+s(42),l.w-2*l.side-s(84),s(32);local r=math.floor(h/2)
 local ratio=preview and preview.ratio or math.max(0,math.min(1,(f[key]-row[4])/(row[5]-row[4])))
 if preview and not preview.keepValue then
  local copy={};for k,value in pairs(f)do copy[k]=value end;f=copy;f[key]=M.value(row,ratio)
  if key=='margin'then f.margin_left=f.margin;f.margin_right=f.margin end
 end
 local knob=math.floor(x+s(58)+(w-s(116))*ratio+0.5)
 local width=math.max(h,math.min(w,knob-x))
 trackImage(v,bb,x,y,w,h,r,width,knob-x,key=='weight'and 6 or nil)
 label(v,bb,row[2],x+s(8),y,s(28),s(15),true,BB.COLOR_WHITE,h)
 label(v,bb,row[3],x+w-s(32),y,s(24),s(15),true,nil,h)
 local text=M.thumbText(row,f)
 label(v,bb,text,knob-r+s(3),y,2*r-s(6),s(14),true,nil,h,nil,true)
 for _,delta in ipairs{-1,1}do local bx=delta<0 and l.side or l.w-l.side-h
  bb:paintCircle(bx+r,y+r,r-s(1),BB.COLOR_BLACK,s(1))
  if preview then label(v,bb,delta<0 and'−'or'+',bx,y,h,s(17),false,nil,h)
  else v:button(bb,delta<0 and'−'or'+',bx,y,h,h,function()
   local current=a.state:format(a.book)[key];local value=M.step(row,current,delta)
   if value~=current then a:changeFormat{[key]=value}else a:draw()end
  end)end
 end
 if not preview then require('readinknative/readersliders').hit(v,{kind='font',row=row,ratio=ratio,thumbRadius=r,
  low=x+s(58),high=x+w-s(58),rect={x=x,y=y,w=w,h=h},damage={x=0,y=y-s(2),w=l.w,h=h+s(4)}})end
end
function M.font(v,bb)
 local a,l=v.app,v.layout;local s=l.s;local y=M.sheet(v,bb,442);local f=a.state:format(a.book)
 v:text(bb,'字体设置',l.side,y+s(15),s(160),s(18),true)
 local iw=math.min(s(136),l.w*0.43)
 bb:paintBorder(l.w-l.side-iw,y+s(9),iw,s(30),s(1),BB.COLOR_BLACK,s(15))
 v:button(bb,'首行缩进 '..(f.indent and'›'or'关 ›'),l.w-l.side-iw,y+s(9),iw,s(30),function()a:changeFormat{indent=not f.indent}end)
 for i,row in ipairs(M.rows)do M.track(v,bb,row,y+s(52+(i-1)*42))end
 v:text(bb,'当前选择 · '..require('readinknative/readerfonts').name(f.face),l.side,y+s(228),l.w-2*l.side,s(17),true)
 -- Font catalog uses the official Chinese display names; downloaded styles
 -- keep distinct engine families so choosing 04 cannot silently render 05.
 local fonts=require('readinknative/readerfonts');local entries=fonts.grid(a.document,f.face)
 local columns=3;local gap=s(7);local w=(l.w-2*l.side-gap*2)/columns
 for i=1,9 do
  local entry=entries[i-1];local name=i==1 and'系统字体'or i==9 and'查看更多 ›'or entry and entry.fontName
  if name then
   local x=l.side+((i-1)%3)*(w+gap);local yy=y+s(266)+math.floor((i-1)/3)*s(53)
   if i==9 then
    bb:paintRoundedRect(x,yy,w,s(46),BB.COLOR_LIGHT_GRAY,s(10))
    label(v,bb,name,x+s(5),yy,w-s(10),s(14),false,nil,s(46))
    v:hit({x=x,y=yy,w=w,h=s(46)},function()a:showFontFaces('readink')end)
   else
    local item=i==1 and{fontName='系统字体',system=true}or entry
    require('readinknative/fontpicker').tile(v,bb,item,x,yy,w,s(46),i==1 and not f.face or i>1 and entry.face==f.face and f.face~=nil)
   end
  end
 end
end
function M.refresh(a)
 if a.book.localFile or not a.client:ready()or not(a.progressEnabled or require('device'):isKindle())then return end
 local network=require('ui/network/manager');if not network:isWifiOn()or not network:isConnected()then return end
 local state,book,document,data=a.state,a.book,a.document,a.client.data;local id=tostring(book.bookId)
 state.readerSummary=state.readerSummary or{};local old=state.readerSummary[id]
 if old and type(old.at)=='number'and os.time()>=old.at and os.time()-old.at<300 then return end
 -- Don't overlap an in-flight time report: its acknowledgement can race a GET.
 if a.syncBusy then return end
 require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel()
 return a.jobs:run('',function()
  local child=require('readinknative/client'):new(data)
  local remote=require('readinknative/readsyncapi').pull(child,book)
  return remote,child.data
 end,function(ok,remote,session)
  if a.closed or a.suspended or a.state~=state or a.book~=book or a.document~=document or a.panel~='progress'or a.client.data~=data then return end
  if not ok or not remote or not remote.readingTimeKnown or remote.version and tostring(remote.version)~=tostring(book.version)then return end
  if session then a.client.data=session;a.client.session.data=session;a.client:commit()end
  local pending=state.readSync and state.readSync.pending and state.readSync.pending[id]
  local unsent=pending and tonumber(pending.seconds)or 0
  if state.readSync and state.readSync.flight then unsent=0 end -- outcome unknown, do not double count
  local recorded=tonumber(remote.recordReadingTime)or 0
  if recorded<0 or recorded>1e12 then recorded=0 end
  state.readerSummary[id]={at=os.time(),seconds=remote.readingTime+recorded+math.max(0,unsent),
   localSeconds=require('readinknative/readingstats').total(state,id),percent=remote.percent}
  state:flush();a:draw()
 end,false)
end
function M.summary(a)
 local page,total=require('readinknative/pagination').position(a)
 local percent=type(page)=='number'and type(total)=='number'and total>0 and math.max(0,math.min(100,math.floor(100*page/total)))or nil
 local S=require('readinknative/readingstats');local seconds=S.total(a.state,a.book.bookId)
 -- Only device-observed time is counted. Do not label it as an all-device total.
 local estimate='预计时间待估算'
 local localSeconds=seconds;local synced=(a.state.readerSummary or{})[tostring(a.book.bookId)]
 if type(synced)=='table'and type(synced.seconds)=='number'and synced.seconds>=0 and type(synced.localSeconds)=='number'then seconds=synced.seconds+math.max(0,seconds-synced.localSeconds)else synced=nil end
 local started=a.progressBaseline
 if percent and started and started.book==a.book and percent>started.percent and localSeconds>started.seconds+60 then
  local remain=(localSeconds-started.seconds)*(100-percent)/(percent-started.percent)
  estimate=percent>=100 and'已读完'or'约 '..S.duration(remain)..'后读完'
 end
 if estimate=='预计时间待估算'and synced and seconds>=300 and type(synced.percent)=='number'and synced.percent>0 and synced.percent<100 then estimate='约 '..S.duration(seconds*(100-synced.percent)/synced.percent)..'后读完'end
 return{page=page,total=total,percent=percent,seconds=seconds,localSeconds=localSeconds,synced=synced~=nil,duration=S.duration(seconds),estimate=estimate,notes=#require('readinknative/collections').records(a)}
end
function M.chapter(a,delta)
 local chapters=a:catalogItems();local index
 if a.book.localFile then index=(require('readinknative/collections').current(a)or 1)+delta
 else index=require('readinknative/pagination').next(a,delta)end
 if chapters[index]then a:selectChapter(chapters[index],index)end
end
function M.progress(v,bb,preview)
 local a,l=v.app,v.layout;local s=l.s;local y=M.sheet(v,bb,190,preview);local q=preview or M.summary(a);local width=(l.w-2*l.side)/3
 local cells={{q.percent and(q.percent..'%')or'—',q.estimate},{q.duration,q.synced and'阅读时长'or'本机阅读时长'},{q.notes..' 条','笔记'}}
 for i,c in ipairs(cells)do local x=l.side+(i-1)*width
  v:text(bb,c[1],x,y+s(24),width,s(i==2 and 18 or 24),true,1,nil,nil,nil,'center')
  v:text(bb,c[2],x,y+s(64),width,s(12),false,2,nil,nil,nil,'center')
  if i==3 and not preview then v:hit({x=x,y=y+s(18),w=width,h=s(80)},function()a:notes()end)end

 end
 for i=1,2 do bb:paintRect(l.side+i*width,y+s(22),s(1),s(64),BB.COLOR_LIGHT_GRAY)end
 local x,w,h=l.side,l.w-2*l.side,s(36);local yy=y+s(120);local pad=s(40)
 bb:paintRoundedRect(x,yy,w,h,BB.COLOR_LIGHT_GRAY,h/2)
 local ratio=q.previewRatio or(q.total and(q.page-1)/math.max(1,q.total-1)or 0);ratio=math.max(0,math.min(1,ratio))
 local knob=x+pad+h/2+(w-pad*2-h)*ratio
 local viewport=bb:viewport(x,yy,math.max(h,knob-x),h);viewport:paintRoundedRect(0,0,w,h,BB.COLOR_BLACK,h/2);viewport:free()
 bb:paintCircle(knob,yy+h/2,h/2-s(1),BB.COLOR_WHITE);bb:paintCircle(knob,yy+h/2,h/2-s(1),BB.COLOR_BLACK,s(1))
 label(v,bb,'‹',x,yy,pad,s(26),true,BB.COLOR_WHITE,h)
 label(v,bb,'›',x+w-pad,yy,pad,s(26),true,nil,h)
 if not preview then
  v:hit({x=x,y=yy,w=pad,h=h},function()M.chapter(a,-1)end)
  v:hit({x=x+w-pad,y=yy,w=pad,h=h},function()M.chapter(a,1)end)
  if q.total and q.total>=1 then require('readinknative/readersliders').hit(v,{kind='progress',summary=q,ratio=ratio,thumbRadius=h/2,
   low=x+pad+h/2,high=x+w-pad-h/2,rect={x=x+pad,y=yy,w=w-pad*2,h=h},damage={x=0,y=y,w=l.w,h=l.h-l.bottom-y}})
  else v:hit({x=x+pad,y=yy,w=w-pad*2,h=h},function()end)end
 end
end
return M
