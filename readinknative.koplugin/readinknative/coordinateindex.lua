-- A verified bridge between original UTF-16 ranges and CRe text nodes.
-- Build only in a cancellable worker. No second DOM, document mutation or
-- guessed correspondence: the complete compact text streams must agree.
local I={MAX_SOURCE=512*1024,MAX_HTML=2*1024*1024,MAX_TEXT=256*1024,MAX_NODES=8192,MAX_DEPTH=128}
local function scalar(s,p)
 local b=s:byte(p);local n=b<128 and 1 or b<224 and 2 or b<240 and 3 or 4
 return s:sub(p,p+n-1),n,n==4 and 2 or 1
end
local function white(c)return c:match('^%s$')or c==' 'or c=='　'or c=='\226\128\168'or c=='\226\128\169'end
local function units(s)local p,n=1,0;while p<=#s do local _,size,u=scalar(s,p);p=p+size;n=n+u end;return n end
local function tagEnd(s,p)
 local quote
 for i=p+1,#s do local c=s:sub(i,i)
  if quote then if c==quote then quote=nil end
  elseif c=='"'or c=="'"then quote=c elseif c=='>'then return i end
 end
end
local function original(source,rows)
 local raw=source.text or source.html;local plain=source.format=='txt'
 if type(raw)~='string'or #raw>I.MAX_SOURCE or require('util').fixUtf8(raw,'')~=raw then return nil,'source_size_or_encoding'end
 local wanted={};for _,r in ipairs(rows)do local a,b=r.range:match('^(%d+)%-(%d+)$');if a then wanted[tonumber(a)]=true;wanted[tonumber(b)]=true end end
 local offsets,parts={},{};local p,u,size=1,0,0;local body=plain;local skip
 local function emit(text)
  local i=1;while i<=#text do local c,n=scalar(text,i);if not white(c)then parts[#parts+1]=c;size=size+#c end;i=i+n end
 end
 while p<=#raw do
  if wanted[u]then offsets[u]=size end
  if not plain and raw:sub(p,p)=='<'then
   local finish=raw:sub(p,p+3)=='<!--'and raw:find('-->',p+4,true)
   if finish then finish=finish+2 else finish=tagEnd(raw,p)end
   if not finish then return nil,'source_markup'end
   local tag=raw:sub(p,finish);local close,name=tag:match('^<%s*(/?)%s*([%w:_%-]+)');name=name and name:lower()
   if skip then
    if name==skip and close=='/'then skip=nil end
   elseif name=='body'then
    if close=='/'then if not body then return nil,'source_body_balance'end;body=false
    else if body then return nil,'source_body_balance'end;body=true end
   elseif(name=='script'or name=='style')and close~='/'then skip=name end
   u=u+units(tag);p=finish+1
  elseif not plain and raw:sub(p,p)=='&'and body and not skip then
   local e=raw:find(';',p+1,true);local entity=e and e-p<=32 and raw:sub(p,e)
   local decoded=entity and require('util').htmlEntitiesToUtf8(entity)
   if entity and decoded~=entity then emit(decoded);u=u+#entity;p=e+1
   else local c,n,us=scalar(raw,p);emit(c);u=u+us;p=p+n end
  else
   local c,n,us=scalar(raw,p);if body and not skip then emit(c)end;u=u+us;p=p+n
  end
  if size>I.MAX_TEXT then return nil,'text_size'end
 end
 if not plain and(body or skip)then return nil,'source_body_balance'end
 if wanted[u]then offsets[u]=size end
 return{text=table.concat(parts),offsets=offsets}
