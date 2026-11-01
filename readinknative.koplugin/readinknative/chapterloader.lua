-- Prepare online chapter layout in a cancellable worker, then restore CRe's
-- disk DOM cache in the UI. No network and no reading-statistics side effects.
local L={engineCacheKnown={}}
local function remember(path,value)
 if not L.engineCacheKnown[path]then
  if(L.engineCacheCount or 0)>=128 then L.engineCacheKnown={};L.engineCacheCount=0 end
  L.engineCacheCount=(L.engineCacheCount or 0)+1
 end
 L.engineCacheKnown[path]=value
end
local function stamp(path)return require('readinknative/pagination').fileStamp(path)end
function L.spec(vid,book,path,w,h,font,value)
 local F=require('readinknative/format');local format=F.normalize(value,font)
 local parts={'reader-cache-v2',tostring(vid),tostring(book.bookId),tostring(book.version or 0),path,w,h,
  require('datastorage'):getDataDir(),require('version'):getCurrentRevision()or'',tostring(require('document/credocument').default_font),
  stamp('./data/epub.css')or''}
 if book.article then parts[#parts+1]='article-layout-'..require('readinknative/articlecontent').LAYOUT end
 parts[#parts+1]=F.signature(format)
 for _,name in ipairs{'fallback_font','additional_fallback_fonts','cre_adjusted_fallback_font_sizes','cre_monospace_scaling'}do
  local value=G_reader_settings and G_reader_settings:readSetting(name)
  -- Settings may be arrays/tables. Pointer strings change across controllers.
  parts[#parts+1]=type(value)=='table'and require('rapidjson').encode(value,{sort_keys=true})or tostring(value)
 end
 return{key=require('ffi/sha2').sha256(table.concat(parts,'|')),path=path,w=w,h=h,format=format,vid=vid,book={bookId=book.bookId,version=book.version,article=book.article}}
end
local function spec(a,path)
 local b=a.view.layout.body
 return L.spec(a.client.data.vid,a.book,path,b.w,b.h,a.state.font,a.state:format(a.book))
end
function L.record(s)
 local f=require('readinknative/cachefiles').open(s.path..'.reader.json','rb');if not f then return nil,'receipt_missing'end
 local raw=f:read(8193);f:close();if #raw>8192 then return nil,'receipt_size'end
 local ok,r=pcall(require('rapidjson').decode,raw)
 if not ok or type(r)~='table'or r.schema~=1 then return nil,'receipt_schema'end
 if r.key~=s.key then return nil,'layout_key'end
 if r.stamp~=stamp(s.path)then return nil,'source_stamp'end
 return r
end
function L.ready(s)
 local r,reason=L.record(s);if not r then return false,nil,reason end
 if type(r.cachePath)~='string'or type(r.cacheStamp)~='string'then return false,nil,'engine_receipt'end
 local current=stamp(r.cachePath)
 if not current then return false,nil,'engine_evicted'end
 if current~=r.cacheStamp then return false,nil,'engine_changed'end
 return true,r
end
local function miss(a,s,reason)
 local key=s.key..':'..tostring(reason)
 if a.layoutMiss~=key then a.layoutMiss=key;require('logger').info('ReadInk layout cache miss:',reason,s.key:sub(1,12))end
end
function L.save(s,cachePath,pages)
 if s.sourceStamp and s.sourceStamp~=stamp(s.path)then return end
 local cacheStamp=type(cachePath)=='string'and stamp(cachePath)
 if not cacheStamp then return end
 local path=s.path..'.reader.json';local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'))
 assert(f:write(require('rapidjson').encode{schema=1,key=s.key,stamp=stamp(s.path),cachePath=cachePath,cacheStamp=cacheStamp,pages=pages}));assert(f:close());assert(require('readinknative/cachefiles').rename(path..'.part',path))
 remember(cachePath,cacheStamp)
end
function L.refresh(s)
 local ready,r=L.ready(s);if not ready or L.engineCacheKnown[r.cachePath]==r.cacheStamp then return end
 -- CRe keeps an in-process directory index: a file newly saved by a fork is
 -- otherwise invisible to an already initialized parent engine. Refresh only
 -- when no CRe document is open; never disturb a host ReaderUI document.
 for _,entry in pairs(require('document/documentregistry').registry)do if entry.doc and entry.doc.provider=='crengine'then return end end
 local C=require('document/credocument');C:engineInit();C.cacheInit()
 remember(r.cachePath,r.cacheStamp)
 require('logger').info('ReadInk refreshed CRe cache directory after worker')
end
function L.track(document,s)s.sourceStamp=stamp(s.path);document.readerCacheSpec=s end
-- Rendering once and closing writes the real DOM/layout cache. Reopening in
-- the worker only verifies that same file and adds another full load to a wait.
-- CRe still validates its cache and rendering hash when the UI restores it.
local function warm(s)
 local clock=require('ui/time');local started=clock.monotonic()
 require('readinknative/content').repairLayout(s.path,s.book.article)
 local doc=require('readinknative/document').open(s.path,s.w,s.h,s.format.size,nil,s.format,'prepare',s.book.article)
 L.track(doc,s)
 local pages=doc:count()
 if s.chapter then require('readinknative/openingmarks').build(doc,s,s.sourceBook,s.chapter)end
 doc:close()
 local saved=L.ready(s)
 require('logger').info('ReadInk chapter preparation ready ms/passes:',math.floor(clock.to_ms(clock.monotonic()-started)),1,saved)
 return{stamp=stamp(s.path),passes=1,cacheSaved=saved,pages=pages}
end
-- Small-memory readers must not retain a suspended second CRe document.
-- Resources/references may prefetch, but native rendering stays single-load.
function L.compact(a)
 if a.compactReader~=nil then return a.compactReader end
 local Device=require('device');if not Device:isKindle()then return false end
 if Device.model=='KindleBasic'then a.compactReader=true;return true end
 local free=require('util').calcFreeMem();if free and free<96*1024*1024 then a.compactReader=true;return true end;return false
end
function L.direct(a,path,chapter,book)
 book=book or a.book
 if not book or book.localFile or book.article or not(L.compact(a)or require('device'):isKindle()or a.singleReader==true)then return false end
 local words=chapter and tonumber(chapter.wordCount)
 local bytes=require('libs/libkoreader-lfs').attributes(path,'size')
 -- A small EPUB may contain a complete long section (26k words in the
 -- reported backward turn). A 20k-word split sent it through warm() with the
 -- current DOM still alive, then opened it again in the parent. Keep bounded
 -- cached sections on the same single-reader route in either direction.
 -- Unknown/very large sections retain the cancellable preparation fallback.
 local enough=bytes and bytes<=2*1024*1024
 if not enough and bytes and bytes<=16*1024*1024 then
  local free=require('util').calcFreeMem()
  enough=free and free>=math.max(128*1024*1024,bytes*8+64*1024*1024)
 end
 return words and words>=0 and words<=100000 and bytes and bytes>0 and enough and true or false
end
function L.pause(a)
 require('readinknative/chapterpreview').stop(a)
 -- Cooperative input hint only. Never SIGSTOP arbitrary native code: it may
 -- retain memory/cache resources required by the visible document.
 if L.compact(a)and a.chapterPreload then L.stop(a)end
end
function L.stop(a)
 require('readinknative/chapterpreview').stop(a)
 require('readinknative/chapterwindow').stop(a)
 if a.preloadResumeTask then require('ui/uimanager'):unschedule(a.preloadResumeTask);a.preloadResumeTask=nil end
 require('readinknative/readingahead').stop(a)
 if a.nextChapterTask then require('ui/uimanager'):unschedule(a.nextChapterTask);a.nextChapterTask=nil end
 if a.preloadJobs then a.preloadJobs:cancel()end
 a.chapterPreload=nil
end
function L.prefetch(a,book,chapter,kind)
 if a.closed or a.suspended or book.localFile then return end
 local Cache=require('readinknative/cache');local path=Cache.find(a.client.data.vid,book,chapter);if not path then return end
 if not require('readinknative/images').ready(path)then return end
 local b=a.view.layout.body;local s=L.spec(a.client.data.vid,book,path,b.w,b.h,a.state.font,a.state:format(book))
 if L.compact(a)or L.direct(a,path,chapter,book)then
  if a.chapterPreload then L.stop(a)end
  require('readinknative/chapterpreview').request(a,book,chapter,path,kind)
  if kind=='next'then require('readinknative/underlinenext').start(a,book,chapter,s)end
  return
 end
 local ready,_,reason=L.ready(s);if not ready then miss(a,s,reason)end
 if kind=='next'then require('readinknative/underlinenext').start(a,book,chapter,s)end
 if ready and(kind~='next'or not require('readinknative/openingmarks').needed(s,book,chapter))then return end
 local old=a.chapterPreload
 if old and old.spec.key==s.key then if a.preloadJobs.resume then a.preloadJobs:resume()end;return old end
 L.stop(a)
 local state,vid=a.state,a.client.data.vid
 local p={spec=s,book=book,chapter=chapter,state=state,vid=vid,kind=kind};a.chapterPreload=p
 if kind=='next'then s.chapter=chapter;s.sourceBook=book end
 a.preloadJobs=a.preloadJobs or require('readinknative/inkjobs').new{NICE=10}
 a.preloadJobs:run('',function()
  assert(Cache.find(vid,book,chapter)==path,'READING_CACHE_CHANGED')
  require('logger').info('ReadInk chapter preload started:',kind)
  return warm(s)
 end,function(ok,result)
  if a.chapterPreload~=p then return end;a.chapterPreload=nil
  if a.closed or a.suspended or a.state~=state or a.client.data.vid~=vid then return end
  if ok then require('readinknative/pagination').offer(a,s,chapter,result)end
  if p.waiter then p.waiter(ok,result)
  elseif not ok then require('logger').warn('ReadInk chapter preload failed:',require('readinknative/errors').code(result))end
  if ok and kind=='next'and a.chapter~=chapter then require('readinknative/underlinenext').start(a,book,chapter,s)end
 end,false)
 return p
end
function L.next(a)
 if not(a.asyncChapterLoad or require('device'):isKindle())or not a.document or not a.chapter or a.book.localFile then return end
 if a.nextChapterTask then require('ui/uimanager'):unschedule(a.nextChapterTask)end
 local owner,state,book=a.document,a.state,a.book
 a.nextChapterTask=function()
  a.nextChapterTask=nil
  if a.closed or a.suspended or a.state~=state or a.document~=owner or a.book~=book or a.mode~='reader'then return end
  local direction=a.readingDirection==-1 and -1 or 1
  local index=require('readinknative/pagination').next(a,direction);local chapter=a.chapters and a.chapters[index]
  if not chapter then return end
  require('readinknative/chapterwindow').prefetch(a)
  if not a.chapterLoading then
   local fetch=a.chapterFetch
   if fetch and tostring(fetch.chapter.chapterUid)~=tostring(chapter.chapterUid)then require('readinknative/readingahead').stop(a)end
   local ink=a.underlineNext
   if ink and not ink.waiting and ink.uid~=tostring(chapter.chapterUid)and ink.uid~=tostring(a.chapter.chapterUid)then require('readinknative/underlinenext').stop(a)end
  end
  local cached=require('readinknative/cache').find(a.client.data.vid,book,chapter)
  if cached and not require('readinknative/images').ready(cached)then cached=nil end
  -- Body fetching can overlap a slow social response on a regular-memory
  -- reader. Never overlap a second native render or relax compact safeguards.
  local inkBusy=a.socialReaderJobs and a.socialReaderJobs.widget or require('readinknative/socialreader').busy(a)
  local deferInk=inkBusy and(cached or L.compact(a))
  if a.jobs.widget or a.chapterLoading or deferInk or require('readinknative/underlinenext').busy(a)or not require('readinknative/offline').canPreload(a,book,chapter)then a.nextChapterTask=function()a.nextChapterTask=nil;L.next(a)end;require('ui/uimanager'):scheduleIn(0.3,a.nextChapterTask);return end
  if cached then L.prefetch(a,book,chapter,'next')
  else require('readinknative/readingahead').start(a,book,chapter,direction)end
 end
 require('ui/uimanager'):scheduleIn(0.15,a.nextChapterTask)
end
function L.prime(a)
 if L.compact(a)then return end
 if not(a.asyncChapterLoad or require('device'):isKindle())or a.closed or a.suspended then return end
 local id=a.state.readingHistory and a.state.readingHistory[1]and a.state.readingHistory[1].bookId
 if not id then return end
 for _,book in ipairs(a.state.books or{})do if tostring(book.bookId)==tostring(id)and not book.localFile then
  local updated=a.state.recent and a.state.recent[tostring(id)]
  if type(updated)~='number'or updated>os.time()or os.time()-updated>86400 then return end
  local chapter=require('readinknative/readingstart').choose(a.state,book,a.state.catalogs[tostring(id)])
  if chapter then L.prefetch(a,book,chapter,'startup')end
  return
 end end
end
function L.cancel(a)
 local loading=a.chapterLoading
 if loading and loading.readingFetch then require('readinknative/readingahead').stop(a)end
 if a.chapterJobs then a.chapterJobs:cancel()end
 if a.chapterPreload and loading and loading.preload==a.chapterPreload then a.chapterPreload.waiter=nil end
 a.chapterLoading=nil
 if loading then local stats=require('readinknative/readingstats');stats.update(a);stats.schedule(a)end
end
function L.prepare(a,path,chapter,done,turnDelta)
 local nextInk=a.underlineNext
 if nextInk and nextInk.document.path~=path then require('readinknative/underlinenext').stop(a)end
 if not(a.asyncChapterLoad or require('device'):isKindle())then
  require('readinknative/content').repairLayout(path,a.book.article);done();return
 end
 if L.direct(a,path,chapter)then
  L.stop(a);a.singleReaderPath=path;require('logger').info('ReadInk compact single-load chapter:',tonumber(chapter.wordCount));done();return
 end
 local s=spec(a,path);local format=s.format
 local resident=require('readinknative/resident').peek(a,path,s.w,s.h,a.state.font,format,chapter)
 local ready,_,reason=L.ready(s)
 if resident or ready then if a.chapterPreload then L.stop(a)end;done();return end;miss(a,s,reason)
 L.cancel(a);require('readinknative/offline').beforeForeground(a)
 require('readinknative/socialreader').cancel(a)
 local owner={state=a.state,book=a.book,chapter=a.chapter,document=a.document,vid=a.client.data.vid,mode=a.mode,targetChapter=chapter,turnDelta=turnDelta}
 a.chapterLoading=owner
 local stats=require('readinknative/readingstats');stats.update(a);stats.schedule(a)
 local function finish(ok,result)
  if a.chapterLoading~=owner then return end;a.chapterLoading=nil;stats.update(a);stats.schedule(a)
  if a.closed or a.suspended or a.mode~=owner.mode or a.state~=owner.state or a.book~=owner.book or a.chapter~=owner.chapter or a.document~=owner.document or a.client.data.vid~=owner.vid then return end
  if not ok then a:failure(result);return end
  if spec(a,path).key~=s.key or result.stamp~=stamp(path)then return end
  if require('readinknative/cache').find(a.client.data.vid,a.book,owner.targetChapter)~=path then a:message('本地章节的阅读权限已变化，请重新打开图书核对。');return end
  done()
 end
 local p=a.chapterPreload
 if p and p.spec.key==s.key then
  owner.preload=p;p.waiter=finish
  if a.preloadResumeTask then require('ui/uimanager'):unschedule(a.preloadResumeTask);a.preloadResumeTask=nil end
  if a.preloadJobs.resume then a.preloadJobs:resume()end
  require('logger').info('ReadInk waiting for existing chapter preload');return
 end
 L.stop(a);a.chapterJobs=a.chapterJobs or require('readinknative/inkjobs').new()
 a.chapterJobs:run('',function()require('logger').info('ReadInk chapter preparation started');return warm(s)end,finish,false,
  function()if a.chapterLoading==owner then a.chapterLoading=nil;stats.update(a);stats.schedule(a)end end)
end
return L
