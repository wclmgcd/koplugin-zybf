-- Official PDF -> EPUB conversion, confirmed by source-bound real chapter
-- data. Catalog Book metadata is optional; original PDF storage stays separate.
local P={}
local function copy(value)return require('rapidjson').decode(require('rapidjson').encode(value))end
local function int(n,lo)return type(n)=='number'and n==n and n%1==0 and n>=lo and n<=2147483647 end
local function stage(name,operation)
 local ok,a,b=pcall(operation)
 if not ok then
  local code=require('readinknative/errors').code(a)
  require('logger').warn('ReadInk PDF text failure stage/code:',name,code)
  error(code..' PDF_STAGE_'..name,0)
 end
 return a,b
end
function P.entry(book)
 local list=book and book.otherType
 if type(list)=='string'and #list<=65536 then local ok,v=pcall(require('rapidjson').decode,list);list=ok and v or nil end
 if type(list)~='table'then return end
 for _,v in ipairs(list)do if type(v)=='table'and v.type=='epub'then return v end end
end
local function bound(book,vid)
 local m=book and book._pdfText
 return type(m)=='table'and m.schema==1 and m.vid==tostring(vid)and m.bookId==tostring(book.bookId)
  and book.format=='epub'and m.version==book.version and int(m.sourceVersion,0)and int(m.version,0)
end
function P.valid(book,vid)return bound(book,vid)and book._pdfText.pending~=true end
local function grant(book,vid)
 if tostring(book.bookId):match('^CB_')and bound(book,vid)and book._pdfText.owned then
  local now=os.time();book._readPermission={bookId=book.bookId,vid=vid,checkedAt=now,untilTime=now+300,accessUntil=now+300,allowed=true,reason='uploaded_pdf_text'}
 end
end
function P.retain(client,previous,info)
 if not P.valid(previous,client.data.vid)then return info end
 local m=previous._pdfText
 if info.format=='epub'then
  info._pdfText=copy(m);info._pdfText.version=info.version or m.version;info.version=info._pdfText.version
  if info.version~=m.version then info._pdfText.pending=true end
  grant(info,client.data.vid);return info
 end
 if info.format~='pdf'or tostring(info.version or 0)~=tostring(m.sourceVersion)or not P.entry(info)then return info end
 info.format='epub';info.version=m.version;info._pdfText=copy(m);grant(info,client.data.vid);return info
end
function P.catalogBook(client,book,metadata)
 local m=assert(book._pdfText,'PDF_TEXT_UNVERIFIED');local verified=P.valid(book,client.data.vid)
 assert((metadata==nil or type(metadata)=='table')and(m.conversionReady==true or verified),'PDF_TEXT_UNVERIFIED')
 assert(not metadata or metadata.bookId==nil or tostring(metadata.bookId)==tostring(book.bookId),'PDF_TEXT_UNVERIFIED')
 local format=metadata and metadata.format
 require('logger').info('ReadInk PDF text catalog metadata present/format/version-kind:',metadata~=nil,
  type(format)=='string'and(format:match('^[A-Za-z]+$')or'empty_or_other')or'missing',type(metadata and metadata.version))
 assert(format==nil or format==''or type(format)=='string'and(format:lower()=='epub'or format:lower()=='pdf'),'PDF_TEXT_UNVERIFIED')
 -- ChapterListInterface.book is nullable in the official service. It updates
 -- an existing Book when present; its omission does not erase known metadata.
 local version=metadata and metadata.version
 if version==nil or version==''then version=book.version end
 if type(version)=='string'and version:match('^%d+$')then version=tonumber(version)end
 assert(int(version,0),'PDF_TEXT_UNVERIFIED')
 local unchanged=verified and book.version==version
 for _,key in ipairs{'title','author','cover','paid','payType','maxFreeChapter','maxFreeInfo','isChapterPaid'}do if metadata and metadata[key]~=nil then book[key]=metadata[key]end end
 m.pending=not unchanged or nil;m.conversionReady=true
 book.version=version;assert(int(book.version,0),'PDF_TEXT_UNVERIFIED');m.version=book.version;grant(book,client.data.vid)