end
local boxing={autoBoxing=true,floatBox=true,inlineBox=true,tabularBox=true,pseudoElem=true}
local hidden={head=true,style=true,script=true,stylesheet=true}
local function native(document)
 local doc=document.doc;local html=doc:getHTMLFromXPointer('/body',0,false)
 if type(html)~='string'or #html>I.MAX_HTML or require('util').fixUtf8(html,'')~=html then return nil,'native_size_or_encoding'end
 local root={path='',counts={}};local stack={};local nodes,parts={},{};local p,size,tags=1,0,0
 while p<=#html do
  local current=stack[#stack];local parent=current and current.logical or root
  if html:sub(p,p)=='<'then
   local finish=tagEnd(html,p);if not finish then return nil,'native_markup'end
   local tag=html:sub(p,finish);local close,name=tag:match('^<%s*(/?)%s*([%w:_%-]+)')
   if not name then return nil,'native_declaration'end
   if close=='/'then
    if not current or current.name~=name then return nil,'native_balance'end
    stack[#stack]=nil
   else
    tags=tags+1;if tags>4*I.MAX_NODES or #stack>=I.MAX_DEPTH then return nil,'native_node_limit'end
    local frame={name=name,skip=current and current.skip or hidden[name]}
    if boxing[name]then frame.logical=parent
    else
     parent.counts[name]=(parent.counts[name]or 0)+1
     frame.logical={path=parent.path..'/'..name..'['..parent.counts[name]..']',counts={}}
    end
    if not tag:match('/%s*>$')then stack[#stack+1]=frame end
   end
   p=finish+1
  else
   local finish=(html:find('<',p,true)or(#html+1))-1
   local text=require('util').htmlEntitiesToUtf8(html:sub(p,finish))
   if not current then return nil,'native_root'end
   parent.counts['text()']=(parent.counts['text()']or 0)+1
   if not current.skip and #text>0 then
    local rawPath=parent.path..'/text()['..parent.counts['text()']..'].0'
    if #rawPath>2000 then return nil,'native_path_limit'end
    local pointer=doc:getNormalizedXPointer(rawPath)
    if type(pointer)~='string'or doc:getTextFromXPointer(pointer)~=text then return nil,'native_node_mismatch'end
    local compact=require('readinknative/readingposition').compact(text)
    if #compact>0 then
     local path=pointer:match('^(.*)%.%d+$');if not path then return nil,'native_text_pointer'end
     nodes[#nodes+1]={first=size+1,last=size+#compact,path=path,text=text};parts[#parts+1]=compact;size=size+#compact
     if #nodes>I.MAX_NODES or size>I.MAX_TEXT then return nil,'native_text_limit'end
    end
   end
   p=finish+1
  end
 end
 if #stack~=0 or #nodes==0 then return nil,'native_incomplete'end
 return{text=table.concat(parts),nodes=nodes}
end
function I.resolve(document,source,rows,book,chapter)
 if type(source)~='table'or type(rows)~='table'or #rows>1000 then return nil,'source_missing'end
 if not require('readinknative/socialranges').valid(source,book,chapter)then return nil,'source_identity'end
 for _,row in ipairs(rows)do if type(row)~='table'or type(row.range)~='string'or not row.range:match('^%d+%-%d+$')then return nil,'range_schema'end end
 local sourceIndex,reason=original(source,rows);if not sourceIndex then return nil,reason end
 local nativeIndex;nativeIndex,reason=native(document);if not nativeIndex then return nil,reason end
 if sourceIndex.text~=nativeIndex.text then return nil,'complete_text_mismatch'end
 local selected,starts,ends={},{},{};local compact=require('readinknative/readingposition').compact
 for i,row in ipairs(rows)do
  if type(row.quote)=='string'and row.quote~=''and not row.position then
   local a,b=row.range:match('^(%d+)%-(%d+)$');a=a and sourceIndex.offsets[tonumber(a)];b=b and sourceIndex.offsets[tonumber(b)]
   if a and b and b>a and sourceIndex.text:sub(a+1,b)==compact(row.quote)then
    selected[#selected+1]={index=i,first=a+1,last=b};starts[a+1]=true;ends[b]=true
   end
  end
 end
 -- One pass for every requested endpoint, including many ranges in one node.
 for _,node in ipairs(nativeIndex.nodes)do
  local p,offset,at=1,0,node.first
  while p<=#node.text do
   local c,n=scalar(node.text,p)
   if not white(c)then
    if starts[at]then starts[at]=node.path..'.'..offset end
    if ends[at+n-1]then ends[at+n-1]=node.path..'.'..(offset+1)end
    at=at+n
   end
   p=p+n;offset=offset+1 -- CRe offsets count scalars, not UTF-16 surrogates.
  end
 end
 local updates={};local doc=document.doc
 for _,s in ipairs(selected)do
    local start,finish=starts[s.first],ends[s.last];local row=rows[s.index]
    if type(start)=='string'and type(finish)=='string'and doc:isXPointerInDocument(start)and doc:isXPointerInDocument(finish)and doc:compareXPointers(start,finish)==1 then
     local actual=doc:getTextFromXPointers(start,finish)
     if type(actual)=='string'and compact(actual)==compact(row.quote)then
      updates[#updates+1]={index=s.index,indexed=true,resolved=true,position={xpointer=start,endXPointer=finish,page=doc:getPageFromXPointer(start)}}
     end
    end
 end
 return updates,'verified'
end
return I
