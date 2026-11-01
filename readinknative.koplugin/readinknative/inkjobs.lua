-- Short reader-only jobs using KOReader's fork/pipe APIs. Poll while active,
-- deliver before the optional file-only cache tail. New visible work cancels
-- that repeatable tail; collect it before another writer can start. No modal
-- widget, core patches, or synchronous UI fallback.
local J={INTERVAL=0.025,TIMEOUT=90,MAX_RESULT=16*1024*1024,READ_SLICE=256*1024};J.__index=J
local function closePipe(a)
 if a.fd then require('ffi').C.close(a.fd);a.fd=nil end
 a.chunks=nil
end
local function terminate(a)
 local F=require('ffi/util')
 if not F.isSubProcessDone(a.pid)then
  -- Cancellation may run before the child reaches setpgid(). A group-only
  -- kill then misses it; kill the known, unreaped child as well. No yield
  -- occurs between checking ownership and sending these signals.
  local C=require('ffi').C;local group=C.kill(-a.pid,9);local child=C.kill(a.pid,9)
  if group~=0 and child==0 then require('logger').info('ReadInk reader worker cancelled before process group was ready')end
 end
 closePipe(a)
end
local function arm(a,interval)
 if not a.poll then return end
 local UI=require('ui/uimanager');UI:unschedule(a.poll);UI:scheduleIn(interval,a.poll)
end
function J.new(options)local v={epoch=0};for k,x in pairs(options or{})do v[k]=x end;return setmetatable(v,J)end
function J:cancel()
 self.epoch=self.epoch+1;self.queued=nil;self.widget=nil
 local a=self.active
 if a then a.killed=true;terminate(a);arm(a,self.INTERVAL)end
end
function J:run(label,task,done,target,cancelled,after)
 self.epoch=self.epoch+1
 local epoch=self.epoch;local widget={};widget.dismiss_callback=function()self:cancel();if cancelled then cancelled()end end
 self.widget=widget;self.queued={epoch=epoch,task=task,done=done,after=after,widget=widget}
 -- A cancelled old process is collected before the next fork, so two cache
 -- tails cannot write the same atomic .part file concurrently.
 if self.active then self.active.killed=true;terminate(self.active)end
 -- Re-arm collection when a UI loop was torn down/restarted between jobs.
 -- A killed writer must be reaped before a queued replacement can fork.
 if self.active and self.active.poll then local UI=require('ui/uimanager');UI:unschedule(self.active.poll);UI:scheduleIn(self.INTERVAL,self.active.poll)end
 self:dispatch()
end
function J:dispatch()
 if self.active or not self.queued then return end
 local q=self.queued;self.queued=nil
 local F=require('ffi/util');local UI=require('ui/uimanager');local codec=require('string.buffer');local clock=require('socket')
 local a={epoch=q.epoch,widget=q.widget,done=q.done,started=clock.gettime()};self.active=a
 local pid,fd=F.runInSubProcess(function(_,out)
  pcall(function()local ffi=require('ffi');pcall(ffi.cdef,'int nice(int inc);');ffi.C.nice(self.NICE or 5)end)
  require('readinknative/imagefetch').enabled=true
  local ok,value,session=pcall(q.task)
  local result=ok and{ok=true,value=value,session=session}or{ok=false,error=tostring(value)}
  local encoded,data=pcall(codec.encode,result)
  data=encoded and data or''
  -- Length framing lets the UI consume bounded chunks without waiting for EOF.
  F.writeToFD(out,string.format('%010d',#data)..data,true)
  -- The pipe is now closed: the parent can paint while this process saves.
  if ok and q.after then pcall(q.after,value,session)end
 end,true)
 if not pid then self.active=nil;if self.epoch==a.epoch then self.widget=nil;a.done(false,'WORKER_FAILED')end;self:dispatch();return end
 a.pid=pid;a.fd=fd
 local function notify(ok,value,session)
  if a.delivered then return end;a.delivered=true
  if self.epoch==a.epoch and not a.killed then
   if self.widget==a.widget then self.widget=nil end
   a.done(ok,value,session)
  end
 end
 a.poll=function()
  if self.active~=a then return end
  local finished=F.isSubProcessDone(a.pid)
  if a.killed then
   if finished then self.active=nil;self:dispatch();return end
   terminate(a)
  elseif not a.delivered and a.fd then
   local available=F.getNonBlockingReadSize(a.fd)
   if available and available>0 then
    -- Read only the bytes already in the pipe, with a finite per-tick budget.
    -- readAllFromFD waits for EOF and can freeze touch while a child stalls.
    local ffi=require('ffi');local size=math.min(available,self.READ_SLICE)
    local bytes=ffi.new('char[?]',size);local count=tonumber(ffi.C.read(a.fd,bytes,size))
    if count and count>0 then
     a.chunks=a.chunks or{};a.chunks[#a.chunks+1]=ffi.string(bytes,count);a.received=(a.received or 0)+count
     if not a.expected and a.received>=10 then
      local data=table.concat(a.chunks);a.chunks={data}
      local prefix=data:sub(1,10)
      a.expected=prefix:match('^%d%d%d%d%d%d%d%d%d%d$')and tonumber(prefix)
      if not a.expected or a.expected>self.MAX_RESULT then
       notify(false,'WORKER_RESULT_SIZE');a.killed=true;terminate(a)
      end
     end
     if not a.killed and a.expected and a.received>=a.expected+10 then
      local data=table.concat(a.chunks);local exact=#data==a.expected+10;closePipe(a)
      local ok,result=pcall(codec.decode,exact and data:sub(11)or'')
      if ok and type(result)=='table'and type(result.ok)=='boolean'then
       if result.ok then notify(true,result.value,result.session)else notify(false,result.error)end
      else notify(false,'WORKER_FAILED')end
     end
    end
   elseif finished then
    closePipe(a);notify(false,'WORKER_FAILED')
   end
  end
  if finished and(a.killed or a.delivered)then
   closePipe(a);if self.active==a then self.active=nil end
   self:dispatch();return
  end
  if not a.killed and clock.gettime()-a.started>self.TIMEOUT then
   notify(false,'WORKER_TIMEOUT');a.killed=true;terminate(a)
  end
  UI:scheduleIn(self.INTERVAL,a.poll)
 end
 UI:scheduleIn(self.INTERVAL,a.poll)
end
return J
