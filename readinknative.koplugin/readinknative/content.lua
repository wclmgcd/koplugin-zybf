-- New chapter preparation pipeline, based on official ChapterResp and
-- ReaderConvert data contracts. Only content returned by the server is used.
local P={MAX_ENTRY=8*1024*1024,MAX_TOTAL=32*1024*1024,MAX_FILES=1024}
function P.safePath(path)
    if type(path)~='string' or path=='' or #path>1024 or path:find('[%c\\:]') or path:sub(1,1)=='/'then return false end
    for part in path:gmatch('[^/]+')do if part=='.' or part=='..'then return false end end
    return true
end
function P.password(headers,vid)
    local value
    for key,item in pairs(headers)do if tostring(key):lower():match('^%s*(.-)%s*$')=='encryptkey'then value=item end end
    if not value then return nil end
    vid=tostring(vid or '')
    assert(vid:match('^%d+$') and #vid<=32,'INVALID_ACCOUNT')
    local repeated=vid:rep(math.ceil(32/#vid))
    local bytes=assert(require('mime').unb64(value),'INVALID_CHAPTER_KEY')
    assert(#bytes>0 and #bytes<=1024 and #bytes%16==0,'INVALID_CHAPTER_KEY')
    local ffi=require('ffi');local crypto=require('ffi/crypto')
    pcall(ffi.cdef,'const EVP_CIPHER *EVP_aes_128_cbc(void);')
    local cipher=ffi.loadlib('crypto','57').EVP_aes_128_cbc()
    local out,n=crypto.evp_decrypt(cipher,bytes,repeated:sub(1,16),repeated:sub(17,32))
    assert(out and n>0,'INVALID_CHAPTER_KEY')
    local raw=ffi.string(out,n);local padding=raw:byte(-1)
    assert(padding and padding>=1 and padding<=16 and raw:sub(-padding)==string.rep(string.char(padding),padding),'INVALID_CHAPTER_KEY')
    local password=raw:sub(1,-padding-1)
    assert(#password>0 and not password:find('%z'),'INVALID_CHAPTER_KEY');return password
end
function P.unpack(body,password,format,textOnly,limits)
    local maxEntry=math.min(P.MAX_ENTRY,limits and limits.entry or P.MAX_ENTRY)
    local maxTotal=math.min(P.MAX_TOTAL,limits and limits.total or P.MAX_TOTAL)
    local maxFiles=math.min(P.MAX_FILES,limits and limits.files or P.MAX_FILES)
    local ffi=require('ffi');require('ffi/libarchive_h')
    pcall(ffi.cdef,[[
        int archive_read_add_passphrase(struct archive *, const char *);
        int archive_read_support_format_zip(struct archive *);
        int archive_read_support_format_tar(struct archive *);
        int archive_read_open_memory(struct archive *, const void *, size_t);
        int archive_read_next_header(struct archive *, struct archive_entry **);
        int archive_read_data_skip(struct archive *);
        const char *archive_entry_symlink(struct archive_entry *);
        const char *archive_entry_hardlink(struct archive_entry *);
    ]])
    local lib=ffi.loadlib('archive','13');local ar=lib.archive_read_new()
    assert(ar~=nil,'ARCHIVE_OPEN_FAILED')
    local entry=ffi.new('struct archive_entry *[1]');local chunk=ffi.new('char[65536]')
    local ok,result=pcall(function()
        assert(format==nil or format=='tar','ARCHIVE_FORMAT_REJECTED')
        assert((format=='tar'and lib.archive_read_support_format_tar(ar)or lib.archive_read_support_format_zip(ar))==0,'ARCHIVE_OPEN_FAILED')
        if password then assert(lib.archive_read_add_passphrase(ar,password)==0,'ARCHIVE_KEY_FAILED')end
        assert(lib.archive_read_open_memory(ar,body,#body)==0,'ARCHIVE_OPEN_FAILED')
        local files,total,count,declaredTotal,seen={},0,0,0,{}
        while true do
            local status=lib.archive_read_next_header(ar,entry)
            if status==1 then break end -- ARCHIVE_EOF
            assert(status==0,'ARCHIVE_READ_FAILED')
            count=count+1;assert(count<=maxFiles,'ARCHIVE_TOO_LARGE')
            local e=entry[0];local path=ffi.string(lib.archive_entry_pathname(e))
            assert(P.safePath(path),'ARCHIVE_PATH_REJECTED')
            local mode=tonumber(lib.archive_entry_filetype(e))
            assert(mode==32768 or mode==16384,'ARCHIVE_TYPE_REJECTED')
            assert(lib.archive_entry_symlink(e)==nil and lib.archive_entry_hardlink(e)==nil,'ARCHIVE_LINK_REJECTED')
            if mode==32768 then
                assert(not seen[path],'ARCHIVE_DUPLICATE');seen[path]=true
                local declared=tonumber(lib.archive_entry_size(e))
                assert(declared>=0 and declared<=maxEntry,'ARCHIVE_TOO_LARGE')
                declaredTotal=declaredTotal+declared;assert(declaredTotal<=maxTotal,'ARCHIVE_TOO_LARGE')
                local lower=path:lower()
                if textOnly and lower~='meta-inf/readink-source.json'and not lower:match('%.x?html?$')and not(declared<=16384 and(lower:match('%.jpe?g$')or lower:match('%.png$')or lower:match('%.gif$')))then
                    assert(lib.archive_read_data_skip(ar)==0,'ARCHIVE_READ_FAILED')
                else
                local parts,size={},0
                while true do
                    local n=tonumber(lib.archive_read_data(ar,chunk,65536))
                    assert(n>=0,'ARCHIVE_READ_FAILED');if n==0 then break end
                    size=size+n;total=total+n
                    assert(size<=maxEntry and total<=maxTotal,'ARCHIVE_TOO_LARGE')
                    parts[#parts+1]=ffi.string(chunk,n)
                end
                assert(size==declared,'ARCHIVE_TRUNCATED');files[path]=table.concat(parts)
                end
            end
        end
        return files
    end)
    lib.archive_free(ar)
    if not ok then error(result,0)end
    return result
end
local function xml(v)return tostring(v or ''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&apos;')end
local media={html='application/xhtml+xml',htm='application/xhtml+xml',xhtml='application/xhtml+xml',css='text/css',
    jpg='image/jpeg',jpeg='image/jpeg',png='image/png',gif='image/gif',svg='image/svg+xml',webp='image/webp',ttf='font/ttf',otf='font/otf',woff='font/woff',woff2='font/woff2'}
function P.package(files,book,chapter)
    local json=require('rapidjson');local meta=json.decode(assert(files['info.txt'],'CHAPTER_FILES_MISSING'))
    assert(type(meta)=='table' and tostring(meta.bookId)==tostring(book.bookId),'CHAPTER_BOOK_MISMATCH')
    local selected
    for _,item in ipairs(meta.chapters or {})do
        if tostring(item.chapterUid)==tostring(chapter.chapterUid)then selected=item.files;break end
    end
    assert(type(selected)=='table' and #selected>0,'CHAPTER_FILES_MISSING')
    local order,seen={},{}
    for _,name in ipairs(selected)do
        local ext=type(name)=='string' and name:match('%.([^./]+)$')
        assert(P.safePath(name) and files[name] and media[ext and ext:lower()]=='application/xhtml+xml','CHAPTER_FILES_MISSING')
        if not seen[name]then order[#order+1]=name;seen[name]=true end
    end
    local names={};for name in pairs(files)do
        local ext=name:match('%.([^./]+)$')
        if ext and media[ext:lower()] and (media[ext:lower()]~='application/xhtml+xml' or seen[name])then names[#names+1]=name end
    end
    table.sort(names)
    local entries={};local manifest,spine={},{};local ids={}
    local function href(path)return (path:gsub('[^/]+',require('readinknative/auth/wire').escape))end
    for i,name in ipairs(names)do
        local id='r'..i;ids[name]=id;entries[#entries+1]={path='OEBPS/'..name,body=files[name]}
        manifest[#manifest+1]='<item id="'..id..'" href="'..xml(href(name))..'" media-type="'..media[name:match('%.([^./]+)$'):lower()]..'"/>'
    end
    for _,name in ipairs(order)do spine[#spine+1]='<itemref idref="'..ids[name]..'"/>'end
    -- EPUB2 NCX avoids inventing chapter headings in the original HTML.
    local ncx='<?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="readink-native"/></head><docTitle><text>'..xml(book.title)..'</text></docTitle><navMap>'
    for i,name in ipairs(order)do ncx=ncx..'<navPoint id="n'..i..'" playOrder="'..i..'"><navLabel><text>'..xml(chapter.title)..'</text></navLabel><content src="'..xml(href(name))..'"/></navPoint>'end
    entries[#entries+1]={path='OEBPS/readink-native.ncx',body=ncx..'</navMap></ncx>'}
    local opf='<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">readink-native:'..xml(book.bookId)..':'..xml(chapter.chapterUid)..'</dc:identifier><dc:title>'..xml(book.title)..'</dc:title><dc:creator>'..xml(book.author)..'</dc:creator><dc:language>zh-CN</dc:language></metadata><manifest><item id="ncx" href="readink-native.ncx" media-type="application/x-dtbncx+xml"/>'..table.concat(manifest)..'</manifest><spine toc="ncx">'..table.concat(spine)..'</spine></package>'
    entries[#entries+1]={path='OEBPS/readink-native.opf',body=opf}
    entries[#entries+1]={path='META-INF/container.xml',body='<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/readink-native.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'}
    return entries
end
function P.write(entries,path,status,retainImageStatus)
    local resources={};for _,entry in ipairs(entries)do resources[entry.path]=entry.body end
    for _,entry in ipairs(entries)do
        if entry.path:lower():match('%.x?html?$')then entry.body=require('readinknative/footnotes').rewrite(entry.body,entry.path,resources);entry.body=require('readinknative/spacing').trim(entry.body)end
    end
    -- A missing marker means "needs inspection". Never attach an old complete
    -- marker to a newly written incomplete EPUB, even if a worker is cancelled.
    -- Layout-only repair keeps every image resource, so cancellation must not
    -- erase a valid old download marker while the old EPUB is still intact.
    if not retainImageStatus then local removed,err,code=require('readinknative/cachefiles').remove(path..'.images.json');assert(removed or code==2,'IMAGE_STATUS_WRITE_FAILED')end
    local writer
    local function archive(pad)
        require('readinknative/cachefiles').touch(path..'.part')
        writer=require('ffi/archiver').Writer:new()
        assert(require('readinknative/cachefiles').archiveOpen(writer,path..'.part'),'EPUB_WRITE_FAILED')
        assert(writer:setZipCompression('store'));assert(writer:addFileFromMemory('mimetype','application/epub+zip'))
        if pad then
            -- CRe hardcodes a 65535-byte minimum when looking up a disk DOM
            -- cache. Our per-chapter EPUBs are often smaller. An unreferenced,
            -- stored ZIP member crosses that threshold without changing the
            -- spine, source text, images, layout or any reading coordinate.
            assert(writer:addFileFromMemory('META-INF/readink-cache-padding',string.rep('\0',65536)))
        end
        assert(writer:setZipCompression('deflate'))
        local compression='deflate'
        for _,entry in ipairs(entries)do if entry.path~='META-INF/readink-cache-padding'then
            local name=entry.path:lower()
            local method=(name:match('%.jpe?g$')or name:match('%.png$')or name:match('%.webp$')or name:match('%.gif$'))and'store'or'deflate'
            if method~=compression then assert(writer:setZipCompression(method));compression=method end
            assert(require('readinknative/cachefiles').archiveCheck(writer:addFileFromMemory(entry.path,entry.body),writer,'archive-write',path..'.part'),'EPUB_WRITE_FAILED')
        end end
        local handle=writer.archive
        local code=require('ffi').loadlib('archive','13').archive_write_close(handle)
        require('readinknative/cachefiles').archiveCheck(code==0,writer,'archive-close',path..'.part');writer.archive=nil
        assert(code==0,'EPUB_WRITE_FAILED')
    end
    local ok,err=pcall(function()
        archive(false)
        if(require('readinknative/cachefiles').attributes(path..'.part','size')or 0)<65536 then archive(true)end
        assert(require('readinknative/cachefiles').rename(path..'.part',path),'EPUB_COMMIT_FAILED')
        if status then
            local article=resources['OEBPS/article.xhtml']
            if article and article:find(require('readinknative/articlecontent').LAYOUT_MARKER,1,true)then status.articleLayoutSchema=require('readinknative/articlecontent').LAYOUT end
            status.layoutSchema=1;status.readerLinksSchema=1;require('readinknative/images').marker(path,status)end
    end)
    if not ok then if writer then pcall(writer.close,writer)end;require('readinknative/cachefiles').remove(path..'.part');error(err,0)end
    return path,status
end
function P.repairLayout(path,article)
    local status=require('readinknative/images').status(path)
    local cacheable=(require('libs/libkoreader-lfs').attributes(path,'size')or 0)>=65536
    local articleOld=article and(not status or status.articleLayoutSchema~=require('readinknative/articlecontent').LAYOUT)
    if cacheable and status and status.layoutSchema==1 and status.readerLinksSchema==1 and not articleOld then return false end
    local f=assert(require('readinknative/cachefiles').open(path,'rb'),'CHAPTER_FILES_MISSING');local body=f:read('*a');f:close()
    local textOnly=status and status.layoutSchema==1 and not articleOld
    local files=P.unpack(body,nil,nil,textOnly);if not textOnly and not files['OEBPS/readink-native.opf']then return false end
    local changed=false;local entries={}
    for name,data in pairs(files)do
        if name:lower():match('%.x?html?$')then local clean=require('readinknative/footnotes').rewrite(data,name,files);clean=require('readinknative/spacing').trim(clean);if article and name=='OEBPS/article.xhtml'then clean=require('readinknative/articlecontent').reflow(clean)end;changed=changed or clean~=data;data=clean end
        if name~='mimetype'then entries[#entries+1]={path=name,body=data}end
    end
    if changed or not cacheable then
        if textOnly then entries={};for name,data in pairs(P.unpack(body))do if name~='mimetype'then entries[#entries+1]={path=name,body=data}end end end
        table.sort(entries,function(a,b)return a.path<b.path end);P.write(entries,path,status,true)
    elseif status then
            local article=resources['OEBPS/article.xhtml']
            if article and article:find(require('readinknative/articlecontent').LAYOUT_MARKER,1,true)then status.articleLayoutSchema=require('readinknative/articlecontent').LAYOUT end
            status.layoutSchema=1;status.readerLinksSchema=1;require('readinknative/images').marker(path,status)end
    return changed or not cacheable
end
function P.prepare(body,headers,vid,book,chapter,mode)
    return P.prepareFiles(P.unpack(body,P.password(headers,vid)),vid,book,chapter,mode)
end
function P.prefetchImages(files,book,chapters,client)
    local selected={};for _,ch in ipairs(chapters)do for _,entry in ipairs(P.package(files,book,ch))do selected[entry.path:sub(7)]=true end end
    local subset={};for name,data in pairs(files)do if not name:lower():match('%.x?html?$')or selected[name]then subset[name]=data end end
    return P.imageContext(subset,book,chapters,client)
end
-- Both fresh chapter packets and old partial EPUBs use the same complete
-- image acquisition policy before a reader is allowed to publish the chapter.
function P.imageContext(files,book,chapters,client)
    local I=require('readinknative/images')
    local root=client and require('readinknative/paths').account(client.data.vid)
    local context=I.prefetch(files,nil,nil,nil,root)
    if client then
        local missing={};for _,url in ipairs(I.references(files))do if context[url]==false then missing[#missing+1]=url end end
        local archive=require('readinknative/imagearchive').prepare(client,book,chapters,missing)
        for url,value in pairs(archive)do context[url]=value end
        -- Persist successful archive entries through the same image object
        -- cache, without retrying public URLs that already failed this pass.
        context=I.prefetch(files,context,nil,nil,root)
    end
    return context
end
function P.deferImages(files,book,chapters,vid)
    local selected={}
    for _,ch in ipairs(chapters)do for _,entry in ipairs(P.package(files,book,ch))do selected[entry.path:sub(7)]=true end end
    local subset={};for name,data in pairs(files)do if not name:lower():match('%.x?html?$')or selected[name]then subset[name]=data end end
    -- Explicit false entries prevent localize() from falling through to a
    -- synchronous network fetch. Embedded/local image resources stay intact.
    local context={};local root=vid and require('readinknative/paths').account(vid)
    for _,url in ipairs(require('readinknative/images').references(subset))do
        local ok,value=false
        if root then ok,value=pcall(require('readinknative/illustrationcache').find,root,url,P.MAX_ENTRY)end
        context[url]=ok and value or false
    end
    return context
end
function P.prepareFiles(files,vid,book,chapter,mode,context)
    local original=require('readinknative/socialranges').source(files,book,chapter)
    local entries=P.package(files,book,chapter);local selected={};local subset={}
    for _,entry in ipairs(entries)do selected[entry.path:sub(7)]=true end
    for name,data in pairs(files)do if not name:lower():match('%.x?html?$')or selected[name]then subset[name]=data end end
    local status=require('readinknative/images').localize(subset,nil,context or require('readinknative/images').prefetch(subset,nil,nil,nil,require('readinknative/paths').account(vid)))
    local prepared=P.package(subset,book,chapter)
    if original then prepared[#prepared+1]={path=require('readinknative/socialranges').ENTRY,body=require('rapidjson').encode(original)}end
    return P.write(prepared,require('readinknative/cache').path(vid,book,chapter,mode or 'preview'),status)
end
function P.repair(path,prepareContext)
    local f=assert(require('readinknative/cachefiles').open(path,'rb'),'CHAPTER_FILES_MISSING');local body=f:read('*a');f:close()
    local files=P.unpack(body);local prefix='OEBPS/'
    assert(files[prefix..'readink-native.opf'],'EPUB_REPAIR_UNSUPPORTED')
    local context=type(prepareContext)=='function'and prepareContext(files)or prepareContext
    local root=require('readinknative/cachefiles').location(path)
    local status,added=require('readinknative/images').localize(files,prefix,context or require('readinknative/images').prefetch(files,nil,nil,nil,root))
    local tags={}
    for _,entry in ipairs(added)do
        local href=entry.name:sub(#prefix+1)
        tags[#tags+1]='<item id="ri-img-'..require('ffi/sha2').sha256(href)..'" href="'..xml(href)..'" media-type="'..entry.type..'"/>'
    end
    if #tags>0 then files[prefix..'readink-native.opf']=files[prefix..'readink-native.opf']:gsub('</manifest>',table.concat(tags)..'</manifest>',1)end
    if not status.changed then local old=require('readinknative/images').status(path);if old then status.articleLayoutSchema=old.articleLayoutSchema;status.layoutSchema=old.layoutSchema;status.readerLinksSchema=old.readerLinksSchema end;require('readinknative/images').marker(path,status);return path,status end
    local entries={};for name,data in pairs(files)do if name~='mimetype'then entries[#entries+1]={path=name,body=data}end end
    table.sort(entries,function(a,b)return a.path<b.path end)
    return P.write(entries,path,status)
end
return P
