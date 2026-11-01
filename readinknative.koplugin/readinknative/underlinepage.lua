-- Quote filtering/searches are batched outside paint. The compact reader may
-- request a bounded event-time pass; its remaining work uses a cancellable fork.
-- No cap discards dense-page marks.
local M={BATCH=4}
-- A sparse original-source index, not an offset table for every byte. A block
-- holds 64 displayed scalars; its raw UTF-16 bounds conservatively include
-- intervening markup. This avoids treating a shared sentence tail as hundreds
-- of candidates and keeps the index small on low-memory devices.
function M.anchor(source)
 if type(source)~='table'then return end
 local raw=source.text or source.html;if type(raw)~='string'then return end
 local plain=source.format=='txt';local parts,blocks={},{};local i,u,size,chars=1,0,0,0;local body=plain;local skip
 local function scalar(s,p)local b=s:byte(p);local n=b<128 and 1 or b<224 and 2 or b<240 and 3 or 4;return s:sub(p,p+n-1),n,n==4 and 2 or 1 end
 local function emit(c,first,last)
  if c:match('^%s$')or c==' 'or c=='　'or c=='\226\128\168'or c=='\226\128\169'then return end
  if chars%64==0 then blocks[#blocks+1]={byte=size+1,first=first}end
  parts[#parts+1]=c;size=size+#c;chars=chars+1;blocks[#blocks].last=last
 end
 while i<=#raw do
  if not plain and raw:sub(i,i)=='<'then
   local finish=raw:find('>',i,true);if not finish then return end
   if raw:sub(i,i+3)=='<!--'then local e=raw:find('-->',i+4,true);if not e then return end;finish=e+2 end
   local tag=raw:sub(i,finish):lower()
   if tag:match('^<body%f[%s>]')then body=true elseif tag:match('^</body%s*>')then body=false
   elseif tag:match('^<script%f[%s>]')then skip='script'elseif tag:match('^<style%f[%s>]')then skip='style'
   elseif skip and tag:match('^</'..skip..'%s*>')then skip=nil end
   while i<=finish do local _,n,units=scalar(raw,i);u=u+units;i=i+n end
  elseif not plain and raw:sub(i,i)=='&'and body and not skip then
   local e=raw:find(';',i+1,true);local entity=e and e-i<=32 and raw:sub(i,e)
   local text=entity and require('util').htmlEntitiesToUtf8(entity)
   if entity and text~=entity then
    local p=1;while p<=#text do local c,n=scalar(text,p);emit(c,u,u+#entity);p=p+n end
    u=u+#entity;i=e+1
   else local c,n,units=scalar(raw,i);emit(c,u,u+units);u=u+units;i=i+n end
  else
   local c,n,units=scalar(raw,i);if body and not skip then emit(c,u,u+units)end;u=u+units;i=i+n
  end
 end
 return{text=table.concat(parts),blocks=blocks}
end
function M.bounds(document,anchor,text)
 if not anchor or text==''then return end
 local raw=anchor.text
 local function unique(q)
  local first,last=raw:find(q,1,true)
  if first and not raw:find(q,first+1,true)then return first,last end
 end
 local left,right=unique(text)
 local atEnd=document.isScroll and document:isScroll()and document:scrollPos()>=document:scrollMax()
     or document:page()+document.doc:getVisiblePageCount()-1>=document:count()
 if not left and atEnd and raw:sub(-#text)==text then left=#raw-#text+1;right=#raw end
 if not left then for _,bytes in ipairs{96,192,384,768}do
  local a=unique(text:sub(1,bytes));local _,b=unique(text:sub(-bytes))
  if a and b and a<=b then left=a;right=b;break end
 end end
 if not left then return end
 local first,last
 for _,block in ipairs(anchor.blocks)do
  if block.byte<=left then first=block.first end
  if block.byte<=right then last=block.last else break end
 end
 if first and last then return first,last end
end
local function firstScalar(s)
 local b=s:byte(1);if not b then return ''end
 return s:sub(1,b<128 and 1 or b<224 and 2 or b<240 and 3 or 4)
end
-- Include ranges starting/ending at a page edge, and long ranges covering an
-- entire middle page. Compacting only filters candidates; exact unique CRe
-- matching remains mandatory before making a clickable mark.
function M.overlaps(page,quote)
 if page==''or quote==''then return false end
 if page:find(quote,1,true)or quote:find(page,1,true)then return true end
 local at=1;local lead=firstScalar(quote)
 while at<=#page do
  local p=page:find(lead,at,true);if not p then break end
  if page:sub(p)==quote:sub(1,#page-p+1)then return true end;at=p+#lead
 end
 at=1;lead=firstScalar(page)
 while at<=#quote do
  local p=quote:find(lead,at,true);if not p then break end
  if quote:sub(p)==page:sub(1,#quote-p+1)then return true end;at=p+#lead
 end
 return false
end
function M.visible(document)
 -- Screen endpoints cover the complete last page and both landscape columns.
 -- Reading progress's short last-node fallback is unsuitable for this job.
 local d=document.doc
 -- Ordinary pages have stable native page boundaries. Avoid two pixel hit
 -- tests; the final page/spread still needs the complete screen-box fallback.
 local page,count,columns=document:page(),document:count(),d:getVisiblePageCount()
 if not(document.isScroll and document:isScroll())and page+columns<=count then
  local first,last=d:getPageXPointer(page),d:getPageXPointer(page+columns)
  local text=first and last and d:getTextFromXPointers(first,last)
  if type(text)=='string'and text~=''then return require('readinknative/readingposition').compact(text)end
 end
 local range=d:getTextFromPositions({x=0,y=0},{x=document.w-1,y=document.h-1},true)
 local text=type(range)=='table'and range.text
 if type(text)=='string'and text~=''then return require('readinknative/readingposition').compact(text)end
 -- CRe returns no range if the bottom-right endpoint is in the empty second
 -- column of a final spread. Query each real column, retaining the complete
 -- first column rather than reducing the last page to its first text node.
 local columns=d:getVisiblePageCount();local parts={}
 if columns>1 then for column=1,columns do
  local left=math.floor((column-1)*document.w/columns);local right=math.floor(column*document.w/columns)-1
  local r=d:getTextFromPositions({x=left,y=0},{x=right,y=document.h-1},true)
  if r and type(r.text)=='string'then parts[#parts+1]=r.text end
 end end
 if #parts>0 then return require('readinknative/readingposition').compact(table.concat(parts,' '))end
 return ''
end
function M.batch(document,rows,indices,book,chapter,anchor,options)
 local limit=options and options.budget or M.BATCH
 local R=require('readinknative/socialranges');local newAnchor;local updates={};local indexSource
 local migrate=false;for _,r in ipairs(rows)do if r.needsFragments then migrate=true;break end end
 if migrate then
  if options and options.eager then return{deferred=true,updates={},remaining={},more=true,searches=0}end
  local ok,source=pcall(R.cachedSource,document.path,book,chapter)
  if ok and source then indexSource=source;R.populate(source,rows);if not anchor then anchor=M.anchor(source);newAnchor=true end end
  for i,r in ipairs(rows)do
   r.needsFragments=nil
   updates[#updates+1]={index=i,quote=r.quote,endpoints=r.endpoints,enriched=true,position=r.position,resolved=r.resolved}
  end
 end
 local coordinateAttempted,coordinates=false,0
 if options and options.coordinates and not options.eager and not indices then
  coordinateAttempted=true
  local ok,result,reason=pcall(function()
   local source=options.source or indexSource or R.cachedSource(document.path,book,chapter)
   indexSource=source;if not anchor then anchor=M.anchor(source);newAnchor=true end
   return require('readinknative/coordinateindex').resolve(document,source,rows,book,chapter)
  end)
  if ok and result then
   for _,u in ipairs(result)do rows[u.index].position=u.position;rows[u.index].resolved=true;updates[#updates+1]=u end
   coordinates=#result
  end
  if anchor then anchor.coordinateAttempted=true;newAnchor=true end
  require('logger').info('ReadInk coordinate index status/positions:',ok and(reason or'source_missing')or'index_deferred',coordinates)
 end
 if not indices then
  if options and options.eager and #rows>128 and not anchor then return{deferred=true,updates={},remaining={},more=true,searches=0}end
  indices={};local page=M.visible(document);local P=require('readinknative/readingposition')
  if not anchor and book and chapter then anchor=M.anchor(R.cachedSource(document.path,book,chapter));newAnchor=true end
  local first,last=M.bounds(document,anchor,page)
  if options and options.eager and #rows>128 and not first then return{deferred=true,updates={},remaining={},more=true,searches=0}end
  for i,row in ipairs(rows)do
   local p=row.position
   local a,b=row.range:match('^(%d+)%-(%d+)$');local nearby=not first or tonumber(a)<last and tonumber(b)>first
   local valid=nearby and p and document.doc:isXPointerInDocument(p.xpointer)and document.doc:isXPointerInDocument(p.endXPointer)
   if nearby and not valid and(not row.resolved or p)and type(row.quote)=='string'and M.overlaps(page,P.compact(row.quote))then indices[#indices+1]=i end
  end
 end
 -- Candidate extraction has its own cost. The search budget starts here so a
 -- slow viewport read cannot postpone every current-page mark to a later frame.
 local deadline=options and options.seconds and require('socket').gettime()+options.seconds
 local remaining={};local searched={};local calls=0
 for _,i in ipairs(indices)do
  local row=rows[i];local e=row.endpoints;local memoKey=table.concat({row.quote,e and e.first or'',e and e.last or''},'\0');local memo=searched[memoKey]
  if not(options and options.eager and e)and(memo~=nil or calls<limit and(not deadline or require('socket').gettime()<deadline))then
   if memo==nil then calls=calls+1;memo=R.position(document,row.quote,e)or false;searched[memoKey]=memo end
   row.position=memo or nil;row.resolved=true
   updates[#updates+1]={index=i,position=row.position,resolved=true}
  else remaining[#remaining+1]=i end
 end
 return{updates=updates,remaining=remaining,more=#remaining>0,searches=calls,candidates=#indices,coordinateAttempted=coordinateAttempted,coordinates=coordinates,anchor=newAnchor and anchor and #anchor.text<=256*1024 and anchor or nil}
end
return M