end
function P.confirm(book,vid,chapter,path)
 assert(bound(book,vid)and book._pdfText.conversionReady==true,'PDF_TEXT_UNVERIFIED')
 -- The original source entry is created only after info.txt has matched the
 -- requested book and chapter, and its declared XHTML files were unpacked.
 -- Cached originals must additionally bind to this exact book/version/chapter.
 local R=require('readinknative/socialranges');local source=R.cachedSource(path,book,chapter)
 assert(R.valid(source,book,chapter)and type(source.html)=='string','PDF_TEXT_UNVERIFIED')
 book._pdfText.pending=nil;grant(book,vid);return true
end
function P.probe(client,original,options)
 options=options or{};assert(not original.localFile,'PDF_TEXT_UNAVAILABLE')
 local A=require('readinknative/api');local raw=stage('INFO',function()return A.info(client,original)end)
 if raw._pdfText then raw=copy(raw);raw.format='pdf';raw.version=raw._pdfText.sourceVersion;raw._pdfText=nil end
 -- A server that has selected the text representation may already return an
 -- EPUB Book here. Keep the known shelf PDF version for its separate cache;
 -- the catalog below must still independently verify the EPUB/version.
 if raw.format=='epub'and original.format=='pdf'and P.entry(raw)then
  raw=copy(raw);raw.format='pdf';raw.version=original.version or 0
 end
 stage('INFO',function()assert(raw.format=='pdf'and tostring(raw.bookId)==tostring(original.bookId)and P.entry(raw),'PDF_TEXT_UNAVAILABLE')end)
 -- showType is a local display preference in the official app, not proof
 -- that its conversion/page mapping is ready. Official entry always polls.
 local mapping=stage('CONVERT',function()
  local page=options.page or 1;assert(int(page,1),'PDF_TEXT_UNVERIFIED')
  local result=client:api('/trans/pdfepub',{cbid=tostring(raw.bookId),transFormat='epub',uid=page,pollPdf2Epub=1})
  assert(type(result)=='table','PDF_TEXT_UNVERIFIED')
  if result.transStatus=='transing'then error('PDF_TEXT_TRANSING')end
  assert(result.transStatus=='succ','PDF_TEXT_UNAVAILABLE')
  -- A first opening does not need a page-to-text location. Never invent an
  -- offset when the service omits it; later PDF pages still require mapping.
  if not(int(result.chapterUid,1)and int(result.chapterOffset,0))then
   assert(page==1 or options.resumeChapterUid,'PDF_TEXT_UNVERIFIED');return nil
  end
  return result
 end)
 local book=copy(raw);book.format='epub';book.version=raw.version or 0
 book._pdfText={schema=1,vid=tostring(client.data.vid),bookId=tostring(raw.bookId),sourceVersion=raw.version or 0,
  version=book.version,owned=options.fromShelf==true and tostring(raw.bookId):match('^CB_')~=nil,pending=true,conversionReady=true}
 -- The catalog supplies the real chapter IDs. Its optional Book may update
 -- the known download version; the actual body confirms the representation.
 local chapters=stage('CATALOG',function()return A.catalog(client,book)end)
 local selected,index
 local wanted=options.resumeChapterUid or mapping and mapping.chapterUid
 for i,ch in ipairs(chapters)do if wanted and tostring(ch.chapterUid)==tostring(wanted)then selected,index=ch,i;break end end
 if mapping then stage('POSITION',function()assert(selected,'PDF_TEXT_UNVERIFIED')end)end
 selected=selected or chapters[1];index=index or 1
 return{book=book,catalog=chapters,chapter=selected,index=index,target=mapping and not options.resumeChapterUid and{cloudOffset=mapping.chapterOffset}or nil,original=raw}
end
function P.prepare(client,original,options)
 local value=P.probe(client,original,options);local A=require('readinknative/api')
 local prepared=stage('BODY',function()
  local result=A.prepareChapter(client,value.book,value.chapter,false)
  assert(result.path and result.book.format=='epub'and P.valid(result.book,client.data.vid),'PDF_TEXT_UNVERIFIED');return result
 end)
 prepared.catalog=value.catalog;prepared.chapter=value.chapter;prepared.index=value.index;prepared.target=value.target;prepared.original=value.original
 prepared.context=A.readContext(client,prepared.book,prepared.catalog)
 -- Visible text uses the same asynchronous first-mark path as other CB books.
 return prepared
