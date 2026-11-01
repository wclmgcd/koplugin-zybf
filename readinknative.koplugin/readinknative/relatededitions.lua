-- CB uploads keep their own IDs and positions. Public thoughts may be read
-- from a conservatively matched edition only after exact, unique quote mapping.
-- Edition/catalog matching adapts the supplied readerbridge reference.
local M={TTL=86400,MAX_CANDIDATES=20}
function M.isCB(book)return type(book)=='table'and type(book.bookId)=='string'and book.bookId:sub(1,3)=='CB_'end
local function normal(s)return tostring(s or''):gsub('　',''):gsub('%s+',''):lower()end
function M.baseTitle(s)
 return tostring(s or''):gsub('　',' '):gsub('^《',''):gsub('》$',''):gsub('%.epub$',''):gsub('%.txt$',''):gsub('（','('):gsub('）',')'):gsub('【','['):gsub('】',']'):gsub('%b()',''):gsub('%b[]',''):gsub('^%s+',''):gsub('%s+$',''):gsub('^《',''):gsub('》$','')
end
local function authorKey(s)return normal(M.baseTitle(s)):gsub('·',''):gsub('著$','')end
local digits={['零']=0,['〇']=0,['一']=1,['二']=2,['两']=2,['三']=3,['四']=4,['五']=5,['六']=6,['七']=7,['八']=8,['九']=9}
local units={['十']=10,['百']=100,['千']=1000}
local function chapterNumber(s)
 if s:match('^%d+$')then return tonumber(s)end
 local total,last,count=0,0,0;local plain={};local hasUnit=false
 for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*')do
  count=count+1
  if digits[ch]then last=digits[ch];plain[#plain+1]=tostring(last)
  elseif units[ch]then hasUnit=true;total=total+(last==0 and 1 or last)*units[ch];last=0
  else return end
 end
 if count==0 then return end
 return hasUnit and total+last or tonumber(table.concat(plain))
end
function M.chapterKey(title)
 local s=normal(title);local number,tail=s:match('^第(.-)章(.*)$')
 if not number then number,tail=s:match('^第(.-)回(.*)$')end
 if not number then number,tail=s:match('^第(.-)节(.*)$')end
 if not number then number,tail=s:match('^(%d+)%.(.+)$')end
 if not number then number,tail=s:match('^(.-)、(.+)$')end
 local n=chapterNumber(number or s)
 if n then return'#'..n..(tail and tail~=''and(':'..tail)or'')end
 return s
end
local front={['封面']=true,['封底']=true,['前折页']=true,['后折页']=true,['书名页']=true,['扉页']=true,['版权页']=true,['版权信息']=true,['目录']=true,['插图']=true,['文前辅文']=true,['序']=true,['序言']=true,['推荐序']=true,['重印前记']=true}
local function set(chapters,body)
 local t,n={},0
 for _,ch in ipairs(chapters or{})do local k=M.chapterKey(ch.title);if k~=''and not t[k]and not(body and front[k])then t[k]=true;n=n+1 end end
 return t,n
end
local function similarity(a,b,body)
 local x,n=set(a,body);local y,m=set(b,body);local shared,long=0,0
 for k in pairs(x)do if y[k]then shared=shared+1;if #k>=12 and not front[k]then long=long+1 end end end
 return shared/math.max(1,math.min(n,m)),shared,math.abs(n-m),long
end
function M.match(book,current,candidate,catalog)
 if not tostring(candidate.bookId):match('^%d+$')or normal(M.baseTitle(book.title))~=normal(M.baseTitle(candidate.title))then return end
 local author,other=authorKey(book.author),authorKey(candidate.author)
 local same=author~=''and author==other
 local ratio,overlap,diff,long=similarity(current,catalog)
 local compatible=ratio>=0.65 and overlap>=3
 if not same then
  -- Translated author names require distinctive full-catalog corroboration;
  -- generic numbered chapters cannot establish an edition relationship.
  local scriptsDiffer=(author:find('[A-Za-z]')~=nil)~=(other:find('[A-Za-z]')~=nil)
  compatible=compatible and ratio>=0.65 and overlap>=5 and long>=3 and(author==''or other==''or scriptsDiffer)
 elseif not compatible then
  ratio,overlap,diff=similarity(current,catalog,true);compatible=ratio>=0.75 and overlap>=5
 end
 local quoteOnly=not compatible and same and #(current or{})>0 and #(catalog or{})>0
 if not compatible and not quoteOnly then return end
 local byTitle,counts={},{}
 for _,ch in ipairs(catalog)do local k=M.chapterKey(ch.title);counts[k]=(counts[k]or 0)+1;byTitle[k]=ch end
 local map,active={}
 for _,ch in ipairs(current)do
  local k=M.chapterKey(ch.title)
  if counts[k]==1 then active=byTitle[k]elseif counts[k]and counts[k]>1 then active=nil end
  if active then map[tostring(ch.chapterUid)]=active end
 end
 return{book=candidate,map=map,catalog=catalog,quoteOnly=quoteOnly or nil,score=quoteOnly and -1000 or ratio*100+(same and 10 or 0)-diff,overlap=overlap}
end
local function disk(vid,name,key)return require('readinknative/paths').cache(vid,'related-'..name..'-'..require('ffi/sha2').sha256(key)..'.json')end
local function read(path,key,limit)
 local f=require('readinknative/cachefiles').open(path,'rb');if not f then return end;local raw=f:read((limit or 262144)+1);f:close()
 if #raw>(limit or 262144)then return end
 local ok,r=pcall(require('rapidjson').decode,raw)
 if ok and type(r)=='table'and r.key==key and type(r.at)=='number'and r.at<=os.time()and os.time()-r.at<M.TTL then return r.value end
end
local function write(path,key,value,limit)
 local F=require('readinknative/cachefiles');local raw=require('rapidjson').encode{key=key,at=os.time(),value=value}
 if #raw>(limit or 512*1024)then return end
 local f=F.open(path..'.part','wb');if not f then return end;local ok=f:write(raw);local closed=f:close()
 if ok and closed then F.rename(path..'.part',path)else F.remove(path..'.part')end
end
function M.select(client,book,current)
 if not M.isCB(book)or book.format=='pdf'then return end
 local titles={};for _,ch in ipairs(current or{})do titles[#titles+1]=tostring(ch.chapterUid)..':'..tostring(ch.title)end
 local key=table.concat({tostring(client.data.vid),book.bookId,tostring(book.version or 0),table.concat(titles,'|')},':')
 local path=disk(client.data.vid,'edition','v3:'..key);local cached=read(path,key)
 if cached then return cached.book and cached or nil end
 -- Reuse a previously discovered edition (e.g. an already downloaded Human
 -- History) after one metadata/catalog validation, without repeating search.
 local previous=read(disk(client.data.vid,'edition','v2:'..key),key)
 if type(previous)=='table'and type(previous.book)=='table'then
  local ok,value=pcall(function()
   local API=require('readinknative/api');local info=API.info(client,previous.book);local chapters=API.catalog(client,info)
   local matched=M.match(book,current,info,chapters)
   if matched then
    matched.book={bookId=tostring(info.bookId),version=info.version or 0,title=info.title,author=info.author,format=info.format};matched.checkedAt=os.time();return matched
   end
  end)
  if ok and value then write(path,key,value);return value end
 end
 local result=require('readinknative/storeapi').search(client,M.baseTitle(book.title))
 local candidates={}
 for _,item in ipairs(result.items or{})do local b=item.book
  if b and tostring(b.bookId):match('^%d+$')and normal(M.baseTitle(b.title))==normal(M.baseTitle(book.title))then candidates[#candidates+1]=b end
 end
 -- A popular title can have many editions. Examine bounded candidates;
 -- one unavailable edition must not abort all the others.
 local seen,unique={},{};for _,b in ipairs(candidates)do if not seen[b.bookId]then unique[#unique+1]=b;seen[b.bookId]=true end end;candidates=unique
 table.sort(candidates,function(a,b)
  local sameA=authorKey(a.author)==authorKey(book.author)
  local sameB=authorKey(b.author)==authorKey(book.author)
  if sameA~=sameB then return sameA end;return tostring(a.bookId)<tostring(b.bookId)
 end)
 local best,lastError;local checked=0
 for i,candidate in ipairs(candidates)do
  if i>M.MAX_CANDIDATES then break end
  local ok,catalog=pcall(require('readinknative/api').catalog,client,candidate)
  if ok then checked=checked+1 else lastError=catalog end
  local value=ok and M.match(book,current,candidate,catalog)
  if value then
   if not best or value.score>best.score or value.score==best.score and tostring(value.book.bookId)<tostring(best.book.bookId)then best=value end
   if not value.quoteOnly and value.score>=99 then break end
  end
 end
 if best then
  local info=require('readinknative/api').info(client,best.book)
  assert(normal(M.baseTitle(info.title))==normal(M.baseTitle(book.title))and info.format~='pdf','RELATED_SOURCE_INVALID')
  best.book={bookId=tostring(info.bookId),version=info.version or 0,title=info.title,author=info.author,format=info.format};best.checkedAt=os.time()
  write(path,key,best);return best
 end
 if checked==0 and lastError then error(lastError,0)end
 -- Negative results are not stored: catalogs/search may be incomplete.
end
function M.validSource(s,book,chapter)
 return type(s)=='table'and type(s.bookId)=='string'and s.bookId:match('^%d+$')and #s.bookId<=128
  and type(s.chapterUid)=='string'and s.chapterUid:match('^%d+$')and #s.chapterUid<=16
  and type(s.range)=='string'and #s.range<=64 and s.range:match('^%d+%-%d+$')
  and tonumber(s.range:match('^(%d+)'))<tonumber(s.range:match('%-(%d+)$'))
  and type(s.version)=='string'and #s.version<=32 and type(s.title)=='string'and #s.title<=1024
  and type(s.targetBookId)=='string'and #s.targetBookId<=128 and type(s.targetChapterUid)=='string'and #s.targetChapterUid<=128
  and type(s.targetVersion)=='string'and #s.targetVersion<=32
  and(not book or s.targetBookId==tostring(book.bookId)and s.targetVersion==tostring(book.version or 0))
  and(not chapter or s.targetChapterUid==tostring(chapter.chapterUid))
end
function M.readRanges(client,book,chapter)
 local ok,rows=pcall(require('readinknative/socialapi').ranges,client,book,chapter)
 if ok then return rows end
 if not M.isCB(book)then error(rows,0)end
 -- Uploaded books may have no public range endpoint; related quotes still
 -- require the independently verified local CB source below.
 return{}
end
local function sourceKey(book)return tostring(book.bookId)..':'..tostring(book.version or 0)end
function M.sourceHot(client,book)
 local key=sourceKey(book);local path=disk(client.data.vid,'hot',key);local value=read(path,key,2*1024*1024)
 if value then return value end
 value=require('readinknative/socialapi').hot(client,book)
 -- One book-wide ranking fetch is shared by every chapter during download.
 write(path,key,value,2*1024*1024);return value
end
function M.collect(client,book,chapter,path,rows,catalog,localSource,options)
 if not M.isCB(book)or book.format=='pdf'then return rows end
 local API=require('readinknative/api');local R=require('readinknative/socialranges');local Pos=require('readinknative/readingposition')
 catalog=catalog or API.catalog(client,book)
 local edition=M.select(client,book,catalog)
 if not edition then return rows end
 local sourceBook=edition.book;local sourceChapter=edition.map[tostring(chapter.chapterUid)]
 localSource=localSource or R.cachedSource(path,book,chapter)
 if not localSource then local _,value=R.load(client,book,chapter,path,{});localSource=value end
 if not localSource then return rows end
 local index=localSource.format=='txt'and Pos.indexPlain(localSource.text)or Pos.index(localSource.html)
 local byRange={};for _,row in ipairs(rows)do byRange[row.range]=row end
 local function add(row,sourceUid,quote)
  if type(quote)~='string'or #Pos.compact(quote)<12 or #quote>16384 then return end
  local range=Pos.range(index,quote);if not range then return end
  if byRange[range]then return range end
  local target,ends=R.quote(localSource.text or localSource.html,range,nil,localSource.format=='txt')
  if not target or Pos.compact(target)~=Pos.compact(quote)or #rows>=1000 then return end
  local value={range=range,quote=target,endpoints=ends,count=row.count,type=row.type,score=row.score,
   foreign={bookId=tostring(sourceBook.bookId),version=tostring(sourceBook.version or 0),chapterUid=tostring(sourceUid),range=row.range,title=sourceBook.title,
    targetBookId=tostring(book.bookId),targetVersion=tostring(book.version or 0),targetChapterUid=tostring(chapter.chapterUid)}}
  rows[#rows+1]=value;byRange[range]=value;return range
 end
 local hotOk,hot=pcall(M.sourceHot,client,sourceBook)
 local processed={};local incomplete=false
 local function prepareSource(sourceChapter)
  local uid=tostring(sourceChapter.chapterUid);if processed[uid]then return end;processed[uid]=true
  local key=sourceKey(sourceBook)..':'..tostring(sourceChapter.chapterUid)
  local rangePath=disk(client.data.vid,'ranges',key);local ranges=read(rangePath,key,512*1024)
  if not ranges and not(options and options.quick)then
   local good,value=pcall(require('readinknative/socialapi').ranges,client,sourceBook,sourceChapter)
   if good then ranges=value;write(rangePath,key,ranges)elseif hotOk then ranges={};incomplete=true else error(value,0)end
  end
  ranges=ranges or{}
  local quotePath=disk(client.data.vid,'quotes',key);local quotes=read(quotePath,key,512*1024)or{}
  if hotOk then for _,r in ipairs(hot.rows)do if tostring(r.chapter.chapterUid)==tostring(sourceChapter.chapterUid)and r.quote~=''then quotes[r.range]=r.quote end end end
  local missing=false;for _,r in ipairs(ranges)do if quotes[r.range]==nil then missing=true;break end end
  if missing and not(options and options.quick)then
   local bodyOk,source=pcall(function()
    local info=API.info(client,sourceBook)
    assert(tostring(info.version or 0)==tostring(sourceBook.version or 0),'RELATED_SOURCE_VERSION_CHANGED')
    local mode=require('readinknative/permission').mode(info,sourceChapter,client.data.vid)
    local body,headers=API.download(client,info,sourceChapter,mode)
    return R.source(API.unpack(body,headers,client,info,{sourceChapter}),info,sourceChapter)
   end)
   if bodyOk and source then R.populate(source,ranges);for _,r in ipairs(ranges)do if r.quote then quotes[r.range]=r.quote end end end
   if bodyOk and source then for _,r in ipairs(ranges)do if quotes[r.range]==nil then quotes[r.range]=false end end end
   if not(bodyOk and source)then incomplete=true end
  end
  write(quotePath,key,quotes)
  for _,r in ipairs(ranges)do add(r,sourceChapter.chapterUid,quotes[r.range])end
 end
 if sourceChapter then prepareSource(sourceChapter)end
 -- CB uploads can split/merge/rename chapters. A uniquely verified quote may
 -- originate in another source chapter; retain that chapter's real identity.
 if hotOk then
  local discovered={};for _,r in ipairs(hot.rows)do
   if add(r,r.chapter.chapterUid,r.quote)then discovered[tostring(r.chapter.chapterUid)]=r.chapter end
  end
  local count=0;for uid,ch in pairs(discovered)do if not processed[uid]and count<5 then
   for _,candidate in ipairs(edition.catalog or{})do if tostring(candidate.chapterUid)==uid then ch=candidate;break end end
   prepareSource(ch);count=count+1
  end end
 elseif not sourceChapter then error(hot,0)end
 return rows,incomplete
end
-- The book-wide hot list uses the same source provenance as inline marks.
-- Only quotations uniquely present in an already downloaded CB chapter enter
-- this list; reading RPCs still use the canonical source coordinates.
function M.hot(client,book,cursor,catalog)
 local API=require('readinknative/socialapi')
 if not M.isCB(book)or book.format=='pdf'then return API.hot(client,book,cursor)end
 local ok,direct=pcall(API.hot,client,book,cursor and not cursor.relatedTitle and cursor or nil)
 if ok and #direct.rows>0 then return direct end
 catalog=catalog or require('readinknative/api').catalog(client,book)
 local edition=M.select(client,book,catalog);if not edition then if ok then return direct end;error(direct,0)end
 local info=require('readinknative/api').info(client,edition.book)
 assert(info.format~='pdf'and normal(M.baseTitle(info.title))==normal(M.baseTitle(book.title)),'RELATED_SOURCE_INVALID')
 if cursor and cursor.relatedVersion then assert(cursor.relatedVersion==tostring(info.version or 0),'RELATED_SOURCE_VERSION_CHANGED')end
 local data=API.hot(client,info,cursor);local Cache=require('readinknative/cache');local R=require('readinknative/socialranges');local Pos=require('readinknative/readingposition')
 local pending={}
 for _,row in ipairs(data.rows)do local uid=tostring(row.chapter.chapterUid);pending[uid]=pending[uid]or{};pending[uid][#pending[uid]+1]={row=row,count=0}end
 for _,ch in ipairs(catalog)do
  local mapped=edition.map[tostring(ch.chapterUid)];local candidates=mapped and pending[tostring(mapped.chapterUid)]
  if candidates then
   local path=Cache.find(client.data.vid,book,ch)
   if path then
    local sourceOk,source=pcall(R.cachedSource,path,book,ch)
    if sourceOk and source then
     local index=source.format=='txt'and Pos.indexPlain(source.text)or Pos.index(source.html)
     for _,hit in ipairs(candidates)do local row=hit.row
      if #Pos.compact(row.quote)>=12 then
       local range=Pos.range(index,row.quote)
       local quote=range and R.quote(source.text or source.html,range,nil,source.format=='txt')
       if quote and Pos.compact(quote)==Pos.compact(row.quote)then
        hit.count=hit.count+1;hit.target={id=tostring(ch.chapterUid)..':'..range,range=range,quote=quote,chapter=ch,count=row.count,
         foreign={bookId=tostring(info.bookId),version=tostring(info.version or 0),chapterUid=tostring(row.chapter.chapterUid),range=row.range,title=info.title,
          targetBookId=tostring(book.bookId),targetVersion=tostring(book.version or 0),targetChapterUid=tostring(ch.chapterUid)}}
       end
      end
     end
    end
   end
  end
 end
 local byId={};for _,hits in pairs(pending)do for _,hit in ipairs(hits)do if hit.count==1 then byId[hit.row.id]=hit.target end end end
 local rows={};for _,row in ipairs(data.rows)do if byId[row.id]then rows[#rows+1]=byId[row.id]end end
 data.rows=rows;data.relatedTitle=info.title;data.relatedVersion=tostring(info.version or 0);return data
end
function M.hotInfo(client,book,catalog)
 local API=require('readinknative/socialapi');local ok,value=pcall(API.hotInfo,client,book)
 if not M.isCB(book)or book.format=='pdf'or ok and(value.total or 0)>0 then if ok then return value end;error(value,0)end
 catalog=catalog or require('readinknative/api').catalog(client,book)
 local edition=M.select(client,book,catalog);if not edition then if ok then return value end;error(value,0)end
 local info=API.hotInfo(client,edition.book);info.relatedTitle=edition.book.title;return info
end
function M.groups(client,book,chapter,ranges,start)
 local API=require('readinknative/socialapi');local result={};start=start or 1
 local related=false;for i=start,math.min(#ranges,start+4)do if ranges[i].foreign then related=true;break end end
 if not related then return API.groups(client,book,chapter,ranges,start)end
 for i=start,math.min(#ranges,start+4)do local row=ranges[i];local s=row.foreign
  if s then
   assert(M.validSource(s,book,chapter),'RELATED_SOURCE_INVALID')
   local sourceBook={bookId=s.bookId,version=s.version,title=s.title};local info=require('readinknative/api').info(client,sourceBook)
   assert(tostring(info.version or 0)==s.version,'RELATED_SOURCE_VERSION_CHANGED')
   local group=API.groups(client,sourceBook,{chapterUid=s.chapterUid},{{range=s.range}},1)[1]
   assert(group,'RELATED_SOURCE_INVALID');group.range=row.range;group.foreign=s;group.quote=row.quote;result[#result+1]=group
  else result[#result+1]=API.groups(client,book,chapter,{row},1)[1]end
 end
 return result
end
function M.moreGroup(client,book,chapter,group)
 if not group.foreign then return require('readinknative/socialapi').moreGroup(client,book,chapter,group)end
 local s=group.foreign;assert(M.validSource(s,book,chapter),'RELATED_SOURCE_INVALID')
 local info=require('readinknative/api').info(client,{bookId=s.bookId});assert(tostring(info.version or 0)==s.version,'RELATED_SOURCE_VERSION_CHANGED')
 local source={range=s.range,maxIdx=group.maxIdx,quote=group.quote}
 local data=require('readinknative/socialapi').moreGroup(client,{bookId=s.bookId},{chapterUid=s.chapterUid},source)
 data.range=group.range;data.foreign=s;return data
end
return M
