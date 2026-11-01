-- A bounded, derived spine. Public paths and XPointers always address the
-- original chapter; only this adapter sees composite fragment/page offsets.
-- Construction never opens a second CRe DOM or fetches content/permissions.
local W={MAX_CHAPTERS=4,MAX_BYTES=2*1024*1024,MAX_UNPACKED=6*1024*1024,MAX_WORDS=24000,MAX_FRAGMENTS=32}
local function stamp(p)return require('readinknative/pagination').fileStamp(p)end
local function uid(ch)return tostring(ch.chapterUid)end
local function xml(s)return tostring(s):gsub('&','&amp;'):gsub('<','&lt;'):gsub('"','&quot;')end
local function attr(s,k)local q,v=s:match(k..'%s*=%s*([\'"])(.-)%1');return v and require('util').htmlEntitiesToUtf8(v)end
local function decode(s)return(s:gsub('%%(%x%x)',function(x)return string.char(tonumber(x,16))end))end
function W.plan(a)
 if not(a.continuousReader or require('device'):isKindle())or a.continuousReader==false or not a.book or a.book.localFile or a.book.article or not a.chapter or not a.chapters then return end
 local body=a.view.layout.body;local f=a.state:format(a.book)
 -- Two-column spreads may share a chapter boundary. Keep the established
 -- single-chapter route until a spread can be represented without overlap.
 if f.view_mode==1 or require('readinknative/format').visiblePages(f,body.w,body.h)>1 then return end
 local compact=require('readinknative/chapterloader').compact(a)
 local direction=a.readingDirection==-1 and -1 or 1;local center=a.chapterIndex
 if not center or not a.chapters[center]or uid(a.chapters[center])~=uid(a.chapter)then return end
 local rows,seen,bytes,words={}, {},0,0
 local order={center,center+direction,center+2*direction,center-direction}
 for _,index in ipairs(order)do
  local ch=a.chapters[index]
  if ch then
   local path,mode=require('readinknative/cache').find(a.client.data.vid,a.book,ch)
   local size=path and require('libs/libkoreader-lfs').attributes(path,'size');local count=tonumber(ch.wordCount)
   if not path or not require('readinknative/images').ready(path)or mode~='full'or not size or not count or count<0 or bytes+size>W.MAX_BYTES or words+count>(compact and 12000 or W.MAX_WORDS)then
    if index==center then return end
   elseif not seen[path]and #rows<(compact and 3 or W.MAX_CHAPTERS)then
    rows[#rows+1]={path=path,stamp=stamp(path),chapter=ch,index=index};seen[path]=true;bytes=bytes+size;words=words+count
   end
  end
 end
 table.sort(rows,function(x,y)return x.index<y.index end)
 -- Never skip an unavailable logical neighbor, including shared-resource
 -- aliases. The controller's ordinary boundary route remains authoritative.
 for i=2,#rows do if rows[i].index~=rows[i-1].index+1 then return end end
 if #rows<2 then return end
 local parts={'continuous-spine-v1',tostring(a.client.data.vid),tostring(a.book.bookId),tostring(a.book.version or 0)}
 for _,r in ipairs(rows)do parts[#parts+1]=uid(r.chapter);parts[#parts+1]=r.stamp end
 local key=require('ffi/sha2').sha256(table.concat(parts,'|'))
 return{key=key,path=require('readinknative/paths').cache(a.client.data.vid,key..'-full.epub'),rows=rows,
  vid=a.client.data.vid,bookId=tostring(a.book.bookId),version=tostring(a.book.version or 0),bytes=bytes}
end
function W.valid(a,s)
 if not s or not a.book or tostring(a.client.data.vid)~=tostring(s.vid)or tostring(a.book.bookId)~=s.bookId or tostring(a.book.version or 0)~=s.version then return false end
 for _,r in ipairs(s.rows)do
  local path,mode=require('readinknative/cache').find(s.vid,a.book,r.chapter)
  if path~=r.path or not require('readinknative/images').ready(path)or mode~='full'or stamp(path)~=r.stamp then return false end
 end
 return true
end
function W.build(s)
 local C=require('readinknative/content');local entries,manifest,spine={}, {},{};local total,fragments=0,0
 for i,row in ipairs(s.rows)do
  assert(stamp(row.path)==row.stamp,'WINDOW_SOURCE_CHANGED')
  local f=assert(require('readinknative/cachefiles').open(row.path,'rb'));local data=f:read(W.MAX_BYTES+1);f:close();assert(#data<=W.MAX_BYTES,'WINDOW_SIZE')
  local files=C.unpack(data,nil,nil,false,{entry=W.MAX_UNPACKED,total=W.MAX_UNPACKED,files=256});local opf=assert(files['OEBPS/readink-native.opf'],'WINDOW_FORMAT');local ids={}
  local prefix='c'..i..'/'
  for tag in opf:gmatch('<item%s[^>]->')do
   local id,href,media=attr(tag,'id'),attr(tag,'href'),attr(tag,'media%-type')
   if id~='ncx'then
    assert(id and href and media,'WINDOW_MANIFEST');local name=decode(href);assert(C.safePath(name)and files['OEBPS/'..name],'WINDOW_RESOURCE')
    ids[id]={id='c'..i..'_'..id,name=name,media=media}
    manifest[#manifest+1]='<item id="'..xml(ids[id].id)..'" href="'..xml(prefix..href)..'" media-type="'..xml(media)..'"/>'
   end
  end
  row.firstFragment=fragments+1
  for tag in opf:gmatch('<itemref%s[^>]->')do
   local item=ids[attr(tag,'idref')];assert(item and item.media=='application/xhtml+xml','WINDOW_SPINE')
   fragments=fragments+1;assert(fragments<=W.MAX_FRAGMENTS,'WINDOW_FRAGMENTS');spine[#spine+1]='<itemref idref="'..xml(item.id)..'"/>'
  end
  row.fragments=fragments-row.firstFragment+1;assert(row.fragments>0,'WINDOW_EMPTY')
  for name,body in pairs(files)do
   if name:sub(1,6)=='OEBPS/'and name~='OEBPS/readink-native.opf'and name~='OEBPS/readink-native.ncx'then
    total=total+#body;assert(total<=W.MAX_UNPACKED,'WINDOW_UNPACKED');entries[#entries+1]={path='OEBPS/'..prefix..name:sub(7),body=body}
   end
  end
  assert(stamp(row.path)==row.stamp,'WINDOW_SOURCE_CHANGED')
 end
 entries[#entries+1]={path='OEBPS/readink-native.opf',body='<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">'..s.key..'</dc:identifier><dc:title>ReadInk</dc:title><dc:language>zh-CN</dc:language></metadata><manifest>'..table.concat(manifest)..'</manifest><spine>'..table.concat(spine)..'</spine></package>'}
 entries[#entries+1]={path='META-INF/container.xml',body='<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/readink-native.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'}
 C.write(entries,s.path);return s
end
function W.discard(s,providerPath)
 if not s then return end
 local expected=require('readinknative/paths').cache(s.vid,s.key..'-full.epub')
 if s.path~=expected then return end
 for _,r in ipairs(s.rows)do if r.path==expected then return end end
 local F=require('readinknative/cachefiles');F.remove(expected);F.remove(expected..'.part')
 local name=s.key..'-full.epub';local mirror=require('readinknative/cachepath').mirror(require('readinknative/paths').account(s.vid),name)
 if providerPath==mirror then F.remove(mirror);F.remove(mirror..'.stamp');pcall(require('libs/libkoreader-lfs').rmdir,mirror:match('^(.*)/[^/]+$'))end
end
function W.stop(a,drop)
 local retired=a.windowBuilding
 if a.windowJobs then a.windowJobs:cancel()end;a.windowBuilding=nil
 if retired then
  local job=a.windowJobs and a.windowJobs.active
  local function cleanup()
   if job and a.windowJobs.active==job then require('ui/uimanager'):scheduleIn(0.05,cleanup);return end
   local active=a.document and a.document.window
   if not(a.windowBuilding and a.windowBuilding.key==retired.key)and not(a.windowReady and a.windowReady.key==retired.key)and not(active and active.spec.key==retired.key)then W.discard(retired)end
  end
  require('ui/uimanager'):scheduleIn(0.05,cleanup)
 end
 if drop then W.discard(a.windowReady);a.windowReady=nil end
end
local function rejectedKey(a,s)
 local b=a.view.layout.body
 return s.key..':'..b.w..':'..b.h..':'..require('readinknative/format').signature(a.state:format(a.book))
end
local function rejected(a,s)return a.windowRejected and a.windowRejected[rejectedKey(a,s)]end
local function reject(a,s)
 if(a.windowRejectedCount or 0)>=16 then a.windowRejected={};a.windowRejectedCount=0 end
 a.windowRejected=a.windowRejected or{};local key=rejectedKey(a,s)
 if not a.windowRejected[key]then a.windowRejectedCount=(a.windowRejectedCount or 0)+1 end
 a.windowRejected[key]=true
end
function W.prefetch(a)
 if a.closed or a.suspended or a.mode~='reader'or not a.document then return end
 local free=require('util').calcFreeMem();if not free or free<64*1024*1024 or a.chapterLoading or(a.offlineRuntime and a.offlineRuntime.busy)or require('readinknative/socialreader').busy(a)then return end
 local active=a.document.window
 if active and W.valid(a,active.spec)then
  local target=(a.chapterIndex or 1)+(a.readingDirection==-1 and -1 or 1)
  for _,r in ipairs(active.spec.rows)do if r.index==target then return end end
 end
 local s=W.plan(a);if not s or rejected(a,s)then return end
 if a.windowReady and a.windowReady.key==s.key and W.valid(a,a.windowReady)or a.windowBuilding and a.windowBuilding.key==s.key then return end
 W.stop(a);local state,doc=a.state,a.document;a.windowBuilding=s
 a.windowJobs=a.windowJobs or require('readinknative/inkjobs').new{NICE=10}
 a.windowJobs:run('',function()return W.build(s)end,function(ok,result)
  if a.windowBuilding~=s then return end;a.windowBuilding=nil
  if not a.closed and not a.suspended and a.state==state and a.document==doc and ok and W.valid(a,result)then W.discard(a.windowReady);a.windowReady=result
  elseif ok then W.discard(result)end
 end,false)
end
local function convert(pointer,row,out)
 if type(pointer)~='string'then return end
 local root,n,tail=pointer:match('^(/body%[?1?%]?)/DocFragment%[(%d+)%](.*)$')
 if not root then root,tail=pointer:match('^(/body%[?1?%]?)/DocFragment(/.*)$');n=1 end
 if not root then return end;n=tonumber(n)
 if out then n=n-row.firstFragment+1 else if n<1 or n>row.fragments then return end;n=n+row.firstFragment-1 end
 if n<1 or n> (out and row.fragments or row.firstFragment+row.fragments-1)then return end
 return root..'/DocFragment'..(out and row.fragments==1 and''or('['..n..']'))..tail
end
function W.attach(d,s,chapter)
 local raw=d.doc;local adapter={raw=raw,spec=s};d.window=adapter;d.readerCacheSpec=nil
 local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);');adapter.pid=tonumber(ffi.C.getpid())
 function adapter:measure()
  local previous=0
  for _,r in ipairs(s.rows)do
   r.firstPage=raw:getPageFromXPointer('/body/DocFragment['..r.firstFragment..']/body')
   assert(type(r.firstPage)=='number'and r.firstPage>previous,'WINDOW_SHARED_PAGE');previous=r.firstPage
  end
  for i,r in ipairs(s.rows)do r.lastPage=s.rows[i+1]and s.rows[i+1].firstPage-1 or raw:getPageCount();assert(r.lastPage>=r.firstPage,'WINDOW_EMPTY_PAGE')end
 end
 function adapter:choose(ch)
  for _,r in ipairs(s.rows)do if uid(ch)==uid(r.chapter)then self.row=r;d.path=r.path;return true end end
  return false
 end
 adapter:measure();assert(adapter:choose(chapter),'WINDOW_CHAPTER')
 local function incoming(p)return convert(p,adapter.row,false)end
 local function outgoing(p)return convert(p,adapter.row,true)end
 local methods={}
 function methods:getCurrentPage()return math.max(1,raw:getCurrentPage()-adapter.row.firstPage+1)end
 function methods:getPageCount()return adapter.row.lastPage-adapter.row.firstPage+1 end
 function methods:gotoPage(p)return raw:gotoPage(adapter.row.firstPage+math.max(0,math.min(self:getPageCount()-1,p-1)))end
 function methods:getPageFromXPointer(p)local q=incoming(p);if q then return raw:getPageFromXPointer(q)-adapter.row.firstPage+1 end end
 function methods:getPageXPointer(p)return outgoing(raw:getPageXPointer(adapter.row.firstPage+p-1))end
 function methods:getXPointer()return outgoing(raw:getXPointer())end
 function methods:isXPointerInDocument(p)local q=incoming(p);return q and raw:isXPointerInDocument(q)or false end
 function methods:getNormalizedXPointer(p)local q=incoming(p);return q and outgoing(raw:getNormalizedXPointer(q))end
 function methods:getTextFromXPointer(p)local q=incoming(p);return q and raw:getTextFromXPointer(q)end
 function methods:compareXPointers(a,b)local x,y=incoming(a),incoming(b);if x and y then return raw:compareXPointers(x,y)end end
 function methods:getTextFromXPointers(a,b,...)local x,y=incoming(a),incoming(b);if x and y then return raw:getTextFromXPointers(x,y,...)end end
 function methods:getScreenBoxesFromPositions(a,b,...)local x,y=incoming(a),incoming(b);if x and y then return raw:getScreenBoxesFromPositions(x,y,...)end;return{}end
 function methods:getTextFromPositions(...)
  local value=raw:getTextFromPositions(...)
  if value then local r={};for k,v in pairs(value)do r[k]=v end;r.pos0=outgoing(r.pos0);r.pos1=outgoing(r.pos1);if r.pos0 and r.pos1 then return r end end
 end
 function methods:findAllText(query,case,context,max,regex,flags)
  local rows={};for _,r in ipairs(raw:findAllText(query,case,context,2000,regex,flags)or{})do
   local a,b=outgoing(r.start),outgoing(r['end']);if a and b and #rows<(max or 200)then local copy={};for k,v in pairs(r)do copy[k]=v end;copy.start=a;copy['end']=b;rows[#rows+1]=copy end
  end;return rows
 end
 function methods:getHTMLFromXPointer(p,...)
  if p=='/body'or p=='/body[1]'then
   local parts={'<body>'};for i=adapter.row.firstFragment,adapter.row.firstFragment+adapter.row.fragments-1 do parts[#parts+1]=assert(raw:getHTMLFromXPointer('/body/DocFragment['..i..']',...))end;parts[#parts+1]='</body>';return table.concat(parts)
  end
  local q=incoming(p);return q and raw:getHTMLFromXPointer(q,...)
 end
 function methods:getHTMLFromXPointers(a,b,...)local x,y=incoming(a),incoming(b);if x and y then return raw:getHTMLFromXPointers(x,y,...)end end
 function methods:getLinkFromPosition(...)
  local target,source=raw:getLinkFromPosition(...)
  if type(target)=='string'and target:sub(1,1)=='/'then target=outgoing(target)or'unavailable://'end
  return target,outgoing(source)
 end
 function methods:isLinkToFootnote(a,b,...)local x,y=incoming(a),incoming(b);if x and y then local ok,why,extra,first,last=raw:isLinkToFootnote(x,y,...);return ok,why,extra,outgoing(first),outgoing(last)end end
 function methods:render(...)local r=raw:render(...);adapter:measure();return r end
 function methods:getToc()return{}end -- The controller owns the server catalog.
 d.doc=setmetatable({}, {__index=function(_,k)
  if methods[k]then return methods[k]end
  local value=raw[k];if type(value)=='function'then return function(_,...)return value(raw,...)end end;return value
 end,__newindex=function(_,k,v)raw[k]=v end})
 return d
end
-- Only an inherited worker may move this borrowed engine to another chapter.
-- Its raw CRe is already loaded; no native open/close occurs here.
function W.workerView(d,ch)
 local w=d.window;if not w or tonumber(require('ffi').C.getpid())==w.pid then return end
 local view=setmetatable({doc=w.raw,path=d.path,w=d.w,h=d.h,font=d.font,format=d.format},getmetatable(d))
 W.attach(view,w.spec,ch);view:jump(1);return view
end
function W.contains(a,path,ch)
 local w=a.document and a.document.window;if not w or not W.valid(a,w.spec)then return false end
 if a.document.isScroll and a.document:isScroll()then return false end
 local body=a.view.layout.body;if a.document.w~=body.w or a.document.h~=body.h then return false end
 local F=require('readinknative/format');if F.signature(a.document.format)~=F.signature(a.state:format(a.book))then return false end
 for _,r in ipairs(w.spec.rows)do if r.path==path and uid(r.chapter)==uid(ch)then return true end end;return false
end
function W.take(a,path,w,h,font,format,position)
 -- This adapter translates page numbers and fragment XPointers. Pixel
 -- scrolling uses original chapters so no composite offset can escape it.
 if format.view_mode==1 or require('readinknative/format').visiblePages(format,w,h)>1 then return end
 local d=a.document
 if W.contains(a,path,a.chapter)and d.w==w and d.h==h then
  d.window:choose(a.chapter);d:jump(1);if position and position.xpointer then d:gotoPointer(position.xpointer)end;return d
 end
 local s=a.windowReady;if not W.valid(a,s)then return end
 local found=false;for _,r in ipairs(s.rows)do if r.path==path and uid(r.chapter)==uid(a.chapter)then found=true end end;if not found then return end
 a.windowReady=nil
 if rejected(a,s)then W.discard(s);return end
 if not require('libs/libkoreader-lfs').attributes(s.path,'size')then return end
 local success,opened=pcall(require('readinknative/document').open,s.path,w,h,font,nil,format,'single-reader')
 if not success then W.discard(s);require('logger').warn('ReadInk continuous spine open deferred');return end
 local ok,value=pcall(W.attach,opened,s,a.chapter)
 if not ok then reject(a,s);opened:close();W.discard(s,opened.providerPath);require('logger').warn('ReadInk continuous spine rejected; original chapter retained:',require('readinknative/errors').code(value));return end
 value:jump(1);if position and position.xpointer then value:gotoPointer(position.xpointer)end
 require('logger').info('ReadInk continuous spine chapters:',#s.rows);return value
end
return W
