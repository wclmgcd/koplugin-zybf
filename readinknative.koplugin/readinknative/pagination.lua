-- Whole-book page coordinates over CRengine's chapter documents. Chapter-local
-- XPointers remain unchanged, preserving existing notes and reading positions.
local P={}
local function uid(ch)return tostring(ch.chapterUid)end
function P.reindex(index,chapters)
    -- Official PageCursorWindow estimates missing chapters from the word/page
    -- density of ready chapters; the footer does not wait for a full download.
    local words,pages=0,0;local counted={}
    for _,ch in ipairs(chapters)do
        local e=index.entries[uid(ch)];local w=tonumber(ch.wordCount)
        if e and type(e.pages)=='number'and e.pages>=1 and type(e.signature)=='string'and not counted[e.signature]and w and w>=0 and w<=100000000 then
            words=words+w;pages=pages+e.pages;counted[e.signature]=true
        end
    end
    local density=pages>0 and math.floor(words/pages)or 0
    local offset,known=0,true;local seen={};index.rows={};index.complete=true;index.estimated=false
    for i,ch in ipairs(chapters)do
        local entry=index.entries[uid(ch)]
        if entry and type(entry.pages)=='number'and entry.pages>=1 and entry.pages%1==0 and entry.pages<=10000000 and type(entry.signature)=='string'then
            local original=seen[entry.signature]
            local row={uid=uid(ch),index=i,pages=entry.pages,offset=original and original.offset or known and offset or nil,alias=original and original.uid or nil}
            index.rows[uid(ch)]=row
            if not original then seen[entry.signature]=row;if known then offset=offset+entry.pages end end
        else
            index.complete=false
            local w=tonumber(ch.wordCount)
            if density>0 and w and w>=0 and w<=100000000 then
                -- The APK performs integer division before Math.ceil (DEX div-int),
                -- so match its rounding rather than treating the division as float.
                local count=math.max(1,math.floor(w/density))
                index.rows[uid(ch)]={uid=uid(ch),index=i,pages=count,offset=known and offset or nil,estimated=true}
                if known then offset=offset+count end;index.estimated=true
            else known=false end
        end
    end
    index.total=known and offset or nil
    return index
