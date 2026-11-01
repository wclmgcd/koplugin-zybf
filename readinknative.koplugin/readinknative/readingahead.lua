-- A small reading buffer is independent of whole-book shelf downloads.
local B={LIMIT=5,SHORT=1500,WORDS=24000,COOLDOWN=30}
local function id(x)return tostring(x.bookId)end
local function uid(x)return tostring(x.chapterUid)end
function B.plan(book,catalog,chapter,vid,direction)
 local P=require('readinknative/permission');local start
 for i,ch in ipairs(catalog)do if uid(ch)==uid(chapter)then start=i;break end end
 if not start then return{}end
 local out={catalog[start]};local total=tonumber(catalog[start].wordCount)
 -- Unknown or long current chapters have enough reading time for background
 -- work. Do not enlarge the foreground download unnecessarily.
 if not total or total<0 or total>B.SHORT then return out end
 local step=direction==-1 and -1 or 1
 for distance=1,B.LIMIT-1 do
  local i=start+distance*step;if i<1 or i>#catalog then break end
  local ch=catalog[i];local words=tonumber(ch.wordCount)
  if not words or words<0 or total+words>B.WORDS then break end
  local mode=P.mode(book,ch,vid);local idx,limit=tonumber(ch.chapterIdx),tonumber(book.maxFreeChapter)
  if mode~='full'and not(mode=='preview'and idx and limit and idx>=0 and idx<=limit)then break end
  out[#out+1]=ch;total=total+words
  if words>B.SHORT then break end
 end
 return out
end
local function same(a,p)
 return p and a.chapterFetch==p and not a.closed and not a.suspended and a.state==p.state and a.book
  and id(a.book)==p.bookId and tostring(a.book.version or 0)==p.version and tostring(a.client.data.vid)==p.vid
end
function B.stop(a)
 local p=a.chapterFetch;a.chapterFetch=nil
 if p then
  if a.chapterFetchAttempts then a.chapterFetchAttempts[p.key]=nil end
  p.waiter=nil
  if a.chapterLoading and a.chapterLoading.readingFetch==p then
   a.chapterLoading=nil;local stats=require('readinknative/readingstats');stats.update(a);stats.schedule(a)
  end
 end
 if a.chapterFetchJobs then a.chapterFetchJobs:cancel()end
end
function B.start(a,book,chapter,direction)
 if a.closed or a.suspended or a.mode~='reader'or book.localFile or book.article or not a.client:ready()then return end
 local old=a.chapterFetch
 if same(a,old)and uid(old.chapter)==uid(chapter)then return old end
 local key=table.concat({tostring(a.client.data.vid),id(book),tostring(book.version or 0),uid(chapter)},':')
 a.chapterFetchAttempts=a.chapterFetchAttempts or{}
 if a.chapterFetchAttempts[key]and os.time()-a.chapterFetchAttempts[key]<B.COOLDOWN then return end
 B.stop(a);a.chapterFetchAttempts[key]=os.time()
 local p={state=a.state,bookId=id(book),version=tostring(book.version or 0),vid=tostring(a.client.data.vid),chapter=chapter,key=key}
 a.chapterFetch=p;a.chapterFetchJobs=a.chapterFetchJobs or require('readinknative/jobs').new();local data=a.client.data;local context=a.readContext
 a.chapterFetchJobs:run('',function()
  local client=require('readinknative/client'):new(data);client.refresh=function()error('PRELOAD_AUTH_REFRESH_DEFERRED')end
  local request=client.request;client.request=function(self,url,body,auth,timeout,repeated)return request(self,url,body,auth,timeout or 4,repeated)end
  local A=require('readinknative/api');local info,catalog=A.contextBook(client,book,context,true);local reused=info~=nil
  if not info then info=A.info(client,book);catalog=A.catalog(client,info)end
  assert(tostring(info.version or 0)==p.version,'BOOK_UPDATED')
  local selected
  for _,ch in ipairs(catalog)do if uid(ch)==uid(chapter)then selected=ch;break end end
  assert(selected,'CATALOG_EMPTY')
  local mode=require('readinknative/permission').mode(info,selected,client.data.vid);local idx,limit=tonumber(selected.chapterIdx),tonumber(info.maxFreeChapter)
  assert(mode=='full'or mode=='preview'and idx and limit and idx>=0 and idx<=limit,'READING_PERMISSION_REQUIRED')
  local result=A.prepareChapter(client,info,selected,false)
  result.catalog=catalog;result.contextReused=reused;return result
 end,function(ok,result)
  if not same(a,p)then if a.chapterFetch==p then B.stop(a)end;return end;a.chapterFetch=nil
  if ok and require('readinknative/cache').find(p.vid,result.book,result.chapter)~=result.path then ok=false;result='READING_CACHE_CHANGED'end
  if p.waiter then p.waiter(ok,result)
  elseif ok then
   require('logger').info('ReadInk reading buffer ready; preparing next layout')
   require('readinknative/chapterloader').prefetch(a,a.book,result.chapter,'next')
  else require('logger').info('ReadInk reading buffer deferred:',require('readinknative/errors').code(result))end
 end,false)
 return p
end
function B.join(a,chapter,done,turnDelta)
 local p=a.chapterFetch;if not same(a,p)or uid(p.chapter)~=uid(chapter)then return false end
 local owner={state=a.state,book=a.book,chapter=a.chapter,document=a.document,vid=a.client.data.vid,mode=a.mode,targetChapter=chapter,turnDelta=turnDelta,readingFetch=p}
 a.chapterLoading=owner;local stats=require('readinknative/readingstats');stats.update(a);stats.schedule(a)
 p.waiter=function(ok,result)
  if a.chapterLoading~=owner then return end;a.chapterLoading=nil;stats.update(a);stats.schedule(a)
  if a.closed or a.suspended or a.state~=owner.state or a.book~=owner.book or a.chapter~=owner.chapter or a.document~=owner.document or a.client.data.vid~=owner.vid or a.mode~=owner.mode then return end
  done(ok,result)
 end
 require('logger').info('ReadInk foreground joined reading buffer');return true
end
return B
