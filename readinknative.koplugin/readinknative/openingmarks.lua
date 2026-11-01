-- Small durable opening-page seeds, scoped by source, account and full layout.
-- They supplement complete range caches; no range is dropped to gain speed.
local O={PAGES=2,MAX_BYTES=256*1024,MAX_POINTS=128,SECONDS=0.35}
local function owner(s,book,ch)
 return require('readinknative/underlineseed').owner(s.vid,book,ch,s.path)
end
local function fingerprint(rows)
 local parts={'endpoints-v1'};for _,r in ipairs(rows)do local e=r.endpoints;parts[#parts+1]={r.range,r.quote or'',e and e.first or'',e and e.last or'',r.needsFragments==true}end
 return require('ffi/sha2').sha256(require('rapidjson').encode(parts))
end
function O.read(s,rows)
 local f=require('readinknative/cachefiles').open(s.path..'.opening.json','rb');if not f then return end
 local raw=f:read(O.MAX_BYTES+1);f:close();if #raw>O.MAX_BYTES then return end
 local ok,v=pcall(require('rapidjson').decode,raw)
 if not ok or type(v)~='table'or v.schema~=1 or v.key~=s.key or v.stamp~=require('readinknative/pagination').fileStamp(s.path)
  or type(v.created)~='number'or v.created>os.time()or os.time()-v.created>=require('readinknative/underlinecache').TTL
  or v.references~=fingerprint(rows)or type(v.pages)~='table'or type(v.positions)~='table'or #v.positions>O.MAX_POINTS then return end
 local count=0
 for page,done in pairs(v.pages)do if(page~='1'and page~='2')or done~=true then return end;count=count+1 end
 for k in pairs(v.positions)do if type(k)~='number'or k<1 or k>#v.positions or k%1~=0 then return end end
 return v
end
function O.needed(s,book,ch)
 local rows=require('readinknative/underlinecache').load(owner(s,book,ch))
 return rows and not O.read(s,rows)and true or false
end
function O.build(doc,s,book,ch)
 local UC=require('readinknative/underlinecache');local c=owner(s,book,ch);local rows,_,_,meta=UC.load(c)
 if not rows or O.read(s,rows)then return end
 local clock=require('socket');local start=clock.gettime();local Page=require('readinknative/underlinepage');local anchor
 if #rows>0 then anchor=Page.anchor(require('readinknative/socialranges').cachedSource(s.path,book,ch))end
 local pages={};local complete=true;local searches=0;local previous=doc:page()
 for page=1,math.min(O.PAGES,doc:count())do
  doc:jump(page);local pending;local more=false;local rounds=0
  repeat
   local result=Page.batch(doc,rows,pending,book,ch,anchor);anchor=result.anchor or anchor
   pending=result.remaining;more=result.more;searches=searches+result.searches;rounds=rounds+1
  until not more or rounds>=8 or clock.gettime()-start>O.SECONDS
  if not more then pages[tostring(page)]=true end
  if more or clock.gettime()-start>O.SECONDS then break end
 end
 doc:jump(previous)
 local positions={};local d=doc.doc
 for _,r in ipairs(rows)do if r.position then
  local p=r.position
  if d:isXPointerInDocument(p.xpointer)and d:isXPointerInDocument(p.endXPointer)then
   local first,last=d:getPageFromXPointer(p.xpointer),d:getPageFromXPointer(p.endXPointer)
   if first<=O.PAGES and last>=1 then
    if #positions>=O.MAX_POINTS then complete=false;break end
    positions[#positions+1]={range=r.range,position=p,first=first,last=last}
   end
  end
 end end
 if not complete then pages={}end
 local value={schema=1,key=s.key,stamp=require('readinknative/pagination').fileStamp(s.path),references=fingerprint(rows),created=os.time(),pages=pages,positions=positions}
 local raw=require('rapidjson').encode(value)
 if #raw>O.MAX_BYTES then return end
 local Cache=require('readinknative/cache');if Cache.find(s.vid,book,ch)~=s.path then return end
 UC.save(c,rows,nil,anchor,meta)
 local F=require('readinknative/cachefiles');local path=s.path..'.opening.json';local f=F.open(path..'.part','wb');if not f then return end
 local ok=f:write(raw);local closed=f:close()
 if ok and closed then F.rename(path..'.part',path)else F.remove(path..'.part')end
 require('logger').info('ReadInk opening underlines prepared pages/positions/searches/ms:',(pages['1']and 1 or 0)+(pages['2']and 1 or 0),#positions,searches,math.floor((clock.gettime()-start)*1000))
 return value
end
function O.apply(a,c,rows)
 local b=a.view.layout.body;local s=require('readinknative/chapterloader').spec(c.vid,c.book,c.document.path,b.w,b.h,a.state.font,c.document.format)
 local v=O.read(s,rows);if not v then return end
 local byRange={};for _,r in ipairs(rows)do byRange[r.range]=r end
 local mapped={};local d=c.document.doc
 -- Validate the small seed before changing any row. Old/damaged XPointers
 -- fall back to normal background positioning, never paint a wrong quote.
 for _,p in ipairs(v.positions)do
  local row=byRange[p.range];local x=p.position
  if not row or type(x)~='table'or type(x.xpointer)~='string'or type(x.endXPointer)~='string'
   or not d:isXPointerInDocument(x.xpointer)or not d:isXPointerInDocument(x.endXPointer)
   or d:getPageFromXPointer(x.xpointer)~=p.first or d:getPageFromXPointer(x.endXPointer)~=p.last then return end
 end
 for _,p in ipairs(v.positions)do local row=byRange[p.range];row.position=p.position;row.resolved=true;mapped[#mapped+1]=row end
 return{pages=v.pages,rows=mapped}
end
return O
