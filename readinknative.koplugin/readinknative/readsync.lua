-- Durable account-scoped synchronization. Only newly observed foreground time
-- is uploaded; legacy local totals are never retrospectively reported.
local S={INTERVAL=300}
local function model(state)
 if type(state.readSync)~='table'or state.readSync.schema~=1 then state.readSync={schema=1,serial=0,pending={},remote={}}end
 return state.readSync
end
local function flush(state)(state.flushProgress or state.flush)(state)end
local function enabled(a)
 return not a.syncSigningOut and a.client and type(a.client.ready)=='function'and a.client:ready()and(a.syncEnabled or require('device'):isKindle())and require('readinknative/preferences').normalize(a.state.preferences).syncReading
end
local function bookCopy(b)return{bookId=tostring(b.bookId),version=b.version or 0,title=b.title,format=b.format,otherType=b.otherType,pdfText=b._pdfText}end
function S.queueKey(book)
 -- Converted PDF and EPUB views of one cloud ID keep distinct progress/time.
 return(type(book.format)=='string'and book.format:lower()=='pdf'and'pdf:'or'')..tostring(book.bookId)
end
local function row(state,book)
 local m=model(state);local id=S.queueKey(book);local r=m.pending[id]
 if not r then r={book=bookCopy(book),seconds=0,hours={},rev=0};m.pending[id]=r end
 return r
end
local function zone(wall)
 local z=os.date('%z',wall);return z and z:match('^[+-]%d%d%d%d$')and z:sub(1,3)..':'..z:sub(4)or'+00:00'
