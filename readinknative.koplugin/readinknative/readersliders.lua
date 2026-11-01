-- A captured slider gesture previews a continuous position, commits once at
-- release, and never asks CRe to paint/reflow or reads a chapter while moving.
local M={}
local function clamp(v)return math.max(0,math.min(1,v))end
local function valid(v,d)
 local a=v.app
 return d and not a.closed and not a.suspended and a.mode=='reader'and a.toolbar and a.panel==d.panel
  and a.state==d.state and a.book==d.book and a.document==d.document and v.layout==d.layout
  and a.document.format==d.format and a.document:page()==d.page
end
function M.active(v)
 if valid(v,v.sliderDrag)then return v.sliderDrag end
 if v.sliderDrag then M.cancel(v)end
end
local function clearPreview(v,d)
 for i=#v.objects,d.objectCount+1,-1 do local obj=v.objects[i];if obj.free then obj:free()end;v.objects[i]=nil end
end
function M.cancel(v)
 local d=v and v.sliderDrag;if not d then return false end
 v.sliderDrag=nil;v.sliderConsumed=true;v.dithered=d.dithered;clearPreview(v,d)
 if d.snapshot then d.snapshot:free();d.snapshot=nil end
 return true
end
function M.hit(v,spec)
 spec.owner={state=v.app.state,book=v.app.book,document=v.app.document,panel=v.app.panel,format=v.app.document.format,page=v.app.document:page(),layout=v.layout}
 v.sliderHits[#v.sliderHits+1]=spec
 v:hit(spec.rect,function(x,y)M.tap(v,spec,x,y)end)
end
local function ratio(spec,x,offset)return clamp((x-(offset or 0)-spec.low)/math.max(1,spec.high-spec.low))end
function M.redraw(v)
 local d=M.active(v);if not d then return false end
 require('ui/uimanager'):setDirty(v,'fast',require('ui/geometry'):new(d.damage),false);return true
end
function M.move(v,g)
 local d=M.active(v);if not d then return false end
 local p=g and(g.end_pos or g.pos);if not p or type(p.x)~='number'or p.x~=p.x then return true end
 local r=ratio(d.spec,p.x,d.offset)
 if math.abs(r-d.ratio)*math.max(1,d.spec.high-d.spec.low)>=0.5 then d.ratio=r;M.redraw(v)end
 return true
end
function M.begin(v,g)
 -- A new contact during an existing drag is another finger: cancel both.
 if v.sliderDrag then M.cancel(v);v:refresh();return true end
 v.sliderConsumed=nil
 local a=v.app;local p=g and g.pos
 if not p or a.closed or a.suspended or a.mode~='reader'or not a.toolbar or not a.document or(a.panel~='font'and a.panel~='progress')then return false end
 for i=#(v.sliderHits or{}),1,-1 do local q=v.sliderHits[i]
  if valid(v,q.owner)and require('readinknative/layout').contains(q.rect,p.x,p.y)then
   require('readinknative/offline').interact(a)
   local knob=q.low+(q.high-q.low)*q.ratio
   local offset=math.abs(p.x-knob)<=q.thumbRadius+v.layout.s(6)and p.x-knob or 0
   local buffer=require('device').screen.bb
   local ok,snapshot=pcall(buffer.copy,buffer);if not ok then return false end
   v.sliderDrag={spec=q,state=a.state,book=a.book,document=a.document,format=a.document.format,
    panel=a.panel,page=a.document:page(),layout=v.layout,ratio=q.ratio,offset=offset,snapshot=snapshot,
    objectCount=#v.objects,damage=q.damage or q.rect,dithered=v.dithered}
   M.move(v,g);return true
  end
 end
 return false
end
function M.apply(v,q,r)
 local a=v.app
 if q.kind=='font'then
  -- A native half-size, quarter-weight or custom margin must survive touching
  -- the current thumb without moving it, including a clamped end position.
  if math.abs(r-q.ratio)<1e-9 then a:draw();return end
  local value=require('readinknative/readerpanels').value(q.row,r)
  if a.state:format(a.book)[q.row[1]]~=value then a:changeFormat{[q.row[1]]=value}else a:draw()end
 else
  local page,total=require('readinknative/pagination').position(a)
  if total and total>=1 then local target=math.floor(r*(total-1)+1.5)
   if target~=page then require('readinknative/pagination').jump(a,target)else a:draw()end
  else a:draw()end
 end
end
function M.finish(v,g)
 local d=M.active(v);if not d then return false end
 M.move(v,g);local q,r=d.spec,d.ratio
 M.cancel(v);M.apply(v,q,r);return true
end
function M.tap(v,q,x)
 if not valid(v,q.owner)then return true end
 if M.active(v)then return M.finish(v,{pos={x=x}})end
 M.apply(v,q,ratio(q,x));return true
end
function M.paint(v,bb)
 local d=M.active(v);if not d then return false end
 clearPreview(v,d);v.dithered=false
 bb:blitFrom(d.snapshot,0,0,0,0,v.layout.w,v.layout.h)
 if d.spec.kind=='font'then
  require('readinknative/readerpanels').track(v,bb,d.spec.row,d.spec.rect.y,{ratio=d.ratio,keepValue=math.abs(d.ratio-d.spec.ratio)<1e-9})
 else
  local q={};for k,value in pairs(d.spec.summary)do q[k]=value end
  q.page=math.floor(d.ratio*(q.total-1)+1.5);q.percent=math.floor(100*q.page/q.total);q.previewRatio=d.ratio
  require('readinknative/readerpanels').progress(v,bb,q)
 end
 return true
end
return M
