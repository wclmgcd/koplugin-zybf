-- Official ranges address UTF-16 positions in the ORIGINAL XHTML, before
-- image localization or layout repair. Never treat them as CRe XPointers.
local R={ENTRY='META-INF/readink-source.json',MAX_SOURCE=2*1024*1024}
function R.source(files,book,chapter)
    local plain=files[require('readinknative/txtcontent').key(chapter.chapterUid)]
    if plain then
        local value=require('rapidjson').decode(plain)
        if R.valid(value,book,chapter)and value.format=='txt'then return value end
        error('TXT_CONTENT_INVALID')
    end
    -- Validate every resource through the same package contract, then use the
    -- OFFICIAL chapter file order, not the alphabetically sorted EPUB manifest.
    -- The chapter's UTF-16 address space spans the original files without an
    -- inserted separator (including each file's headers/tags/BOM).
    require('readinknative/content').package(files,book,chapter)
    local meta=require('rapidjson').decode(files['info.txt']);local selected
    for _,ch in ipairs(meta.chapters or{})do if tostring(ch.chapterUid)==tostring(chapter.chapterUid)then selected=ch.files;break end end
    if type(selected)~='table'or #selected<1 or #selected>128 then return end
    local html,order,seen,total={},{},{},0
    for _,name in ipairs(selected)do if not seen[name]then
        local raw=files[name];total=total+#raw;if total>R.MAX_SOURCE then return end
        html[#html+1]=raw;order[#order+1]=name;seen[name]=true
    end end
    return{schema=1,bookId=tostring(book.bookId),chapterUid=tostring(chapter.chapterUid),version=tostring(book.version or 0),html=table.concat(html),resourceOrder=order}
end
function R.valid(s,book,chapter)
    return type(s)=='table'and s.bookId==tostring(book.bookId)and s.chapterUid==tostring(chapter.chapterUid)
        and s.version==tostring(book.version or 0)and((s.schema==1 and type(s.html)=='string'and #s.html<=R.MAX_SOURCE)
        or(s.schema==2 and s.format=='txt'and type(s.text)=='string'and #s.text<=R.MAX_SOURCE))
end
function R.slice(html,first,last)
    if type(html)~='string'or require('util').fixUtf8(html,'')~=html or type(first)~='number'or type(last)~='number'
        or first<0 or last<=first or first%1~=0 or last%1~=0 then return end
    local pos,offset,start=1,0
    while pos<=#html do
        if offset==first then start=pos end
        if offset==last then return start and html:sub(start,pos-1)end
        local b=html:byte(pos);local bytes=b<128 and 1 or b<224 and 2 or b<240 and 3 or 4
        offset=offset+(bytes==4 and 2 or 1);pos=pos+bytes
        if offset>last then return end -- A boundary inside a surrogate is invalid.
    end
    if offset==last and start then return html:sub(start)end
end
function R.boundaries(source,ranges,plain)
    if require('util').fixUtf8(source,'')~=source then return{}end
    local wanted={};for _,r in ipairs(ranges)do
        local first,last=r.range:match('^(%d+)%-(%d+)$')
        if first then wanted[tonumber(first)]=true;wanted[tonumber(last)]=true end
    end
    local map={};local pos,offset=1,0;local tag,entity=false,false
    while pos<=#source do
        if wanted[offset]and(plain or not tag and not entity)then map[offset]=pos end
        local byte=source:byte(pos);local bytes=byte<128 and 1 or byte<224 and 2 or byte<240 and 3 or 4
        if byte==60 then tag=true;entity=false elseif byte==62 then tag=false;entity=false
        elseif byte==38 then entity=true elseif byte==59 or byte==9 or byte==10 or byte==13 or byte==32 then entity=false end
        offset=offset+(bytes==4 and 2 or 1);pos=pos+bytes
    end
    if wanted[offset]and(plain or not tag and not entity)then map[offset]=pos end
    return map
end
function R.quote(source,range,boundaries,plain)
    if type(range)~='string'then return end
    local first,last=range:match('^(%d+)%-(%d+)$')
    if not first then return end
    local raw
    if boundaries then
        local left,right=boundaries[tonumber(first)],boundaries[tonumber(last)]
        if not left or not right or right<=left then return end
        raw=source:sub(left,right-1)
    else raw=R.slice(source,tonumber(first),tonumber(last))end
    if not raw or #raw>65536 then return end
    -- Reject endpoints inside markup/entities instead of moving them silently.
    if not boundaries and not plain then
        local prefix=R.slice(source,0,tonumber(first))or''
        if prefix:match('<[^>]*$')or prefix:match('&[^;<>%s]*$')or raw:match('<[^>]*$')or raw:match('&[^;<>%s]*$')then return end
    end
    if plain then local text=raw:gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','');if #text>0 and #text<=16384 then return text end;return end
    local fragments={}
    local original=raw:gsub('<!%-%-.-%-%->','')
    for part in (original:gsub('<[^>]*>','\0')):gmatch('[^%z]+')do
        part=require('util').htmlEntitiesToUtf8(part):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
        if part~=''then fragments[#fragments+1]=part end
    end
    raw=original:gsub('<[^>]*>','')
    raw=raw:gsub('&#[xX]([%da-fA-F]+);',function(v)return require('util').unicodeCodepointToUtf8(tonumber(v,16))end)
        :gsub('&#(%d+);',function(v)return require('util').unicodeCodepointToUtf8(tonumber(v))end)
    local text=require('util').htmlEntitiesToUtf8(raw):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
    if #text>0 and #text<=16384 then
        local ends=#fragments>1 and{first=fragments[1],last=fragments[#fragments]}or nil
        return text,ends
    end
end
function R.position(document,quote,ends)
    if type(quote)~='string'or quote==''then return end
    -- Exact, unique matches only. Ambiguous/revised text gets no clickable mark.
    local hits=document.doc:findAllText(quote,false,0,2,false,0x00FF)
    local h=hits and #hits==1 and hits[1]
    -- A phrase crossing block elements is not searchable as one CRe string.
    -- Both endpoints must be unique, and the complete selected native text
    -- must equal the original quote. Never combine unrelated unique phrases.
    if not h and(not hits or #hits==0)and type(ends)=='table'and type(ends.first)=='string'and type(ends.last)=='string'
        and #ends.first>0 and #ends.last>0 and #ends.first<=16384 and #ends.last<=16384 then
        local left=document.doc:findAllText(ends.first,false,0,2,false,0x00FF)
        local right=document.doc:findAllText(ends.last,false,0,2,false,0x00FF)
        if left and #left==1 and right and #right==1 then
            local start,finish=left[1].start,right[1]['end']
            local ordered=start and finish and document.doc:compareXPointers(start,finish)==1
            local actual=ordered and document.doc:getTextFromXPointers(start,finish)
            local compact=require('readinknative/readingposition').compact
            if type(actual)=='string'and compact(actual)==compact(quote)then h={start=start,['end']=finish}end
        end
    end
    if not h then return end
    if h.start and h['end']and document.doc:isXPointerInDocument(h.start)and document.doc:isXPointerInDocument(h['end'])then
        return{xpointer=h.start,endXPointer=h['end'],page=document.doc:getPageFromXPointer(h.start)}
    end
end
function R.populate(source,ranges)
    local raw=source.text or source.html;local plain=source.format=='txt'
    local boundaries=R.boundaries(raw,ranges,plain)
    for _,r in ipairs(ranges)do
        r.quote,r.endpoints=R.quote(raw,r.range,boundaries,plain)
        if r.needsFragments then r.needsFragments=nil;if not r.position then r.resolved=nil end end
    end
    return ranges
end
function R.cachedSource(path,book,chapter)
    local C=require('readinknative/content');local J=require('rapidjson');local f=assert(require('readinknative/cachefiles').open(path,'rb'),'CHAPTER_FILES_MISSING')
    local bytes=f:read('*a');f:close();local files=C.unpack(bytes,nil,nil,true)
    local source=files[R.ENTRY]and J.decode(files[R.ENTRY])
    if R.valid(source,book,chapter)then return source end
    -- Only legacy sidecars require hashing the whole archive to bind offsets.
    local digest=require('ffi/sha2').sha256(bytes)
    if not R.valid(source,book,chapter)then
        local sf=require('readinknative/cachefiles').open(path..'.source.json','rb')
        if sf then local text=sf:read(3*R.MAX_SOURCE+1);sf:close();local ok,value=pcall(J.decode,text)
            if ok and value.digest==digest and R.valid(value,book,chapter)then source=value end end
    end
    return R.valid(source,book,chapter)and source or nil,digest
end
function R.load(client,book,chapter,path,ranges)
    local J=require('rapidjson');local source,digest=R.cachedSource(path,book,chapter)
    if not R.valid(source,book,chapter)then
        -- Legacy caches have already rewritten image URLs. Read the original
        -- chapter once, without fetching images or replacing the reading cache.
        local A=require('readinknative/api');local info=A.info(client,book)
        assert(tostring(info.version or 0)==tostring(book.version or 0),'SOCIAL_SOURCE_VERSION_CHANGED')
        local fresh;for _,ch in ipairs(A.catalog(client,info))do if tostring(ch.chapterUid)==tostring(chapter.chapterUid)then fresh=ch;break end end
        assert(fresh,'CATALOG_EMPTY');local mode=require('readinknative/permission').mode(info,fresh,client.data.vid)
        local body,headers=A.download(client,info,fresh,mode)
        source=R.source(A.unpack(body,headers,client,info,{fresh}),info,fresh)
        assert(R.valid(source,book,chapter),'SOCIAL_SOURCE_UNSUPPORTED');source.digest=digest
        local out=assert(require('readinknative/cachefiles').open(path..'.source.json.part','wb'));assert(out:write(J.encode(source)));assert(out:close());assert(require('readinknative/cachefiles').rename(path..'.source.json.part',path..'.source.json'))
    end
    R.populate(source,ranges)
    return ranges,source
end
return R
