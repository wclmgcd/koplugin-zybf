-- Two independent, low-priority workers; one URL/size per job. A slow avatar
-- never holds a batch of successful avatars hostage. Cancellation isn't failure.
local Q={DELAY=0.15,FAILURE_TTL=5}
local function valid(a,q)
 return a.avatarQueue==q and require('readinknative/avatarpaint').same(a.view,q.owner)and require('readinknative/avatarpaint').top(a.view)
end
function Q.stop(a,drop,keepScene)
 local q=a.avatarQueue;a.avatarQueue=nil
 if q then
  local UI=require('ui/uimanager')
  if q.task then UI:unschedule(q.task)end
  if q.flush then UI:unschedule(q.flush)end
 end
 for _,slot in ipairs(a.avatarSlots or{})do slot.key=nil;slot.token=nil;slot.job:cancel()end
 if a.view and not keepScene then require('readinknative/avatarpaint').invalidate(a.view)end
 if drop then a.avatarFailures=nil end
end
function Q.guard(a)
 local q=a.avatarQueue;if q and not valid(a,q)then Q.stop(a)end
end
local function failures(a)
 local f=a.avatarFailures
 if not f or f.state~=a.state or f.vid~=tostring(a.client.data.vid)then f={state=a.state,vid=tostring(a.client.data.vid),rows={},count=0};a.avatarFailures=f end
 return f
end
local function flush(a,q)
 if q.flush then return end
 q.flush=function()
  q.flush=nil
  if a.avatarQueue~=q then return end
  if not valid(a,q)then Q.stop(a);return end
  local scene=a.view.avatarScene;local ready=q.ready;q.ready={}
  if scene and not scene.invalid then require('readinknative/avatarpaint').schedule(a.view,scene,ready)end
 end
 require('ui/uimanager'):scheduleIn(Q.DELAY,q.flush)
end
local pump
local function schedule(a,q)
 if q.task then return end
 q.task=function()q.task=nil;pump(a,q)end
 require('ui/uimanager'):scheduleIn(0.05,q.task)
end
pump=function(a,q)
 if a.avatarQueue~=q then return end
 if not valid(a,q)then Q.stop(a);return end
 local scene=a.view.avatarScene;if not scene or scene.invalid then return end
 local free=require('util').calcFreeMem();if not free or free<64*1024*1024 then return end
 local capacity=free>=128*1024*1024 and 2 or 1
 a.avatarSlots=a.avatarSlots or{}
 for i=1,2 do if not a.avatarSlots[i]then a.avatarSlots[i]={job=require('readinknative/inkjobs').new{NICE=15,TIMEOUT=8,MAX_RESULT=4096}}end end
 local A=require('readinknative/avatarcache');local f=failures(a)
 for i=1,capacity do
  local slot=a.avatarSlots[i]
  if not slot.key then
   local nextItem
   for _,r in ipairs(scene.rects)do
    local item=scene.wanted[r.key];local at=f.rows[r.key]
    local path,_,modified=A.find(q.owner.vid,r.url,r.size)
    local stale=modified and(os.time()<modified or os.time()-modified>=A.TTL)
    if not q.active[r.key]and(not at or os.time()<at or os.time()-at>=Q.FAILURE_TTL)and(not path or stale or not item.painted)then
     nextItem={key=r.key,url=r.url,size=r.size,force=path~=nil};break
    end
   end
   -- Only after current-page requests settle, warm at most two next-page
   -- avatars. They never paint this page and never delay its visible tiles.
   if not nextItem and not next(q.active)then
    for _,item in ipairs(scene.prefetch or{})do
     if not q.prefetched[item.key]and not scene.wanted[item.key]and not A.find(q.owner.vid,item.url,item.size)then
      q.prefetched[item.key]=true;nextItem={key=item.key,url=item.url,size=item.size};break
     end
    end
   end
   if nextItem then
    local item=nextItem;local token={};slot.key=item.key;slot.token=token;q.active[item.key]=true
    slot.job:run('',function()return A.prepare(q.owner.vid,item.url,item.size,item.force)end,function(ok,path)
     if slot.token~=token then return end
     slot.key=nil;q.active[item.key]=nil
     if not valid(a,q)then if a.avatarQueue==q then Q.stop(a)end;return end
     if ok and path then
      A.invalidate(a.view,q.owner.vid,item.url,item.size)
      f.rows[item.key]=nil
      local current=a.view.avatarScene
      if current and current.wanted[item.key]then current.wanted[item.key].painted=true;q.ready[item.key]=true;flush(a,q)end
     else
      if f.count>=128 then f.rows={};f.count=0 end
      if not f.rows[item.key]then f.count=f.count+1 end;f.rows[item.key]=os.time()
     end
     schedule(a,q)
    end,false)
   end
  end
 end
end
function Q.request(a,scene)
 if not scene or not scene.owner then return end
 local P=require('readinknative/avatarpaint');local q=a.avatarQueue
 if q and not valid(a,q)then Q.stop(a,false,true);q=nil end
 if not q then q={owner=scene.owner,active={},ready={},prefetched={}};a.avatarQueue=q end
 -- Drop requests that left the viewport; a reused process slot reaps its old
 -- child before forking again. Each worker writes a PID-specific temp file.
 local reserved={};for _,item in ipairs(scene.prefetch or{})do reserved[item.key]=true end
 for _,slot in ipairs(a.avatarSlots or{})do
  if slot.key and not scene.wanted[slot.key]and not reserved[slot.key]then q.active[slot.key]=nil;slot.key=nil;slot.token=nil;slot.job:cancel()end
 end
 if P.same(a.view,q.owner)then schedule(a,q)end
end
return Q
