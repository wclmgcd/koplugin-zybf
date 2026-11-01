-- On-device rendering probe: synthetic fixtures only, no account/network writes.
local M={}
function M.run(app)
    if app.document then app:message('请先返回书架，再运行本机检查。');return end
    local root=require('readinknative/paths').account(app.client.data.vid)..'/diagnostics-alpha12'
    require('util').makePath(root)
    local report={version=require('readinknative/version'),kind='native static rendering probe',screens={},failures={}}
    local view,document,bb
    local ok,err=xpcall(function()
        local App=require('readinknative/app')
        local fixture=setmetatable({path=app.path,client={data={},ready=function()return false end},
            mode='shelf',query='',shelfPage=1,catalogPage=1,notesPage=1,settingsPage=1,
            book={bookId='readink-diagnostic',title='ReadInk 本机检查',author='原创演示',localFile=app.path..'/fixtures/演示书.epub'},
            state={annotations={},preferences={},sort='server',readingStats={books={},days={}}},draw=function()end},App)
        fixture.state.books={fixture.book}
        fixture.state.filtered=function(self)return self.books end
        fixture.state.format=function()return require('readinknative/format').normalize{}end
        view=require('readinknative/view'):new{app=fixture};fixture.view=view
        document=require('readinknative/document').open(fixture.book.localFile,view.layout.body.w,view.layout.body.h,26)
        fixture.document=document
        local pos=document:position()
        fixture.state.annotations={{id='diagnostic',kind='note',bookId=fixture.book.bookId,chapterTitle='演示章节',
            text='这是一条原创检查笔记，用于确认本机字体、图标和行布局可以绘制。',position=pos,created=1,updated=1}}
        local raw=document.doc:findAllText('ReadInk',true,5,200,false,0x00FF)[1]
        assert(raw and raw.start and raw['end'],'PROBE_RANGE_NOT_FOUND')
        local position={xpointer=raw.start,endXPointer=raw['end'],page=document.doc:getPageFromXPointer(raw.start)}
        fixture.state.annotations[#fixture.state.annotations+1]={id='diagnostic-underline',kind='highlight',bookId=fixture.book.bookId,
            chapterTitle='演示章节',text='ReadInk',position=position,created=1,updated=1}
        fixture.state.annotations[#fixture.state.annotations+1]={id='diagnostic-quoted-note',kind='note',bookId=fixture.book.bookId,
            chapterTitle='演示章节',text='这条笔记附带原文选区。',quote='ReadInk',position=position,created=1,updated=1}
        local BB=require('ffi/blitbuffer');bb=BB.new(view.dimen.w,view.dimen.h,BB.TYPE_BB8)
        report.width=view.dimen.w;report.height=view.dimen.h
        local function capture(name,mode,prepare)
            fixture:clearTextSelection();fixture.mode=mode;fixture.panel=nil;fixture.shelfEditing=false;fixture.notesEditing=false
            if prepare then prepare()end
            local success,error=xpcall(function()view:paintTo(bb,0,0);bb:writePNG(root..'/'..name..'.png')end,debug.traceback)
            if success then report.screens[#report.screens+1]=name else report.failures[#report.failures+1]={name=name,error=tostring(error)}end
        end
        capture('shelf','shelf')
        capture('shelf-select','shelf',function()fixture.shelfEditing=true;fixture.shelfSelection={[fixture.book.bookId]=true}end)
        capture('catalog','catalog')
        capture('notes','notes')
        capture('notes-select','notes',function()fixture.notesEditing=true;fixture.noteSelection={diagnostic=true}end)
        capture('account','account')
        capture('account-details','accountDetails')
        capture('sort','sort')
        capture('cache','cache',function()fixture.cacheSummary={all={count=0,bytes=0}}end)
        capture('note-detail','noteDetail',function()
            fixture.noteDetail={row=fixture.state.annotations[1],state=fixture.state,book=fixture.book,vid=fixture.client.data.vid,returnMode='notes'};fixture.detailPage=1
        end)
        capture('settings','settings')
        local sampleBook={bookId='store-diagnostic',title='原创书城检查',author='原创演示',format='epub',intro=string.rep('这是原创的书城检查简介。',50),newRating=805}
        local sampleCategory={id='fixture',title='示例分类',children={}}
        local function storeRoute(kind,data)
            fixture.store={state=fixture.state,vid=fixture.client.data.vid,stack={},tab='home',route={kind=kind,key='fixture:'..kind,title='书城检查',book=sampleBook,data=data}}
        end
        capture('store-home','store',function()storeRoute('home',{items={{kind='section',title='精选好书'},{kind='book',book=sampleBook}}})end)
        capture('store-categories','store',function()storeRoute('categories',{items={{kind='category',category=sampleCategory}}})end)
        capture('store-ranks','store',function()storeRoute('ranks',{items={{kind='category',category=sampleCategory}}})end)
        capture('store-detail','store',function()storeRoute('detail',{book=sampleBook})end)
        capture('store-intro','store',function()storeRoute('detail',{book=sampleBook});fixture.store.route.detailTab='intro'end)
        capture('store-search','store',function()storeRoute('search',{items={{kind='book',book=sampleBook}}})end)
        capture('store-error','store',function()storeRoute('search',{items={}});fixture.store.route.error='NETWORK_FAILED'end)
        capture('reader','reader',function()fixture.toolbar=false end)
        capture('underline','reader',function()fixture.toolbar=false end)
        capture('selection','reader',function()
            fixture.toolbar=false
            local boxes=document:rangeBoxes(position);assert(#boxes>0,'PROBE_RANGE_NOT_VISIBLE')
            local b=boxes[1];local point={x=b.x+b.w/2,y=b.y+b.h/2}
            local T=require('readinknative/textselection');assert(T.begin(fixture,point),'PROBE_SELECTION_FAILED');assert(T.finish(fixture))
        end)
        capture('quoted-notes','notes')
        capture('reader-time','reader',function()fixture.toolbar=false;fixture.state.preferences.showTime=true end)
        fixture.state.preferences.showTime=false
        capture('font','reader',function()fixture.toolbar=true;fixture.panel='font'end)
        capture('search','search',function()
            fixture.textQuery='阅读';fixture.searchResults=document:search('阅读');fixture.searchPage=1
        end)
        local chooser
        local imported,importError=xpcall(function()
            chooser=require('ui/widget/pathchooser'):new{path=app.path..'/fixtures',select_directory=false,select_file=true,
                title='本地导入检查',file_filter=function(name)return name:lower():match('%.epub$')end}
            chooser:paintTo(bb,0,0);bb:writePNG(root..'/import.png')
        end,debug.traceback)
        if chooser and chooser.free then chooser:free()end
        if imported then report.screens[#report.screens+1]='import'else report.failures[#report.failures+1]={name='import',error=tostring(importError)}end
        local login,qrSource,qrBB
        local qrOk,qrError=xpcall(function()
            qrBB=BB.new(320,320,BB.TYPE_BB8);qrBB:paintRect(0,0,320,320,BB.COLOR_WHITE)
            qrSource=require('ui/widget/qrwidget'):new{text='readink://synthetic-login-layout-test',width=256,height=256}
            qrSource:paintTo(qrBB,32,32);qrBB:writePNG(root..'/qr-source.png')
            login=require('readinknative/qrview'):new{path=root..'/qr-source.png',cancel=function()end}
            login:paintTo(bb,0,0);bb:writePNG(root..'/login.png')
        end,debug.traceback)
        if login then for _,key in ipairs({'image','text','cancelText'})do if login[key]then login[key]:free()end end end
        if qrSource then qrSource:free()end;if qrBB then qrBB:free()end
        if qrOk then report.screens[#report.screens+1]='login'else report.failures[#report.failures+1]={name='login',error=tostring(qrError)}end

    end,debug.traceback)
    if not ok then report.failures[#report.failures+1]={name='probe',error=tostring(err)}end
    if view then view:clearObjects();for _,image in pairs(view.coverObjects)do image:free()end end
    if bb then bb:free()end
    if document then document:close()end
    local f=assert(io.open(root..'/result.json','wb'));f:write(require('rapidjson').encode(report));f:close()
    app:draw();app:message('本机检查：'..#report.screens..' 个页面，'..#report.failures..' 项失败。\n截图及结果：\n'..root)
end
return M
