-- Durable, account-local underline outbox and cloud snapshot. Network, source
-- matching and CRe searches run in a worker; the parent commits local state.
local S={INTERVAL=120}
local function persist(state)(state.flushAnnotations or state.flush)(state)end
local function clone(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=clone(x)end;return t end
function S.model(state)
 if type(state.annotationSync)~='table'or state.annotationSync.schema~=1 then state.annotationSync={schema=1,pending={},remote={},serial=0}end
 return state.annotationSync
end
local function bookCopy(b)return{bookId=tostring(b.bookId),title=b.title,version=b.version,format=b.format or'epub'}end
function S.queue(state,book,chapter,row)
 if row.kind~='highlight'or row.cloudId or book.localFile or book.article or not chapter then return end
 local m=S.model(state);if m.pending[row.id]then local op=m.pending[row.id];op.sourceRange=row.sourceRange or op.sourceRange;op.sourceVersion=row.sourceVersion or op.sourceVersion;return end
 m.pending[row.id]={id=row.id,book=bookCopy(book),chapter={chapterUid=tostring(chapter.chapterUid),title=chapter.title},quote=row.text,
  position=clone(row.position),sourceRange=row.sourceRange,sourceVersion=row.sourceVersion,action='add',phase='pending'}
end
function S.remove(state,row)
 if row.kind~='highlight'then return end
 local m=S.model(state);local op=m.pending[row.id]
 if not row.cloudId and not op then return end
 if not row.cloudId and op.phase=='pending'then m.pending[row.id]=nil;return end
 op=op or{id=row.id,book={bookId=row.bookId,version=row.bookVersion},chapter={chapterUid=row.chapterUid},quote=row.text,phase='pending'}
 op.action='delete';op.cloudId=row.cloudId or op.cloudId;m.pending[row.id]=op
end
local function receipt(state,value)
 local p=state.root..'/annotation-receipt.json';local f=assert(io.open(p..'.part','wb'));assert(f:write(require('rapidjson').encode(value)));assert(f:close());assert(os.rename(p..'.part',p))
end
local function readReceipt(state)
 local f=io.open(state.root..'/annotation-receipt.json','rb');if not f then return end
 local raw=f:read(32769);f:close();if #raw>32768 then return end
 local ok,v=pcall(require('rapidjson').decode,raw);if ok and type(v)=='table'then return v end
end
local function apply(state,op,r)
 if r.range then op.range=r.range end
 if r.cloudId then op.cloudId=r.cloudId end
 if r.done then
  if op.action=='delete'and r.action=='add'then op.phase='pending';return end
  if op.action=='add'then for _,row in ipairs(state.annotations)do if row.id==op.id then row.cloudId=op.cloudId;row.sourceRange=op.range;row.sourceVersion=tostring(op.book.version);row.bookVersion=op.book.version end end end
  S.model(state).pending[op.id]=nil
 elseif r.error then op.error=r.error;op.phase=r.unknown and'unknown'or'pending' end
end
function S.recover(state)
 local m=S.model(state);local f=m.flight;if not f then return true end
 local r=readReceipt(state);local op=m.pending[f.key]
 if r and r.serial==f.serial and r.key==f.key then
  if r.phase=='done'then if op then apply(state,op,r.result)end;m.flight=nil;return true end
  if r.phase=='sending'then if op then op.phase='unknown'end;m.flight=nil;return true end
 end
 if os.time()-f.created<240 then return false end
 if op then op.phase=f.previousPhase=='unknown'and'unknown'or'pending'end;m.flight=nil;return true
end
function S.match(rows,book,chapter,range)
 local found
 for _,r in ipairs(rows or{})do if r.type==1 and r.chapterUid==tostring(chapter.chapterUid)and r.range==range and
  (r.bookVersion==nil or tostring(r.bookVersion)==tostring(book.version))then
  if found then return nil,'ANNOTATION_SYNC_AMBIGUOUS'end;found=r
 end end
 return found
end
function S.map(op,client,path)
 local P=require('readinknative/readingposition');local index=P.source(path,op.book,op.chapter)
 if not index then require('readinknative/socialranges').load(client,op.book,op.chapter,path,{});index=P.source(path,op.book,op.chapter)end
 local range=P.range(index,op.quote)
 -- Known official ranges permit repeated words, but must roundtrip to this
 -- exact quote and version. Never turn a CRe pointer into a service offset.
 local known=op.sourceRange or op.range
 if known and tostring(op.sourceVersion or op.book.version)==tostring(op.book.version)then
  local files=require('readinknative/content').unpack((function()local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end)(),nil,nil,true)
  local raw=files[require('readinknative/socialranges').ENTRY]
  local src=raw and require('rapidjson').decode(raw)
  if src and require('readinknative/socialranges').valid(src,op.book,op.chapter)then
   local q=require('readinknative/socialranges').quote(src.text or src.html,known,nil,src.format=='txt')
   if q and P.compact(q)==P.compact(op.quote)then range=known end
  end
 end
 if not range and index and op.position then
  local candidates=P.ranges(index,op.quote)
  if candidates and #candidates>1 then
   local D=require('readinknative/document');local doc=D.open(path,600,700,26,nil,{},nil,true)
   local good,hits=pcall(doc.doc.findAllText,doc.doc,op.quote,false,0,2001,false,0x00FF)
   if good and hits and #hits==#candidates then
    for i,h in ipairs(hits)do if h.start==op.position.xpointer and h['end']==op.position.endXPointer then range=candidates[i];break end end
   end
   doc:close()
  end
 end
 assert(range,'ANNOTATION_SYNC_RANGE_UNMATCHED');return range
end
-- One mutation per worker. Uncertain POSTs are reconciled by full readback;
-- if no matching record is found they remain queued, never blindly resent.
function S.process(client,op,path,save)
 local api=require('readinknative/socialapi');local write=require('readinknative/annotationsyncapi')
 local result={action=op.action};local sending,mutated=false,false
 local ok,err=pcall(function()
  local snapshot=api.bookmarks(client,op.book);result.remote=snapshot
  if op.action=='add'or not op.cloudId then
   local range=op.range or S.map(op,client,assert(path,'CHAPTER_FILES_MISSING'));result.range=range;op.range=range
   local existing,ambiguous=S.match(snapshot.rows,op.book,op.chapter,range);assert(not ambiguous,ambiguous)
   if existing then result.cloudId=existing.bookmarkId
   elseif op.phase=='unknown'then error('ANNOTATION_SYNC_OUTCOME_UNKNOWN')
   elseif op.action=='delete'then result.done=true;return
   else
    save{phase='sending'};sending=true
    result.cloudId=write.add(client,op.book,op.chapter,range,op.quote);mutated=true
   end
  else result.cloudId=op.cloudId end
  if op.action=='delete'then
   local exists=false;for _,r in ipairs(snapshot.rows)do if r.bookmarkId==result.cloudId then exists=true end end
   if exists then save{phase='sending'};sending=true;write.remove(client,result.cloudId);mutated=true end
  end
  result.done=true
 end)
 if not ok then
  result.error=require('readinknative/errors').code(err)
  if sending then result.remote=nil end
  result.unknown=op.phase=='unknown'or sending and client.write_state~='unsent'and client.write_state~='rejected'and not tostring(err):find('API_',1,true)
 end
 if mutated then local good,fresh=pcall(api.bookmarks,client,op.book);result.remote=good and fresh or nil end
 return result
end
function S.remotePosition(document,row,index)
 local position=require('readinknative/socialranges').position(document,row.quote)
 if position then return position end
 local ranges=require('readinknative/readingposition').ranges(index,row.quote)
 if not ranges or #ranges<2 then return end
 local hits=document.doc:findAllText(row.quote,false,0,2001,false,0x00FF)
 if not hits or #hits~=#ranges then return end
 for i,range in ipairs(ranges)do if range==row.range then local h=hits[i];return{xpointer=h.start,endXPointer=h['end'],page=document.doc:getPageFromXPointer(h.start)}end end
end
function S.merge(state,book,data,mapped,chapter)
 local m=S.model(state);m.remote[tostring(book.bookId)]={rows=data.rows,at=os.time()}
 local byId={};for _,r in ipairs(data.rows)do byId[r.bookmarkId]=r end
 for i=#state.annotations,1,-1 do local row=state.annotations[i]
  if row.kind=='highlight'and row.bookId==tostring(book.bookId)and row.cloudId and not m.pending[row.id]and not byId[row.cloudId]then table.remove(state.annotations,i)end
 end
 for _,r in ipairs(mapped or{})do
  local exists,pending=false,false
  for _,row in ipairs(state.annotations)do if row.cloudId==r.bookmarkId then exists=true end end
  for _,op in pairs(m.pending)do if op.cloudId==r.bookmarkId or op.book.bookId==tostring(book.bookId)and op.chapter.chapterUid==r.chapterUid and((op.range or op.sourceRange)==r.range or require('readinknative/readingposition').compact(op.quote or'')==require('readinknative/readingposition').compact(r.quote or''))then pending=true end end
  if not exists and not pending then
   state.annotations[#state.annotations+1]={id='remote-underline:'..r.bookmarkId,cloudId=r.bookmarkId,bookId=tostring(book.bookId),bookVersion=book.version,
    chapterUid=r.chapterUid,chapterTitle=r.chapterTitle,kind='highlight',text=r.quote,position=r.position,sourceRange=r.range,sourceVersion=tostring(book.version),created=r.created or os.time(),updated=r.created or os.time()}
  end
 end
 -- An acknowledged local record takes precedence over an earlier imported
 -- view of the same server record; preserve the user's original XPointer.
 local originals={};for _,r in ipairs(state.annotations)do if r.cloudId and not r.id:match('^remote%-underline:')then originals[r.cloudId]=true end end
 for i=#state.annotations,1,-1 do local r=state.annotations[i];if r.cloudId and originals[r.cloudId]and r.id:match('^remote%-underline:')then table.remove(state.annotations,i)end end
end
local function enabled(a)
 return a.client and a.client.ready and a.client:ready()and not a.syncSigningOut and(a.annotationSyncEnabled or require('device'):isKindle())
end
function S.adopt(a)
 local books={};for _,b in ipairs(a.state.books or{})do books[tostring(b.bookId)]=b end
 for _,b in ipairs(a.state.readingHistory or{})do books[tostring(b.bookId)]=books[tostring(b.bookId)]or b end
 if a.book then books[tostring(a.book.bookId)]=a.book end
 for _,row in ipairs(a.state.annotations)do if row.kind=='highlight'and not row.cloudId then
  local b=books[row.bookId];local chapters=a.book==b and a.chapters or(a.state.catalogs or{})[row.bookId]
  if b then for _,ch in ipairs(chapters or{})do if tostring(ch.chapterUid)==row.chapterUid then S.queue(a.state,b,ch,row);break end end end
 end end
end
function S.request(a,manual)
 if not enabled(a)or a.closed or a.suspended or a.annotationSyncBusy then return end
 local state=a.state;local m=S.model(state);S.recover(state);if m.flight then return end
 S.adopt(a)
 local net=require('ui/network/manager');if not net:isWifiOn()or not net:isConnected()then if manual then a:message('当前离线，划线已保存在本机，联网后同步。')end;return end
 if a.syncBusy or(a.jobs and a.jobs.widget)or(a.chapterJobs and a.chapterJobs.widget)or(a.offlineRuntime and a.offlineRuntime.busy)then return end
 local op;for _,v in pairs(m.pending)do if not v.at or os.time()-v.at>=(manual and 0 or S.INTERVAL)then op=v;break end end
 local book=op and op.book or a.book
 if not book or book.localFile or book.article then if manual then a:message('请打开要同步划线的线上书籍后重试；待传划线会自动补传。')end;return end
 local recent=m.remote[tostring(book.bookId)];if not op and not manual and recent and os.time()-recent.at<S.INTERVAL then return end
 local current=a.book and tostring(a.book.bookId)==tostring(book.bookId)and a.document and a.chapter
 local chapter=current and a.chapter;local doc=current and a.document;local path=op and require('readinknative/cache').find(a.client.data.vid,op.book,op.chapter)
 local known={};for _,r in ipairs(state.annotations)do if r.cloudId and r.bookId==tostring(book.bookId)and tostring(r.sourceVersion)==tostring(book.version)and chapter and r.chapterUid==tostring(chapter.chapterUid)then known[r.cloudId]=true end end
 local snapshot=op and clone(op);m.serial=m.serial+1;local serial=m.serial
 if op then op.at=os.time();if op.phase~='unknown'then op.phase='working'end;m.flight={key=op.id,serial=serial,created=os.time(),previousPhase=snapshot.phase};persist(state)end
 local data,vid=a.client.data,tostring(a.client.data.vid);a.annotationSyncBusy=true
 a.annotationSyncJobs=a.annotationSyncJobs or require('readinknative/jobs').new()
 a.annotationSyncJobs:run('',function()
  local c=require('readinknative/client'):new(data);local result
  local function save(v)if v.phase=='sending'then assert(os.time()-m.flight.created<=180,'ANNOTATION_SYNC_WORK_EXPIRED')end;v.serial=serial;v.key=snapshot and snapshot.id;receipt(state,v)end
  if snapshot then
   save{phase='preparing'};result=S.process(c,snapshot,path,save)
   save{phase='done',result={action=result.action,range=result.range,cloudId=result.cloudId,done=result.done,error=result.error,unknown=result.unknown}}
  else local ok,r=pcall(require('readinknative/socialapi').bookmarks,c,book);result={remote=ok and r or nil,error=not ok and require('readinknative/errors').code(r)or nil}end
  local mapped={}
  if result.remote and doc and chapter then
   local ranges={};for _,r in ipairs(result.remote.rows)do if r.type==1 and not known[r.bookmarkId]and r.chapterUid==tostring(chapter.chapterUid)and tostring(r.bookVersion or book.version)==tostring(book.version)then ranges[#ranges+1]=clone(r) end end
   local ok=pcall(require('readinknative/socialranges').load,c,book,chapter,doc.path,ranges)
   if ok then local index=require('readinknative/readingposition').source(doc.path,book,chapter);for _,r in ipairs(ranges)do r.position=S.remotePosition(doc,r,index);if r.position then mapped[#mapped+1]=r end end end
  end
  result.mapped=mapped;return result,c.data
 end,function(ok,result,session)
  a.annotationSyncBusy=nil
  if a.closed or a.state~=state or tostring(a.client.data.vid)~=vid then return end
  if session and a.client.data==data then a.client.data=session;a.client.session.data=session;a.client:commit()end
  if op then S.recover(state)end
  if ok then
   if result.remote then S.merge(state,book,result.remote,a.document==doc and a.chapter==chapter and result.mapped or nil,chapter)end
   m.error=result.error;m.lastSuccess=not result.error and os.time()or m.lastSuccess
  else m.error='WORKER_FAILED'end
  persist(state);if not m.error and next(m.pending)then S.start(a,true)end;if a.social and a.social.bookId==tostring(book.bookId)then a.social.mineAt=nil;if ok and result.remote then a.social.bookmarks=result.remote end end
  if not a.suspended then a:draw();if manual then a:message(m.error and'划线同步未完成，记录已保留，可稍后重试。'or'划线已与云端同步。')end end
 end,false)
end
function S.start(a,soon)
 if not enabled(a)or a.closed or a.suspended then return end
 local UI=require('ui/uimanager');if a.annotationSyncTask then UI:unschedule(a.annotationSyncTask)end
 a.annotationSyncTask=function()a.annotationSyncTask=nil;S.request(a);S.start(a)end
 UI:scheduleIn(soon and 1 or S.INTERVAL,a.annotationSyncTask)
end
function S.stop(a)
 if a.annotationSyncTask then require('ui/uimanager'):unschedule(a.annotationSyncTask);a.annotationSyncTask=nil end
 if a.annotationSyncJobs then a.annotationSyncJobs:cancel()end;a.annotationSyncBusy=nil
end
function S.changed(a)S.start(a,true)end
function S.status(a)
 local m=S.model(a.state);local n=0;for _ in pairs(m.pending)do n=n+1 end
 if m.error=='ANNOTATION_SYNC_OUTCOME_UNKNOWN'then return'上次上传结果待核对，划线保留在本机'end
 if m.error=='ANNOTATION_SYNC_RANGE_UNMATCHED'then return'有划线位置未能匹配，已保留本机记录'end
 if n>0 then return'待同步 '..n..' 条划线；联网后补传'end
 return m.lastSuccess and'上次同步 '..os.date('%m-%d %H:%M',m.lastSuccess)or'划线自动同步；本地书籍和想法正文不上传'
end
return S
