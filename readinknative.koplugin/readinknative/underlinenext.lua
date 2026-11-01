-- Speculative next-chapter ink. Body preparation remains independent so a
-- slow/missing social response can never delay displaying the new chapter.
local N={}
function N.stop(a)
 local p=a.underlineNext;a.underlineNext=nil
 if p and p.poll then require('ui/uimanager'):unschedule(p.poll);p.poll=nil end
 if p and p.waiting and a.socialReader==p.waiting then p.waiting.loading=false;p.waiting.waitingNext=nil end
 if a.underlineNextJobs then a.underlineNextJobs:cancel()end
end
local function same(a,p)
 return p and a.underlineNext==p and not a.closed and not a.suspended and a.state==p.state and tostring(a.client.data.vid)==p.vid
  and a.book and tostring(a.book.bookId)==p.bookId and tostring(a.book.version or 0)==p.version
end
function N.busy(a)return same(a,a.underlineNext)and true or false end
local function owner(a,book,ch,path)
 return{state=a.state,vid=tostring(a.client.data.vid),book=book,chapter=ch,bookId=tostring(book.bookId),version=tostring(book.version or 0),uid=tostring(ch.chapterUid),
  stamp=require('readinknative/pagination').fileStamp(path),document={path=path}}
end
local function cacheOwner(p)
 p.cacheKey=table.concat({p.vid,p.bookId,p.version,p.uid,p.stamp},':')..(require('readinknative/relatededitions').isCB(p.book)and ':cb3'or '');return p
