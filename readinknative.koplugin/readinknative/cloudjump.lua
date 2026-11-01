-- Resolve a cloud source range in a cancellable worker, then use its CRe pointer.
local M={}
function M.locate(document,path,book,chapter,range,quote)
 local R=require('readinknative/socialranges');local P=require('readinknative/readingposition')
 if type(range)~='string'or not range:match('^%d+%-%d+$')then return end
 local index=P.source(path,book,chapter);if not index then return end
 local needle=P.compact(quote or'');if needle==''then return end
 local candidates=P.ranges(index,quote);if not candidates then return end
 local selected;for i,r in ipairs(candidates)do if r==range then selected=i;break end end
 if not selected then return end
 local hits=document.doc:findAllText(quote,false,0,2001,false,0x00FF)
 -- The original source range selects an occurrence; never guess by first hit.
 if not hits or #hits~=#candidates or #hits>2000 then return end
 local h=hits[selected]
 if h and document.doc:isXPointerInDocument(h.start)and document.doc:isXPointerInDocument(h['end'])then return{xpointer=h.start,endXPointer=h['end']}end
end
function M.open(a,row)
 local social=require('readinknative/social');local owned=false
 for _,r in ipairs(social.records(a))do if r==row then owned=true;break end end
 if not owned or row.kind~='highlight'then return end
 local record=row.bookmark or row.review;local chapter,index
 for i,ch in ipairs(a:catalogItems())do if tostring(ch.chapterUid)==tostring(row.chapterUid)then chapter,index=ch,i;break end end
 if not chapter or not record or type(record.range)~='string'then a:message('云端划线缺少原文位置，请刷新笔记后重试。');return end
 if record.bookVersion and tostring(record.bookVersion)~=tostring(a.book.version)then a:message('这条云端划线属于另一版本，无法精确定位。');return end
 local book,state,document,mode=a.book,a.state,a.document,a.mode;local body=a.view.layout.body;local format=state:format(book)
 local quote=row.quote or row.text
 local snapshot=a.client.data;local vid=tostring(snapshot.vid)
 local function valid()return not a.closed and not a.suspended and a.state==state and a.book==book and a.document==document and a.mode==mode and tostring(a.client.data.vid)==vid end
 require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel()
 local function work(client)
  local path=require('readinknative/cache').find(client.data.vid,book,chapter);local result
  if not path then result=require('readinknative/api').chapter(client,book,chapter);path=result.path end
  assert(not result or tostring(result.book.version)==tostring(book.version),'SOCIAL_SOURCE_VERSION_CHANGED')
  require('readinknative/socialranges').load(client,book,chapter,path,{})
  local doc=require('readinknative/document').open(path,body.w,body.h,format.size,nil,format,'prepare')
  local ok,pointer=pcall(M.locate,doc,path,book,chapter,record.range,quote);doc:close()
  assert(ok and pointer,'ANNOTATION_SYNC_RANGE_UNMATCHED');return pointer
 end
 return a.jobs:run('定位划线原文',function()
  local client=require('readinknative/client'):new(snapshot)
  local good,pointer=pcall(work,client)
  return{ok=good,pointer=good and pointer or nil,error=not good and pointer or nil},client.data
 end,function(ok,result,session)
  if not valid()then return end
  if not ok or not result.ok then a:failure(ok and result.error or result);return end
  if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
  a:selectChapter(chapter,index,result.pointer)
 end)
end
return M