end
function P.spec(a)
    if not a.book or a.book.localFile or not a.document or not a.document.format or not a.document.doc or not a.chapter then return end
    local F=require('readinknative/format');local f=F.normalize(a.document.format);local chapters=a:catalogItems();if #chapters==0 then return end
    local parts={'cached-dom-v3',tostring(a.client.data.vid),tostring(a.book.bookId),tostring(a.book.version or 0),tostring(a.document.w),tostring(a.document.h),F.signature(f)}
    parts[#parts+1]=tostring(a.document.doc.default_font)
    for _,ch in ipairs(chapters)do parts[#parts+1]=uid(ch)end
    local book={};for _,k in ipairs({'bookId','version','paid','format'})do book[k]=a.book[k]end
    local priorityUid
    for i,ch in ipairs(chapters)do if uid(ch)==uid(a.chapter)and chapters[i+1]then priorityUid=uid(chapters[i+1]);break end end
    return{key=require('ffi/sha2').sha256(table.concat(parts,'|')),vid=a.client.data.vid,book=book,chapters=chapters,format=f,w=a.document.w,h=a.document.h,priorityUid=priorityUid}
end
function P.path(spec)return require('readinknative/paths').cache(spec.vid,'pagination-'..spec.key..'.json')end
function P.fileStamp(path)
    local a=require('libs/libkoreader-lfs').attributes(path)
    return a and table.concat({path,a.size or 0,a.modification or 0},':')
end
function P.cacheStamp(spec)
    local parts={};local Cache=require('readinknative/cache')
    for _,ch in ipairs(spec.chapters)do
        local path=Cache.find(spec.vid,spec.book,ch)
        parts[#parts+1]=uid(ch)..':'..(path and P.fileStamp(path)or'missing')
    end
    return require('ffi/sha2').sha256(table.concat(parts,'|'))
end
function P.signature(path)
    local f=assert(require('readinknative/cachefiles').open(path,'rb'));local files=require('readinknative/content').unpack(f:read('*a'));f:close()
    local opf=assert(files['OEBPS/readink-native.opf']);local spine=assert(opf:match('<spine[^>]*>(.-)</spine>'))
    local ids={};for id,href in opf:gmatch('<item%s+id="([^"]+)"%s+href="([^"]+)"')do ids[id]=href end
    local parts,text={},''
    for id in spine:gmatch('<itemref%s+idref="([^"]+)"')do
        local href=assert(ids[id]):gsub('&amp;','&'):gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
        local name='OEBPS/'..href;local body=assert(files[name]);parts[#parts+1]=name;parts[#parts+1]=require('ffi/sha2').sha256(body);text=text..body
    end
    local names={};for name in pairs(files)do if name:match('%.css$')then names[#names+1]=name end end;table.sort(names)
    for _,name in ipairs(names)do text=text..files[name];parts[#parts+1]=name;parts[#parts+1]=require('ffi/sha2').sha256(files[name])end
    names={};for name in pairs(files)do
        local base=name:match('([^/]+)$')
        if not name:match('%.x?html?$')and not name:match('%.css$')and not name:match('%.opf$')and not name:match('%.ncx$')and text:find(base,1,true)then names[#names+1]=name end
    end;table.sort(names)
    for _,name in ipairs(names)do parts[#parts+1]=name;parts[#parts+1]=require('ffi/sha2').sha256(files[name])end
    return require('ffi/sha2').sha256(table.concat(parts,'|'))
end
function P.current(a,spec)
    spec=spec or P.spec(a);if not spec then return end
    local index=a.pageIndex
    if not index or index.key~=spec.key then
        local f=require('readinknative/cachefiles').open(P.path(spec),'rb')
        if f then
            local data=f:read(2*1024*1024+1);f:close()
            if #data<=2*1024*1024 then local ok,value=pcall(require('rapidjson').decode,data);if ok and type(value)=='table'and value.schema==1 and value.key==spec.key and type(value.entries)=='table'then index=value end end
        end
        if not index or index.key~=spec.key then index={schema=1,key=spec.key,entries={}}end
        a.pageIndex=index;P.reindex(index,spec.chapters)
    end
    if index.expiresAt and os.time()>=index.expiresAt then index={schema=1,key=spec.key,entries={}};a.pageIndex=index;P.reindex(index,spec.chapters)end
    return index
end
function P.record(a)
    local spec=P.spec(a);if not spec then return end
    local index=P.current(a,spec);local path=require('readinknative/cache').find(spec.vid,spec.book,a.chapter)
    if path then
        local stamp=P.fileStamp(path);local old=index.entries[uid(a.chapter)]
        -- Showing a chapter must not unpack and hash all embedded illustrations
        -- before UIManager gets its first chance to paint it. Resolve content
        -- identity in the background; the foreground already knows its pages.
        local reusable=old and old.stamp==stamp
        index.entries[uid(a.chapter)]={pages=a.document:count(),stamp=stamp,
            signature=reusable and old.signature or('pending:'..uid(a.chapter)),provisional=not reusable or old.provisional or nil}
        P.reindex(index,spec.chapters)
    end
    return spec,index
end
function P.request(a)
    local spec,index=P.record(a);if not spec then return end
    local need=false;for _,ch in ipairs(spec.chapters)do if type(ch.wordCount)~='number'then need=true;break end end
    local attempt=a.pageMetadataAttempt
    if need and a.client:ready()and(not attempt or attempt.key~=spec.key or os.time()-attempt.at>=300)then
        spec.needMetadata=true;a.pageMetadataAttempt={key=spec.key,at=os.time()}
    end
    -- DOM preparation belongs to the chapter loader. Page statistics only
    -- harvest measured results; evicting an engine cache cannot cause a second
    -- statistics renderer to race the reader's next-chapter worker.
    local entry=index.entries[uid(a.chapter)]
    if not spec.needMetadata and index.cacheStamp and entry and not entry.provisional then return end
    require('readinknative/offline').paginate(a,spec,index)
end
function P.offer(a,s,chapter,result)
    local spec=P.spec(a)
    if not spec or not result or result.stamp~=P.fileStamp(s.path)or type(result.pages)~='number'then return end
    local layout=require('readinknative/chapterloader').spec(spec.vid,spec.book,s.path,spec.w,spec.h,spec.format.size,spec.format)
    if layout.key~=s.key then return end
    local index=P.current(a,spec);local old=index.entries[uid(chapter)]
    local reusable=old and old.stamp==result.stamp and not old.provisional
    index.entries[uid(chapter)]={pages=result.pages,stamp=result.stamp,signature=reusable and old.signature or('pending:'..uid(chapter)),provisional=not reusable or nil}
    index.cacheStamp=nil;P.reindex(index,spec.chapters)
end
function P.build(spec,previous,limit)
    local index={schema=1,key=spec.key,entries={}};local counts={};local Cache=require('readinknative/cache')
    local processed=0;local ordered={}
    if spec.priorityUid then for _,ch in ipairs(spec.chapters)do if uid(ch)==spec.priorityUid then ordered[#ordered+1]=ch;break end end end
    for _,ch in ipairs(spec.chapters)do if uid(ch)~=spec.priorityUid then ordered[#ordered+1]=ch end end
    for _,ch in ipairs(ordered)do
        local path=Cache.find(spec.vid,spec.book,ch)
        if path then
            local stamp=P.fileStamp(path);local old=previous and previous.entries[uid(ch)]
            local same=old and old.stamp==stamp
            local reusable=same and not old.provisional and type(old.signature)=='string'
            if not reusable and limit and processed>=limit then
                if same then index.entries[uid(ch)]=old end;index.pending=true
            else
                if not reusable then processed=processed+1 end
                local signature=reusable and old.signature or P.signature(path)
                local L=require('readinknative/chapterloader');local rs=L.spec(spec.vid,spec.book,path,spec.w,spec.h,spec.format.size,spec.format)
                -- Measured pages survive DOM eviction; source/layout validation
                -- remains mandatory. No repair/repack/open/render for statistics.
                local receipt=L.record(rs)
                local pages=same and old.pages or receipt and receipt.pages or counts[signature]
                if type(pages)=='number'and pages>=1 and pages%1==0 and pages<=10000000 then counts[signature]=pages else pages=nil end
                index.entries[uid(ch)]={pages=pages,signature=signature,stamp=stamp}
            end
            local expiry=Cache.accessExpiry(spec.vid,spec.book,ch);if expiry then index.expiresAt=math.min(index.expiresAt or expiry,expiry)end
        end
    end
    P.reindex(index,spec.chapters)
    if not index.pending then index.cacheStamp=P.cacheStamp(spec)end
    local path=P.path(spec);local f=assert(require('readinknative/cachefiles').open(path..'.part','wb'));f:write(require('rapidjson').encode(index));f:close();assert(require('readinknative/cachefiles').rename(path..'.part',path))
    return index
end
function P.position(a)
    if a.book.localFile then return a.document:page(),a.document:count()end
    local index=P.current(a);local row=index and a.chapter and index.rows[uid(a.chapter)]
    if row and row.offset then return row.offset+a.document:page(),index.total end
end
function P.label(a)
    local page,total=P.position(a);if not page then return''end
    return tostring(page)..(total and(' / '..total)or'')
end
function P.chapterPage(a,ch)
    local index=P.current(a);local row=index and index.rows[uid(ch)];return row and row.offset and row.offset+1
end
function P.next(a,delta)
    local index=P.current(a);local current=index and a.chapter and index.rows[uid(a.chapter)];local target=(a.chapterIndex or 1)+delta
    while a.chapters[target]do
        local nextRow=index and index.rows[uid(a.chapters[target])]
        if not current or not nextRow or (current.alias or current.uid)~=(nextRow.alias or nextRow.uid)then return target end
        target=target+delta
    end
    return target
end
function P.jump(a,page)
    if a.book.localFile then a.document:jump(page);a:savePosition();a:draw();return end
    local index=P.current(a);if not index or not index.total then return end
    page=math.max(1,math.min(index.total,math.floor(page)))
    for i,ch in ipairs(a.chapters)do local row=index.rows[uid(ch)]
        if row and not row.alias and page>row.offset and page<=row.offset+row.pages then a:selectChapter(ch,i,{page=page-row.offset});return end
    end
end
return P
