-- Routes verified in the official 2.1.2 E-Ink APK. Requests owned/free content,
-- freshly verified membership content or preview; no purchase or progress writes.
local A={}
function A.format(book)
 local format=book.format==nil and'epub'or type(book.format)=='string'and book.format:lower()
 assert(format=='epub'or format=='txt'or format=='pdf','BOOK_FORMAT_UNSUPPORTED');return format
end
function A.unpack(body,headers,client,book,chapters)
 assert(A.format(book)~='pdf','PDF_NATIVE_REQUIRED')
 local C=require('readinknative/content')
 if A.format(book)=='txt'then return require('readinknative/txtcontent').convert(C.unpack(body,nil,'tar'),book,chapters)end
 return C.unpack(body,C.password(headers,client.data.vid))
end
function A.shelfSnapshot(client)
    return require('readinknative/shelfmodel').parse(client:api('/shelf/sync',{synckey=0,lectureSynckey=0}))
end
function A.shelf(client)local s=A.shelfSnapshot(client);return s.books,s.groups end
function A.catalog(client,book)
    if A.format(book)=='pdf'then return{}end
    local result=client:api('/book/chapterInfos',nil,{bookIds={tostring(book.bookId)},synckeys={0}})
    for _,row in ipairs(result.data or {})do
        if tostring(row.bookId)==tostring(book.bookId) then
            assert(type(row.updated)=='table','CATALOG_SCHEMA_CHANGED')
            local chapters,seen={},{}
            for _,c in ipairs(row.updated)do
                if c.chapterUid and not seen[tostring(c.chapterUid)]then
                    seen[tostring(c.chapterUid)]=true
                    chapters[#chapters+1]={chapterUid=c.chapterUid,title=c.title or '未命名章节',
                        chapterIdx=tonumber(c.chapterIdx),level=tonumber(c.level) or 0,paid=c.paid,price=c.price,
                        wordCount=tonumber(c.wordCount),tar=type(c.tar)=='string'and c.tar or nil}
                end
            end
            table.sort(chapters,function(a,b)return (a.chapterIdx or tonumber(a.chapterUid)or 0)<(b.chapterIdx or tonumber(b.chapterUid)or 0) end)
            assert(#chapters>0,'CATALOG_EMPTY')
            if book._pdfText then require('readinknative/pdftext').catalogBook(client,book,row.book)end
            return chapters,row.book
        end
    end
    error('CATALOG_EMPTY')
end
function A.info(client,book)
    local response=client:api('/book/info',{bookId=tostring(book.bookId),myzy=1})
    local info=response.book or response
    assert(type(info)=='table' and tostring(info.bookId)==tostring(book.bookId),'BOOK_SCHEMA_CHANGED')
    info.format=A.format(info)
    local P=require('readinknative/permission')
    if client.data and client.data.vid then
        local summary
        if P.mode(info,{})~='full'and not P.shortUntil(info,os.time())then
            local ok,value=pcall(function()return require('readinknative/accountinfo').membership(client:api('/pay/memberCardSummary',{pf='wechat_wx-2001-android-100-weread',snapshot=0}))end)
            if ok then summary=value else info._permissionError=require('readinknative/errors').code(value)end
        end
        P.attach(info,summary,client.data.vid)
        require('readinknative/cache').recordBookAccess(client.data.vid,info)
    end
    return require('readinknative/pdftext').retain(client,book,info)
end
function A.downloadMany(client,book,chapters,mode,offline)
    assert(A.format(book)~='pdf','PDF_NATIVE_REQUIRED')
    assert(mode=='full' or mode=='preview','READING_MODE_INVALID')
    assert(#chapters>0 and #chapters<=5,'CHAPTER_BATCH_INVALID')
    local ids,seen={'0'},{}
    for _,chapter in ipairs(chapters)do
        if mode=='full'then assert(require('readinknative/permission').mode(book,chapter,client.data and client.data.vid)=='full','READING_PERMISSION_REQUIRED')end
        local uid=tostring(chapter.chapterUid);assert(uid:match('^%d+$')and not seen[uid],'CHAPTER_BATCH_INVALID');seen[uid]=true;ids[#ids+1]=uid
    end
    local query={bookId=book.bookId,chapters=table.concat(ids,','),bookVersion=book.version or 0,
        bookType=A.format(book),quote='',preview=mode=='preview' and 1 or 0,preload=0,offline=offline==true and 1 or 0,stopAutoPayWhenBNE=1,
        pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId='1',release=1}
    local body,headers=client:request(require('readinknative/auth/wire').url('https://i.weread.qq.com/book/chapterdownload',query),nil,true,30)
    assert((A.format(book)=='txt'and #body>=512 or A.format(book)=='epub'and body:sub(1,2)=='PK'),mode=='preview' and 'PREVIEW_UNAVAILABLE' or 'CHAPTER_REJECTED')
    -- Never retry a denied preview as full, or retry a potentially paid operation.
    return body,headers
end
function A.download(client,book,chapter,mode,offline)return A.downloadMany(client,book,{chapter},mode,offline)end
function A.preview(client,book,chapter)return A.download(client,book,chapter,'preview')end
function A.prepareChapter(client,info,fresh,offline,options)
    if info._readPermission and os.time()>=info._readPermission.untilTime and os.time()-info._readPermission.checkedAt>=300 then info=A.info(client,info)end
    local mode,reason=require('readinknative/permission').mode(info,fresh,client.data and client.data.vid)
    local Cache=require('readinknative/cache');local Images=require('readinknative/images')
    local stored,storedMode=Cache.stored(client.data.vid,info,fresh,mode)
    if stored and info._pdfText and info._pdfText.pending then
        local valid=pcall(require('readinknative/pdftext').confirm,info,client.data.vid,fresh,stored)
        if not valid then stored=nil end
    end
    local imageStatus=stored and Images.status(stored)
    if stored and storedMode==mode then
        if not(imageStatus and imageStatus.complete)then
            local C=require('readinknative/content')
            -- Upgrade a store1/store2 text-only cache without fetching its body
            -- again. Successful individual images survive a failed attempt.
            local path,status=C.repair(stored,function(files)return C.imageContext(files,info,{fresh},client)end)
            assert(status.complete,'IMAGES_INCOMPLETE');stored=path;imageStatus=status
        end
        -- Renew only after the existing permission check grants this exact mode.
        Cache.recordAccess(client.data.vid,info,fresh,mode)
        return{path=stored,images=imageStatus,mode=mode,book=info,chapter=fresh,reused=true}
    end
    local clock=require('socket');local began=clock.gettime()
    local ok,body,headers=pcall(A.download,client,info,fresh,mode,offline)
    if not ok then
        if reason=='paid_membership_required'and tostring(body):find('HTTP_402',1,true)then error('READING_PAID_MEMBER_REQUIRED '..tostring(body))end
        error(body)
    end
    local downloaded=clock.gettime()
    require('readinknative/cache').recordAccess(client.data.vid,info,fresh,mode)
    local C=require('readinknative/content');local files=A.unpack(body,headers,client,info,{fresh})
    local unpacked=clock.gettime()
    local context=C.prefetchImages(files,info,{fresh},client)
    local imagesReady=clock.gettime()
    local path,images=C.prepareFiles(files,client.data.vid,info,fresh,mode,context)
    assert(images.complete,'IMAGES_INCOMPLETE')
    if info._pdfText and info._pdfText.pending then require('readinknative/pdftext').confirm(info,client.data.vid,fresh,path)end
    require('logger').info('ReadInk chapter body download/unpack/images/prepare ms:',
        math.floor((downloaded-began)*1000),math.floor((unpacked-downloaded)*1000),
        math.floor((imagesReady-unpacked)*1000),math.floor((clock.gettime()-imagesReady)*1000))
    return {path=path,images=images,mode=mode,book=info,chapter=fresh}
end
function A.prepareChapters(client,info,chapters,offline)
    assert(#chapters>0 and #chapters<=5,'CHAPTER_BATCH_INVALID')
    if #chapters==1 then
        local value=A.prepareChapter(client,info,chapters[1],offline)
        assert(chapters[1].offlineMode~='full'or value.mode=='full','READING_PERMISSION_REQUIRED')
        return{value}
    end
    if info._readPermission and os.time()>=info._readPermission.untilTime then info=A.info(client,info)end
    local results={};local index=1;local P=require('readinknative/permission');local C=require('readinknative/content')
    while index<=#chapters do
        local mode=P.mode(info,chapters[index],client.data.vid);local group={}
        while index<=#chapters and P.mode(info,chapters[index],client.data.vid)==mode do group[#group+1]=chapters[index];index=index+1 end
        for _,ch in ipairs(group)do assert(ch.offlineMode~='full'or mode=='full','READING_PERMISSION_REQUIRED')end
        local missing,prepared={},{};local Cache=require('readinknative/cache');local Images=require('readinknative/images')
        for _,ch in ipairs(group)do
            local path=Cache.stored(client.data.vid,info,ch,mode)
            if path and Images.ready(path)then
                Cache.recordAccess(client.data.vid,info,ch,mode)
                prepared[tostring(ch.chapterUid)]={path=path,images=Images.status(path),mode=mode,book=info,chapter=ch,reused=true}
            else missing[#missing+1]=ch end
        end
        if #missing>0 then
            local body,headers=A.downloadMany(client,info,missing,mode,offline)
            local files=A.unpack(body,headers,client,info,missing)
            for _,ch in ipairs(missing)do C.package(files,info,ch)end
            local imageContext=C.prefetchImages(files,info,missing,client)
            for _,ch in ipairs(missing)do
                Cache.recordAccess(client.data.vid,info,ch,mode)
                local path,images=C.prepareFiles(files,client.data.vid,info,ch,mode,imageContext)
                prepared[tostring(ch.chapterUid)]={path=path,images=images,mode=mode,book=info,chapter=ch}
            end
        end
        for _,ch in ipairs(group)do results[#results+1]=prepared[tostring(ch.chapterUid)]end
    end
    if info._pdfText and info._pdfText.pending and results[1]then require('readinknative/pdftext').confirm(info,client.data.vid,results[1].chapter,results[1].path)end
    return results
end
-- Ephemeral read metadata; never persisted as an entitlement or a shelf item.
-- A context can only remove duplicate reads within the same fresh opening.
function A.readContext(client,book,catalog)
    return{schema=1,vid=client.data and client.data.vid,book=book,catalog=catalog,at=os.time()}
end
function A.contextBook(client,book,context,needCatalog)
    if not client.data or type(context)~='table'or context.schema~=1 or context.vid~=client.data.vid or type(context.book)~='table'
        or tostring(context.book.bookId)~=tostring(book.bookId)or tostring(context.book.version or 0)~=tostring(book.version or 0)
        or type(context.at)~='number'or os.time()<context.at or os.time()-context.at>30
        or needCatalog and type(context.catalog)~='table'then return end
    local proof=context.book._readPermission
    if proof and(proof.vid~=client.data.vid or proof.bookId~=tostring(book.bookId)or type(proof.checkedAt)~='number'or os.time()<proof.checkedAt or proof.allowed and(type(proof.untilTime)~='number'or os.time()>=proof.untilTime))then return end
    return context.book,context.catalog
end
function A.chapter(client,book,chapter,options)
    -- Refresh server permission flags before a new full download. Cached local
    -- files do not trigger a request; unconfirmed rights use preview.
    local info,catalog=A.contextBook(client,book,options and options.context,true);local reused=info~=nil
    if not info then info=A.info(client,book);catalog=A.catalog(client,info)end
    local fresh
    for _,item in ipairs(catalog)do if tostring(item.chapterUid)==tostring(chapter.chapterUid)then fresh=item;break end end
    assert(fresh,'CATALOG_EMPTY')
    -- Publish the current chapter only after its illustrations are complete;
    -- neighboring chapters remain background work.
    local result=A.prepareChapter(client,info,fresh,false)
    result.catalog=catalog;result.contextReused=reused
    -- Return the readable body immediately. The visible reader fetches its
    -- first verified marks asynchronously; only the offline queue prepares
    -- complete references before announcing a whole-book download.
    return result
end
return A
