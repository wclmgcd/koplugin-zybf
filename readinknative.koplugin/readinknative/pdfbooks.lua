-- Preserve fixed-layout PDFs with KOReader's native MuPDF reader. EPUB/TXT
-- keep their independent gesture6 reader and its original state machinery.
local P={};local Cache=require('readinknative/pdfcache')
function P.isPdf(book)
    return book and(type(book.format)=='string'and book.format:lower()=='pdf'
        or type(book.localFile)=='string'and book.localFile:lower():match('%.pdf$')~=nil)or false
end
local function fromShelf(a,book)
    for _,b in ipairs(a.state.books or{})do if not b.localFile and tostring(b.bookId)==tostring(book.bookId)then return true end end
    return false
end
function P.status(a,book)
    local key=tostring(book.bookId)
    if a.pdfDownloads and a.pdfDownloads[key]then return 2 end
    if Cache.find(a.client.data.vid,book)then return 3 end
    return a.pdfFailures and a.pdfFailures[key]and 5 or 0
end
local function merge(a,book,info)
    for k,v in pairs(info or{})do if type(k)=='string'and k:sub(1,1)~='_'and k~='localFile'then book[k]=v end end
    a.state:flush()
end
local function restoreShelf(snapshot)
    local UI=require('ui/uimanager');local FM=require('apps/filemanager/filemanager');local fm=FM.instance
    if not fm or fm.tearing_down or not UI:isWidgetShown(fm)then return end
    local plugin=fm.readinknative
    if not plugin then return end
    plugin:open()
    UI:nextTick(function()
        local a=plugin.app
        if not a or a.closed or tostring(a.client.data.vid)~=snapshot.vid then return end
        a.query=snapshot.query;a.shelfGroup=snapshot.group;a.shelfPage=snapshot.page
        a:draw();a:loadCovers()
    end)
end
function P.attach(reader,snapshot)
    require('readinknative/pdfsync').attach(reader,snapshot.sync)
    require('readinknative/wallpaper').attachPdf(reader,snapshot.sync)
    if reader.readinkPdfReturn then return end
    reader.readinkPdfReturn=true
    local original=reader.showFileManager
    reader.showFileManager=function(ui,file,selected)
        -- Normal reader Back/Home reaches this after its own settings flush and
        -- close. An explicit KOReader Exit never invokes this return hook.
        local result=original(ui,file,selected)
        require('ui/uimanager'):nextTick(function()restoreShelf(snapshot)end)
        return result
    end
    local reload=reader.reloadDocument
    reader.reloadDocument=function(ui,afterClose,seamless,afterOpen)
        return reload(ui,afterClose,seamless,function(nextReader)
            P.attach(nextReader,snapshot);if afterOpen then afterOpen(nextReader)end
        end)
    end
end
function P.handoff(a,book,path)
    Cache.validate(path)
    local Reader=require('apps/reader/readerui');local provider=require('document/pdfdocument')
    local snapshot={vid=tostring(a.client.data.vid),query=a.query or'',group=a.shelfGroup,page=a.shelfPage or 1,
        sync={state=a.state,client=a.client,book=book,syncEnabled=a.syncEnabled}}
    require('readinknative/shelforder').touch(a.state,book);a.state:flush()
    -- Close through the existing path, which releases CRe and gesture owners,
    -- saves the prior book, and restores the host before native reader setup.
    a:close()
    Reader:showReader(path,provider,false,true,function(reader)P.attach(reader,snapshot)end)
end
function P.cancel(a)
    if a.pdfTextOpening then a.pdfTextOpening=nil;if a.jobs then a.jobs:cancel()end end
    if a.pdfDownloads and next(a.pdfDownloads)then a.jobs:cancel();a.pdfDownloads={}end
end
function P.request(a,books,done)
    P.cancel(a)
    local state,vid=a.state,a.client.data.vid;local owner={};local selected={}
    a.pdfDownloads=a.pdfDownloads or{};a.pdfFailures=a.pdfFailures or{}
    for _,b in ipairs(books)do
        local key=tostring(b.bookId);a.pdfDownloads[key]=owner;a.pdfFailures[key]=nil
        selected[key]=fromShelf(a,b)
    end
    local function clear(failed)
        for _,b in ipairs(books)do local key=tostring(b.bookId)
            if a.pdfDownloads[key]==owner then a.pdfDownloads[key]=nil;a.pdfFailures[key]=failed or nil end
        end
    end
    return a:remote('下载 PDF',function(client)
        local results={}
        for _,b in ipairs(books)do results[#results+1]=Cache.fetch(client,b,selected[tostring(b.bookId)])end
        return results
    end,function(results)
        clear(false)
        for i,result in ipairs(results)do merge(a,books[i],result.book)end
        if done then done(results)else a:draw()end
    end,nil,{valid=function()return not a.closed and not a.suspended and a.state==state and a.client.data.vid==vid end,
        failed=function(err)clear(true);if not a.closed then a:failure(err);a:draw()end end,
        cancelled=function()clear(false);if not a.closed then a:draw()end end})
end
function P.openOriginal(a,book)
    if book.localFile then
        local ok,err=pcall(P.handoff,a,book,book.localFile)
        if not ok then a:failure(err)end;return
    end
    local cached=Cache.find(a.client.data.vid,book)
    if cached then local ok,err=pcall(P.handoff,a,book,cached);if not ok then a:failure(err)end;return end
    return P.request(a,{book},function(results)
        local ok,err=pcall(P.handoff,a,book,results[1].path);if not ok then a:failure(err)end
    end)
end
function P.open(a,book)
    if book.localFile then return P.openOriginal(a,book)end
    return require('readinknative/pdftext').open(a,book)
end
return P