end

function P.cached(a,original)
 local saved=(a.state.pdfText or{})[tostring(original.bookId)]
 if not saved or saved.sourceVersion~=(original.version or 0)or type(saved.catalog)~='table'or not P.valid(saved.book,a.client.data.vid)then return end
 local last=(a.state.last or{})[tostring(original.bookId)]
 local chapter=require('readinknative/readingstart').choose(a.state,saved.book,saved.catalog)
 if not last and saved.chapterUid then for _,ch in ipairs(saved.catalog)do if tostring(ch.chapterUid)==tostring(saved.chapterUid)then chapter=ch;break end end end
 if not chapter then return end
 if not require('readinknative/cache').find(a.client.data.vid,saved.book,chapter)then return end
 return saved.book,saved.catalog,chapter,not last and saved.target or nil
end
function P.remember(a,result)
 assert(P.valid(result.book,a.client.data.vid),'PDF_TEXT_UNVERIFIED')
 local id=tostring(result.book.bookId);a.state.pdfText=a.state.pdfText or{}
 a.state.pdfText[id]={sourceVersion=result.book._pdfText.sourceVersion,book=copy(result.book),catalog=result.catalog,
  chapterUid=result.chapter and tostring(result.chapter.chapterUid),target=result.target}
 a.state.catalogs[id]=result.catalog
 for _,original in ipairs(a.state.books or{})do if tostring(original.bookId)==id and original.format=='pdf'then
  original.version=result.book._pdfText.sourceVersion;original.otherType=result.original and result.original.otherType or original.otherType
 end end
 a.state:flush()
end
local function accept(a,result)
 P.remember(a,result)
 local context=result.context or require('readinknative/api').readContext(a.client,result.book,result.catalog)
 context.pdfTextChapter=result.chapter;context.pdfTextTarget=result.target
 a:openBook(result.book,nil,context)
end
function P.open(a,original)
 local state,vid,doc,mode=a.state,a.client.data.vid,a.document,a.mode
 local function valid()return not a.closed and not a.suspended and a.state==state and a.client.data.vid==vid and a.document==doc and a.mode==mode end
 local book,catalog,chapter,target=P.cached(a,original)
 if book then return accept(a,{book=book,catalog=catalog,chapter=chapter,target=target})end
 local owned=false;for _,b in ipairs(state.books or{})do if not b.localFile and tostring(b.bookId)==tostring(original.bookId)then owned=true;break end end
 local position=state:position(original,nil);local last=state.last[tostring(original.bookId)]
 local options={fromShelf=owned,page=position and position.pdf and position.page or 1,resumeChapterUid=last and last.chapterUid}
 local token={};a.pdfTextOpening=token
 local function current()return a.pdfTextOpening==token and valid()end
 local function fallback(reason)
  if not current()then return end;a.pdfTextOpening=nil
  local code=require('readinknative/errors').code(reason)
  local labels={INFO='图书信息',CONVERT='文字转换',CATALOG='文字目录',POSITION='页码定位',BODY='文字正文'}
  local step=tostring(reason):match('PDF_STAGE_([A-Z]+)')
  local message=require('readinknative/errors').message(reason)
  message=message..'\n'..(labels[step]and('失败环节：'..labels[step]..'；')or'')..'错误码：'..code
  local UI=require('ui/uimanager');local dialog
  dialog=require('ui/widget/buttondialog'):new{title=message,buttons={
   {{text='继续原版 PDF',callback=function()UI:close(dialog);if valid()then require('readinknative/pdfbooks').openOriginal(a,original)end end}},
   {{text='重试文字模式',callback=function()UI:close(dialog);if valid()then P.open(a,original)end end}},
   {{text='取消',callback=function()UI:close(dialog)end}}}}
  UI:show(dialog)
 end
 return a:remote('准备官方 PDF 文字模式',function(client)return P.prepare(client,original,options)end,function(result)
  if not current()then return end;a.pdfTextOpening=nil;accept(a,result)
 end,nil,{valid=current,failed=fallback,cancelled=function()if a.pdfTextOpening==token then a.pdfTextOpening=nil end end})
end
return P