end
function S.record(a,previous,delta,wall)
 if not enabled(a)or not previous.book or previous.book.localFile or a.syncApplying then return end
 local r=row(a.state,previous.book)
 if previous.wall and math.abs((wall-previous.wall)-delta)>5 then r.risk=require('bit').bor(r.risk or 0,1)end
 for t=wall-delta,wall-1 do
  local start=math.floor(t/3600)*3600;local tz=zone(t);local h=r.hours[#r.hours]
  if not h or h.startOfHour~=start or h.timeZone~=tz then
   h=nil;for _,existing in ipairs(r.hours)do if existing.startOfHour==start and existing.timeZone==tz then h=existing;break end end
   if not h then h={startOfHour=start,timeZone=tz,readingTime=0};r.hours[#r.hours+1]=h end
  end
  h.readingTime=h.readingTime+1
 end
 r.seconds=r.seconds+delta;r.zone=zone(wall);r.rev=r.rev+1
end
function S.capture(a,updated)
 S.cancelCapture(a)
 if a.pdfSync then return a.pdfSync:capture(updated)end
 if not enabled(a)or a.syncApplying or not a.document or not a.chapter or not a.book or a.book.localFile then return end
 local pointer=a.document:position().xpointer;local previous=a.syncLastPosition
 if updated==nil and previous and previous.state==a.state and previous.bookId==tostring(a.book.bookId)and previous.uid==tostring(a.chapter.chapterUid)and previous.xpointer==pointer then updated=previous.updated end
 updated=updated or os.time();a.syncLastPosition={state=a.state,bookId=tostring(a.book.bookId),uid=tostring(a.chapter.chapterUid),xpointer=pointer,updated=updated}
 local r=row(a.state,a.book);local ok,visible,node=pcall(require('readinknative/readingposition').visible,a.document)
 local page,total=require('readinknative/pagination').position(a)
 local percent=type(page)=='number'and type(total)=='number'and total>0 and math.min(99,math.max(0,math.floor(100*page/total)))or nil
 r.book=bookCopy(a.book);r.rev=r.rev+1
 r.position={chapterUid=tostring(a.chapter.chapterUid),chapterIdx=a.chapter.chapterIdx,path=a.document.path,
  visible=ok and type(visible)=='string'and require('util').fixUtf8(visible:sub(1,4096),'')or nil,node=type(node)=='string'and #node<=8192 and node or nil,updated=updated or os.time(),xpointer=pointer,
  percent=percent,chapterProgress=math.min(100,math.floor(100*a.document:page()/a.document:count()))}
 r.zone=zone(os.time());r.mappingUnavailable=nil
end
function S.capturePdf(a,page,pages,updated)
 if not enabled(a)or a.syncApplying or not a.book or a.book.localFile then return end
 local position=require('readinknative/readsyncapi').pdfPosition(a.book,{pdf=true,page=page,pages=pages,updated=updated or 0,pdfEpoch=a.pdfEpoch})
 local r=row(a.state,a.book);r.book=bookCopy(a.book);r.position=position;r.rev=r.rev+1;r.zone=zone(os.time());r.mappingUnavailable=nil
 return position
end
-- Coalesce page turns; the durable local pointer is saved immediately by the
-- controller. Text extraction for cloud coordinates happens after painting.
function S.cancelCapture(a)
 if a.syncCaptureTask then require('ui/uimanager'):unschedule(a.syncCaptureTask);a.syncCaptureTask=nil end
end
function S.defer(a)
 S.cancelCapture(a)
 if not enabled(a)or a.syncApplying or not a.document then return end
 local d,state,chapter,path,page=a.document,a.state,a.chapter,a.document.path,a.document:page()
 a.syncCaptureTask=function()
  a.syncCaptureTask=nil
  if not a.closed and not a.suspended and a.state==state and a.document==d and d.doc and d.path==path and a.chapter==chapter and d:page()==page then S.capture(a)end
 end
 require('ui/uimanager'):scheduleIn(0.2,a.syncCaptureTask)
end
local function receipt(state,value)
 local store=require('luasettings'):open(state.root..'/sync-receipt.lua');store:saveSetting('receipt',value);store:flush()
end
local function readReceipt(state)
 return require('luasettings'):open(state.root..'/sync-receipt.lua'):readSetting('receipt')
end
local function subtract(r,snapshot)
 r.seconds=math.max(0,r.seconds-snapshot.seconds)
 for _,old in ipairs(snapshot.hours)do for _,h in ipairs(r.hours)do if h.startOfHour==old.startOfHour and h.timeZone==old.timeZone then h.readingTime=math.max(0,h.readingTime-old.readingTime);break end end end
 for i=#r.hours,1,-1 do if r.hours[i].readingTime==0 then table.remove(r.hours,i)end end
 if r.rev==snapshot.rev then r.position=nil end
end
function S.recover(state)
 local m=model(state);local flight=m.flight;if not flight then return end
 local value=readReceipt(state)
 if value and value.id==flight.id and value.phase=='ack'then
  require('readinknative/shelforder').ack(state,flight.bookId,flight.shelfSerial,value.shelfServerTime)
  local key=flight.queueKey or flight.bookId
  local r=m.pending[key];if r then subtract(r,flight.snapshot);if r.seconds==0 and not r.position then m.pending[key]=nil end end
  m.flight=nil;m.lastSuccess=value.at;m.error=nil
 elseif value and value.id==flight.id and value.phase=='retry'then m.flight=nil
 elseif not value or value.id~=flight.id or value.phase=='preparing'then
  -- A reopened UI can coexist briefly with the previous bounded worker. Its
  -- pre-send deadline expires before this reservation can be retried.
  if os.time()-(flight.created or 0)<300 then return false end;m.flight=nil
 else m.error='SYNC_OUTCOME_UNKNOWN';return false end
 return true
end
local function copy(t)return require('rapidjson').decode(require('rapidjson').encode(t))end
local function connected()
 local n=require('ui/network/manager');return n:isWifiOn()and n:isConnected()
end
local function applyRemote(a,remote,book,position)
 if type(book.format)=='string'and book.format:lower()=='pdf'then
  if a.pdfSync then a.pdfSync:offerRemote(remote,book,position)end;return
 end
 if not remote or(remote.appId and remote.appId==a.client.data.deviceId)or not a.book or tostring(a.book.bookId)~=tostring(book.bookId)or(a.mode~='reader'and a.mode~='catalog')then return end
 if remote.version and tostring(remote.version)~=tostring(a.book.version or 0)then return end
 if not position or remote.updated<=position.updated or(remote.chapterUid==position.chapterUid and remote.chapterOffset==position.chapterOffset)then return end
 local doc=a.document;local state=a.state;local owner=a.book;local m=model(state);local key=tostring(book.bookId)..':'..remote.updated
 if a.syncPrompt==key then return end;a.syncPrompt=key
 local function jump()
  if a.closed or a.suspended or a.state~=state or a.book~=owner or a.document~=doc then return end
  local target,index
  for i,ch in ipairs(a.chapters or{})do if tostring(ch.chapterUid)==remote.chapterUid then target,index=ch,i;break end end
  if not target then a:message('云端章节不在当前目录，请更新目录后重试。');return end
  a:selectChapter(target,index,{cloudOffset=remote.chapterOffset})
 end
 local UI=require('ui/uimanager')
 UI:show(require('ui/widget/confirmbox'):new{text='其他设备的阅读进度已更新，是否跳转到该位置？',ok_text='跳转',cancel_text='留在这里',ok_callback=jump,
  cancel_callback=function()if not a.closed and a.state==state and a.document==doc then S.capture(a);flush(state)end end})
end
function S.request(a,manual,force)
 if a.syncCaptureTask then S.capture(a)end
 if not enabled(a)or a.closed or a.suspended or a.syncBusy or a.annotationSyncBusy then return end
 local clock=require('ui/time');local now=clock.monotonic()
 if not manual and not force and a.syncAttempt and now-a.syncAttempt<clock.s(S.INTERVAL)then return end
 local m=model(a.state);if S.recover(a.state)then flush(a.state)end
 if m.flight then if manual then a:message('上次同步的服务器结果尚未确认，记录已保留，暂不重复上报时长。')end;return end
 if not connected()then if manual then a:message('当前离线，阅读时长和进度已保存在本机，联网后同步。')end;return end
 if(a.jobs and a.jobs.widget)or(a.chapterJobs and a.chapterJobs.widget)or(a.offlineRuntime and a.offlineRuntime.busy)then return end
 local id,r
 if a.book and not a.book.localFile then id=S.queueKey(a.book);r=m.pending[id]end
 if not r then id,r=next(m.pending)end
 if not r then if manual then a:message('没有待同步的阅读记录。')end;return end
 if r.seconds==0 and not r.position then m.pending[id]=nil;return end
 local snapshot=copy(r);m.serial=m.serial+1
 local bookId=tostring(snapshot.book.bookId)
 local flight={id=tostring(os.time())..'-'..m.serial,created=os.time(),bookId=bookId,queueKey=id,snapshot=snapshot,shelfSerial=require('readinknative/shelforder').serial(a.state,bookId)};m.flight=flight;flush(a.state)
 local state,vid,data=a.state,a.client.data.vid,a.client.data;local config=a.syncConfig;local wasDocument=a.document
 a.syncAttempt=now;a.syncBusy=true;a.syncJobs=a.syncJobs or require('readinknative/jobs').new()
 a.syncJobs:run('',function()
  local A=require('readinknative/readsyncapi');local c=require('readinknative/client'):new(data)
  local phase='preparing';receipt(state,{id=flight.id,phase=phase})
  local result={};local ok,error=pcall(function()
   local remote,stamp=A.pull(c,snapshot.book);result.remote=remote
   local position=snapshot.position;local mapped
   if position and position.pdf==true then
    mapped=A.pdfPosition(snapshot.book,position);result.mapped=mapped
   elseif position and position.visible then
    local mappedOk,offset=pcall(require('readinknative/readingposition').toCloud,position.path,snapshot.book,{chapterUid=position.chapterUid},position.visible,position.node)
    if not mappedOk then offset=nil end
    if not offset then
     pcall(require('readinknative/socialranges').load,c,snapshot.book,{chapterUid=position.chapterUid},position.path,{})
     mappedOk,offset=pcall(require('readinknative/readingposition').toCloud,position.path,snapshot.book,{chapterUid=position.chapterUid},position.visible,position.node)
     if not mappedOk then offset=nil end
    end
    if offset then
     mapped={chapterUid=position.chapterUid,chapterIdx=position.chapterIdx,chapterOffset=offset,percent=position.percent,currentPercent=position.percent,chapterProgress=position.chapterProgress,updated=position.updated}
     result.mapped=mapped
    end
   end
   if remote and remote.version and tostring(remote.version)~=tostring(snapshot.book.version or 0)then mapped=nil;result.mapped=nil;result.versionChanged=true end
   if remote and position and remote.updated>position.updated and(not remote.appId or remote.appId~=c.data.deviceId)then mapped=nil;result.conflict=true end
   if not mapped and snapshot.seconds==0 then result.noWrite=true;return end
   result.config=A.config(c,config)
   local body=A.body(c,snapshot,mapped,result.config.guest,stamp or os.time(),require('readinknative/auth/wire').random1000())
   assert(os.time()-flight.created<=240,'SYNC_WORK_EXPIRED')
   phase='sending';receipt(state,{id=flight.id,phase=phase,shelfServerTime=body.timestamp})
   A.send(c,body);phase='ack';receipt(state,{id=flight.id,phase=phase,at=os.time(),shelfServerTime=body.timestamp});result.sent=true
  end)
  if not ok then
   local code=require('readinknative/errors').code(error)
   local known=phase~='sending'or c.write_state=='unsent'or c.write_state=='rejected'or tostring(error):find('API_',1,true)
   phase=known and'retry'or'unknown'
   receipt(state,{id=flight.id,phase=phase,error=code});result.error=code;result.unknown=phase=='unknown'
  elseif result.noWrite then receipt(state,{id=flight.id,phase='retry'})end
  return result,c.data
 end,function(ok,result,session)
  a.syncBusy=nil
  if a.closed then return end
  if a.state~=state or a.client.data.vid~=vid then return end
  if session and a.client.data==data then a.client.data=session;a.client.session.data=session;a.client:commit()end
  if not ok then m.error='SYNC_WORKER_FAILED';flush(state);return end
  if result.sent then S.recover(state)else
   if result.unknown then m.error='SYNC_OUTCOME_UNKNOWN'else m.flight=nil;m.error=result.error end
   if result.noWrite and r.rev==snapshot.rev then r.position=nil;if r.seconds==0 then m.pending[id]=nil end end
  end
  if result.remote then m.remote[id]=result.remote end
  if result.config then a.syncConfig=result.config end
  if result.sent then require('readinknative/shelfmodel').invalidate(a);require('readinknative/shelfmodel').ensure(a);require('readinknative/readprofile').changed(a)end
  flush(state)
  if not a.closed and not a.suspended and a.document==wasDocument then
   if result.conflict then applyRemote(a,result.remote,snapshot.book,result.mapped or snapshot.position)
   elseif manual then
    if result.sent then a:message(result.mapped and'阅读时长和进度已同步。'or'阅读时长已同步；当前章内位置未能精确匹配，未上传。')
    else a:message(result.error and'同步失败，记录已保留，稍后重试。'or'云端进度已检查。')end
   end
  end
 end,false)
end
function S.start(a)
 if not enabled(a)then return end
 local UI=require('ui/uimanager');if a.syncTask then UI:unschedule(a.syncTask)end
 if a.closed or a.suspended then return end
 a.syncTask=a.syncTask or function()S.request(a);S.start(a)end;UI:scheduleIn(S.INTERVAL,a.syncTask)
end
function S.open(a,previous,navigated)
 if a.syncApplying then return end
 S.capture(a,navigated and os.time()or previous and previous.updated or 0);S.start(a)
 if enabled(a)then local owner=a.document;require('ui/uimanager'):scheduleIn(0.5,function()if not a.closed and not a.suspended and a.document==owner then S.request(a,false,true)end end)end
end
function S.stop(a)
 S.cancelCapture(a)
 if a.syncTask then require('ui/uimanager'):unschedule(a.syncTask)end
 -- A bounded in-flight report may finish and write its own receipt while the
 -- UI leaves the reader. Killing it would make acknowledgement less reliable.
end
function S.status(a)
 local m=model(a.state)
 if not require('readinknative/preferences').normalize(a.state.preferences).syncReading then return'已关闭；待传记录保留在本机'end
 if m.error=='SYNC_OUTCOME_UNKNOWN'then return'上次上报结果未确认，记录已保留'end
 local seconds=0;for _,r in pairs(m.pending)do seconds=seconds+(r.seconds or 0)end
 if seconds>0 then return'待同步 '..seconds..' 秒；联网后补传'end
 return m.lastSuccess and'上次同步 '..os.date('%m-%d %H:%M',m.lastSuccess)or'联网后同步；离线记录保留至补传'
end
function S.cancel(a)
 S.stop(a);if a.syncJobs then a.syncJobs:cancel()end;a.syncBusy=nil;S.recover(a.state);flush(a.state)
end
function S.manual(a)
 if not a.book or a.book.localFile then return end
 local saved=type(a.state.position)=='function'and a.state:position(a.book,a.chapter);S.capture(a)
 local r=row(a.state,a.book);if not r.position then r.position={updated=saved and saved.updated or 0}end
 S.request(a,true);S.start(a)
end
return S
