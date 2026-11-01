-- Account statistics are saved immediately. Only repaint an exposed page;
-- native modal closure restores its own rectangle without forcing a flash.
-- Compose off-screen, then copy the finished frame once; never stall input
-- waiting for an e-ink waveform on every account-page redraw.
local UI=require('ui/uimanager')
local Geom=require('ui/geometry')
local R={}
local function vid(a)return tostring(a.client and a.client.data and a.client.data.vid or'')end
local function current(a,o)
 return o and not a.closed and not a.suspended and a.mode=='account'
  and a.view==o.view and a.state==o.state and vid(a)==o.vid
end
local function shown(view)
 return type(UI.isWidgetShown)=='function'and UI:isWidgetShown(view)
end
local function onScreen(bb)return bb==require('device').screen.bb end
function R.owner(a)
 if not a or a.closed or a.suspended or a.mode~='account'or not a.view or not a.state or not shown(a.view)then return end
 return{view=a.view,state=a.state,vid=vid(a)}
end
function R.request(a)
 local o=R.owner(a);if not o then return false end
 a.accountRefreshPending=o
 -- Do not go through App:draw/View:refresh: that would also enqueue the
 -- ordinary whole-page refresh and swallow the measured smaller regions.
 if type(UI.getTopmostVisibleWidget)=='function'and UI:getTopmostVisibleWidget()==o.view then UI:setDirty(o.view)end
 return true
end
function R.beforePaint(view,bb)
 -- Snapshots must not consume pending data, advance the screen baseline or
 -- wait on hardware. An obsolete View must not consume its replacement's work.
 if not onScreen(bb)then return end
 local a=view.app;local p=a.accountRefreshPending
 view.accountRefreshRequested=nil
 if p and p.view==view then
  a.accountRefreshPending=nil
  if current(a,p)and shown(view)then view.accountRefreshRequested=true end
 end
 local o=R.owner(a)
 if not o or o.view~=view then
  view.accountRefreshFrame=nil;view.accountRefreshRequested=nil;R.free(view);return bb
 end
 local surface=view.accountPaintSurface;local kind=bb:getType()
 if surface and(surface:getWidth()~=view.dimen.w or surface:getHeight()~=view.dimen.h or surface:getType()~=kind)then R.free(view);surface=nil end
 if not surface then
  local ok,result=pcall(require('ffi/blitbuffer').new,view.dimen.w,view.dimen.h,kind)
  if not ok then return bb end
  surface=result;view.accountPaintSurface=surface
 end
 view.accountComposedFrame=nil
 return surface
end
local function rect(view,r)
 if not r then return end
 local x,y=math.max(0,math.floor(r.x)),math.max(0,math.floor(r.y))
 local right,bottom=math.min(view.dimen.w,math.ceil(r.x+r.w)),math.min(view.dimen.h,math.ceil(r.y+r.h))
 if right>x and bottom>y then return Geom:new{x=x,y=y,w=right-x,h=bottom-y}end
end
local function sameRect(a,b)
 return a and b and a.x==b.x and a.y==b.y and a.w==b.w and a.h==b.h
end
local function union(view,a,b)
 a,b=rect(view,a),rect(view,b)
 if not a then return b end;if not b then return a end
 local x,y=math.min(a.x,b.x),math.min(a.y,b.y)
 return Geom:new{x=x,y=y,w=math.max(a.x+a.w,b.x+b.w)-x,h=math.max(a.y+a.h,b.y+b.h)-y}
end
local function paintKey(view)
 local a=view.app;local P=require('readinknative/preferences')
 return table.concat({require('readinknative/readprofile').displayKey(a),
  require('readinknative/accountinfo').memberText(a.state.accountInfo),P.exitButtonLabel(),
  require('readinknative/version'),tostring(a.accountPage or 1),
  tostring(a.offlineNotice and a.offlineNotice.text),tostring(a.offlineNotice and a.offlineNotice.icon),
  tostring(view.fontScale),tostring(view.layout),tostring(view.dimen.w),tostring(view.dimen.h)},'\0')
end
function R.reuse(view)
 local frame=view.accountPaintFrame
 if not frame or not current(view.app,frame.owner)or view.accountPaintKey~=paintKey(view)then return false end
 view.hits=view.accountPaintHits;view.sliderHits=view.accountPaintSliderHits
 view.accountComposedFrame=frame;return true
end
function R.free(view)
 view.accountPaintFrame=nil;view.accountPaintKey=nil;view.accountPaintHits=nil;view.accountPaintSliderHits=nil
 if view.accountPaintSurface then view.accountPaintSurface:free();view.accountPaintSurface=nil end
 view.accountComposedFrame=nil
end
function R.commit(view,surface,target)
 if surface==target or surface~=view.accountPaintSurface then return end
 -- No clear or text shaping happens in the mapped framebuffer. The native
 -- popup is subsequently painted above this complete account composition.
 target:blitFrom(surface,0,0,0,0,view.dimen.w,view.dimen.h)
 local frame=view.accountComposedFrame;view.accountComposedFrame=nil
 if frame then
  view.accountPaintFrame=frame;view.accountPaintKey=paintKey(view)
  view.accountPaintHits=view.hits;view.accountPaintSliderHits=view.sliderHits
  R.painted(view,target,frame)
 end
end
function R.painted(view,bb,frame)
 if bb==view.accountPaintSurface then view.accountComposedFrame=frame;return end
 if not onScreen(bb)then return end
 local o=R.owner(view.app);if not o or o.view~=view then return end
 frame.owner=o
 local old=view.accountRefreshFrame;local submitted=false
 local function submit(region)
  if region then UI:setDirty(nil,'ui',region);submitted=true end
 end
 if not old or not current(view.app,old.owner)or old.layout~=frame.layout
  or old.w~=frame.w or old.h~=frame.h or old.fontScale~=frame.fontScale then
  -- No trustworthy geometry from this page/device size: ordinary UI update,
  -- never an account-imposed full/flash waveform.
  submit(view.dimen)
 else
  if old.nameKey~=frame.nameKey or not sameRect(old.nameRect,frame.nameRect)then submit(union(view,old.nameRect,frame.nameRect))end
  if old.profileKey~=frame.profileKey or not sameRect(old.statsRect,frame.statsRect)then submit(union(view,old.statsRect,frame.statsRect))end
  if old.header~=frame.header or old.rowKey~=frame.rowKey or not sameRect(old.rowsRect,frame.rowsRect)then
   submit(union(view,old.rowsRect,frame.rowsRect))
  end
  if old.pagerKey~=frame.pagerKey or not sameRect(old.pagerRect,frame.pagerRect)then submit(union(view,old.pagerRect,frame.pagerRect))end
  if not submitted and view.accountRefreshRequested then
   -- A->B->A completions can coalesce before a queued paint. Keep that rare
   -- no-op bounded; otherwise the host supplies a whole-screen partial refresh.
   submit(rect(view,frame.statsRect))
  end
 end
 -- Every changed region has now been queued for this exact composition.
 -- Widgets above us are painted afterwards by UIManager, so their pixels stay
 -- on top; native closure later restores the part they used to cover.
 view.accountRefreshFrame=frame;view.accountRefreshRequested=nil
end
return R
