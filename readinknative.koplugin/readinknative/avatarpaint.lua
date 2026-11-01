-- Avatar-only paints use the host's per-widget dirty hint. Any ordinary dirty
-- request replaces that hint and takes the original full-page paint path.
local P={}
function P.top(v)
 local UI=require('ui/uimanager')
 return not UI.getTopmostVisibleWidget or UI:getTopmostVisibleWidget()==v
end
function P.owner(v)
 local a=v.app;local r=a.social and a.social.route
 if a.mode~='social'or not r or a.closed or a.suspended or a.exiting or a.activeInput then return end
 return{state=a.state,vid=tostring(a.client.data.vid),book=a.book,route=r,page=r.page,tab=r.tab,expanded=r.expandedComment,
  groups=r.groups,data=r.data,w=v.dimen.w,h=v.dimen.h,scale=v.fontScale,night=require('device').screen.night_mode,
  dither=require('device').screen.sw_dithering,rotation=require('device').screen.bb and require('device').screen.bb.getRotation and require('device').screen.bb:getRotation()}
end
function P.same(v,o)
 local n=P.owner(v);if not n or not o then return false end
 for k,x in pairs(n)do if o[k]~=x then return false end end
 for k,x in pairs(o)do if n[k]~=x then return false end end
 return true
end
function P.invalidate(v)
 local UI=require('ui/uimanager');local patch=v.avatarPatch
 if patch and UI._dirty and UI._dirty[v]==patch then UI._dirty[v]=true;UI:setDirty(nil,'ui')end
 if v.avatarScene then v.avatarScene.invalid=true end
 v.avatarPatch=nil
end
function P.begin(v,target)
 if target==require('device').screen.bb then
  P.invalidate(v);v.avatarScene=nil
  v.avatarBuilding=v.app.mode=='social'and{rects={},wanted={},prefetch={}}or nil
 else v.avatarBuilding=nil end
end
function P.record(v,user,size,x,y,top,bottom,painted)
 local b=v.avatarBuilding;if not b or not user or #b.rects>=64 then return end
 local A=require('readinknative/avatarcache');local key,url=A.identity(v.app.client.data.vid,user.avatar,size);if not key then return end
 local left,right=math.max(0,x),math.min(v.dimen.w,x+size);local first,last=math.max(top,0,y),math.min(bottom,v.dimen.h,y+size)
 if right<=left or last<=first then return end
 local item={key=key,url=url,size=size,x=x,y=y,left=left,top=first,w=right-left,h=last-first}
 b.rects[#b.rects+1]=item;b.wanted[key]={key=key,url=url,size=size,painted=painted or false}
end
function P.reserve(v,user,size)
 local b=v.avatarBuilding;if not b or not user or #b.prefetch>=2 then return end
 local key,url=require('readinknative/avatarcache').identity(v.app.client.data.vid,user.avatar,size);if not key or b.wanted[key]then return end
 for _,item in ipairs(b.prefetch)do if item.key==key then return end end
 b.prefetch[#b.prefetch+1]={key=key,url=url,size=size}
end
function P.finish(v,target)
 if target~=require('device').screen.bb then return end
 local b=v.avatarBuilding;v.avatarBuilding=nil
 if not b or not P.top(v)then v.avatarScene=nil;return end
 b.owner=P.owner(v);if not b.owner then return end
 b.target=target;v.avatarScene=b
 require('readinknative/avatarqueue').request(v.app,b)
end
function P.schedule(v,scene,keys)
 if v.avatarScene~=scene or scene.invalid or not P.same(v,scene.owner)or not P.top(v)then return end
 local UI=require('ui/uimanager')
 if type(UI._dirty)~='table'then v:refresh();return end
 local pending=v.avatarPatch
 if UI._dirty[v]then
  if pending and UI._dirty[v]==pending and pending.scene==scene then
   for key in pairs(keys)do pending.keys[key]=true end;keys=pending.keys
  else return end -- an ordinary full paint will consume all cached avatars
 end
 local x,y,right,bottom=v.dimen.w,v.dimen.h,0,0
 for _,r in ipairs(scene.rects)do if keys[r.key]then x=math.min(x,r.left);y=math.min(y,r.top);right=math.max(right,r.left+r.w);bottom=math.max(bottom,r.top+r.h)end end
 if right<=x or bottom<=y then return end
 local patch=pending or{scene=scene,keys=keys};v.avatarPatch=patch
 UI:setDirty(v,'ui',require('ui/geometry'):new{x=x,y=y,w=right-x,h=bottom-y})
 if UI._dirty[v]==true then UI._dirty[v]=patch else v.avatarPatch=nil;v:refresh()end
end
function P.try(v,target,hint)
 local patch=v.avatarPatch
 if not patch or target~=require('device').screen.bb then return false end
 v.avatarPatch=nil
 local scene=patch.scene
 if hint~=patch or v.avatarScene~=scene or scene.invalid or scene.target~=target or not P.same(v,scene.owner)or not P.top(v)then
  require('ui/uimanager'):setDirty(nil,'ui');return false
 end
 -- Decode/cache all small tiles before touching the mapped buffer. No clear,
 -- layout, text widget, hit map, or route state is changed by this path.
 local staged,owned={},{};local A=require('readinknative/avatarcache');local bytes=0
 local ok=pcall(function()
  for _,r in ipairs(scene.rects)do if patch.keys[r.key]then
   local image=owned[r.key]
   if not image then
    local cached=A.load(v,scene.owner.vid,r.url,r.size)
    assert(cached,'AVATAR_TILE_MISSING')
    if cached then
     bytes=bytes+A.bytes(cached);assert(bytes<=2*1024*1024,'AVATAR_PATCH_LIMIT')
     image=cached:copy();owned[r.key]=image
    end
   end
   if image then staged[#staged+1]={r=r,image=image}end
  end end
  for _,item in ipairs(staged)do
   local r,b=item.r,item.image
   target:blitFrom(b,r.left,r.top,r.left-r.x,r.top-r.y,r.w,r.h)
   local surface=v.socialPaintSurface
   if surface and surface~=target then surface:blitFrom(b,r.left,r.top,r.left-r.x,r.top-r.y,r.w,r.h)end
  end
 end)
 for _,image in pairs(owned)do pcall(image.free,image)end
 if not ok then require('ui/uimanager'):setDirty(nil,'ui');return false end

 v.avatarPatchSerial=(v.avatarPatchSerial or 0)+1
 return true
end
return P