end
function N.join(a,c,done)
 local p=a.underlineNext
 if not same(a,p)or p.document.path~=c.document.path or p.cacheKey~=c.cacheKey then return false end
 local b=a.view.layout.body;local s=require('readinknative/chapterloader').spec(c.vid,c.book,c.document.path,b.w,b.h,a.state.font,a.state:format(c.book))
 if s.key~=p.spec.key then return false end
 p.waiter=done;p.waiting=c
 local UI=require('ui/uimanager')
 p.poll=function()
  if not same(a,p)then return end
  local rows,available,anchor,meta=require('readinknative/underlinecache').load(p)
  if rows and(require('readinknative/relatededitions').isCB(p.book)or not(meta and meta.partial))and(available>0 or #rows==0)then
   p.waiting=nil;N.stop(a);done(true,{rows=rows,first=available,anchor=anchor,partial=meta and meta.partial})
  else UI:scheduleIn(0.1,p.poll)end
 end
 UI:scheduleIn(0.1,p.poll);require('logger').info('ReadInk next underline foreground joined');return true
end
function N.start(a,book,ch,s)
 if a.closed or a.suspended or a.mode~='reader'or not a.document or not a.client:ready()or book.localFile or book.article
  or a.chapter and tostring(a.chapter.chapterUid)==tostring(ch.chapterUid)
  or(a.state.socialDisplay or{})[tostring(book.bookId)]==false or require('readinknative/socialreader').busy(a)then return end
 local Cache=require('readinknative/cache');local path=Cache.find(a.client.data.vid,book,ch)
 if not path then return end
 local p=cacheOwner(owner(a,book,ch,path));local UC=require('readinknative/underlinecache');local cachedRows,cachedAvailable,cachedAnchor,meta=UC.load(p)
 local window=require('readinknative/chapterwindow').contains(a,path,ch)and a.document
 local indexWindow=window and not require('readinknative/relatededitions').isCB(book)and not(cachedAnchor and cachedAnchor.coordinateAttempted)
 if indexWindow and cachedRows then indexWindow=false;for _,row in ipairs(cachedRows)do if not row.position then indexWindow=true;break end end end
 if cachedRows and(#cachedRows==0 or cachedAnchor)and not indexWindow then return end
 if cachedRows and not indexWindow then
  a.underlineAnchorAttempts=a.underlineAnchorAttempts or{}
  if a.underlineAnchorAttempts[p.cacheKey]then return end
  local count=0;for _ in pairs(a.underlineAnchorAttempts)do count=count+1 end;if count>=64 then a.underlineAnchorAttempts={}end
  a.underlineAnchorAttempts[p.cacheKey]=true
 end
 local old=a.underlineNext;if same(a,old)and old.cacheKey==p.cacheKey and old.spec.key==s.key then return old end
 N.stop(a);p.spec=s;a.underlineNext=p
 require('readinknative/offline').beforeForeground(a)
 a.underlineNextJobs=a.underlineNextJobs or require('readinknative/inkjobs').new{NICE=10};local data=a.client.data;local catalog=a.chapters
 a.underlineNextJobs:run('',function()
  local clock=require('socket');local start=clock.gettime()
  assert(Cache.find(p.vid,book,ch)==path and require('readinknative/pagination').fileStamp(path)==p.stamp,'SOCIAL_READING_CACHE_CHANGED')
  local client=require('readinknative/client'):new(data)
  client.refresh=function()error('PRELOAD_AUTH_REFRESH_DEFERRED')end
  local request=client.request;client.request=function(self,url,body,auth,timeout,repeated)return request(self,url,body,auth,timeout or 4,repeated)end
  local Related=require('readinknative/relatededitions');local quick=not cachedRows and Related.isCB(book)
  local refs=quick and require('readinknative/underlinerefs').fetch(client,book,ch,path,catalog,true)
  local rows=cachedRows or refs and refs.rows or Related.readRanges(client,book,ch);local network=clock.gettime()
  local anchor=cachedAnchor;local source
  if refs then source=refs.source;anchor=UC.anchor(require('readinknative/underlinepage').anchor(source))end
  if cachedRows and #rows>0 then source=require('readinknative/socialranges').cachedSource(path,book,ch);anchor=anchor or UC.anchor(require('readinknative/underlinepage').anchor(source))end
  if not cachedRows and not refs and #rows>0 then
   local ignored;ignored,source=require('readinknative/socialranges').load(client,book,ch,path,rows)
   anchor=UC.anchor(require('readinknative/underlinepage').anchor(source))
  end
  local partial=refs and refs.partial or meta and meta.partial
  if not cachedRows and not refs then
   local ok,related,incomplete=pcall(require('readinknative/relatededitions').collect,client,book,ch,path,rows,catalog,source)
   if ok then rows=related;partial=incomplete elseif #rows==0 then error(related,0)else partial=true end
  end
  local mapped=0
  -- CB prefetch publishes references immediately. The visible reader matches
  -- its current page first; full chapter indexing may follow after first paint.
  if not Related.isCB(book)and window and #rows>0 and source and not(anchor and anchor.coordinateAttempted)then
   local view=require('readinknative/chapterwindow').workerView(window,ch)
   if view then
    local updates=require('readinknative/coordinateindex').resolve(view,source,rows,book,ch)
    if anchor then anchor.coordinateAttempted=true end
    for _,u in ipairs(updates or{})do local row=rows[u.index];row.position=u.position;row.resolved=u.resolved;mapped=mapped+1 end
   end
  end
  -- Outside a continuous spine, references only: never open a second DOM.
  assert(Cache.find(p.vid,book,ch)==path and require('readinknative/pagination').fileStamp(path)==p.stamp,'SOCIAL_READING_CACHE_CHANGED')
  UC.save(p,rows,nil,anchor,{partial=partial})
  return{rows=rows,anchor=anchor,partial=partial,first=#rows,mapped=mapped,networkMs=math.floor((network-start)*1000),sourceMs=math.floor((clock.gettime()-network)*1000),mapMs=0}
 end,function(ok,result)
  if not same(a,p)then return end
  if p.poll then require('ui/uimanager'):unschedule(p.poll);p.poll=nil end
  a.underlineNext=nil
  if Cache.find(p.vid,book,ch)~=path or require('readinknative/pagination').fileStamp(path)~=p.stamp then ok=false;result='SOCIAL_READING_CACHE_CHANGED'end
  if ok then require('logger').info('ReadInk next underline ready rows/first/ms:',#result.rows,result.first,result.networkMs+result.sourceMs+result.mapMs)
  else require('logger').info('ReadInk next underline deferred:',require('readinknative/errors').code(result))end
  if p.waiter then p.waiter(ok,result)elseif ok then require('readinknative/chapterloader').next(a)end
 end,false)
 return p
end
return N
