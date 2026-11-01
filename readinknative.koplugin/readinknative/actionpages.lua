-- Secondary native scenes share the account/book guards of their parent views.
local M={}
local function valid(app,owner)
    return owner and not app.closed and owner.state==app.state and owner.vid==app.client.data.vid
end
function M.record(app,row)
    if not app.book then return end
    for _,value in ipairs(app.state.annotations)do
        if value==row and row.bookId==tostring(app.book.bookId)then
            app.noteDetail={row=row,state=app.state,book=app.book,vid=app.client.data.vid,
                returnMode=app.mode=='reader' and 'reader' or 'notes'}
            app.detailPage=1;app.panel=nil;app.mode='noteDetail';app:draw();return app.view
        end
    end
end
function M.currentRecord(app)
    local owner=app.noteDetail
    if not valid(app,owner)or owner.book~=app.book then return end
    for _,row in ipairs(app.state.annotations)do if row==owner.row and row.bookId==tostring(app.book.bookId)then return row end end
end
function M.copyRecord(app)
    local row=M.currentRecord(app);if not row then return end
    local input=require('device').input
    if not input or not input.setClipboardText then app:message('本机暂不支持剪贴板。');return end
    input.setClipboardText(require('readinknative/selection').noteText({row}));app:message('已复制这条本地记录。')
end
function M.deleteRecord(app)
    local row=M.currentRecord(app);if not row then return end
    local owner=app.noteDetail
    require('ui/uimanager'):show(require('ui/widget/confirmbox'):new{text=row.kind=='highlight'and'删除这条划线？已同步的划线也会从云端删除。'or'删除这条本地记录？',ok_text='删除',ok_callback=function()
        if app.noteDetail~=owner or M.currentRecord(app)~=row then return end
        require('readinknative/annotations').remove(app.state,row.id);app.state:flush();require('readinknative/annotationsync').changed(app)
        app.noteDetail=nil;app.mode=owner.returnMode;app:draw();app:startClock()
    end})
end
function M.sort(app)
    app.sortReturn=app.mode=='settings' and 'settings' or 'shelf'
    app.mode='sort';app:draw();return app.view
end
function M.chooseSort(app,key)
    if key~='server'and key~='recent'and key~='title'then return end
    app.coverJobs:cancel();app.state.sort=key;app.state:flush();app.shelfPage=1
    app.mode=app.sortReturn or 'shelf';app:draw();if app.mode=='shelf'then app:loadCovers()end
    if key=='recent'then require('readinknative/shelfmodel').invalidate(app);require('readinknative/shelfmodel').ensure(app)end
end
-- Cache inventory and deletion may walk thousands of FAT files. Paint first,
-- then use the same cancellable, non-modal subprocess contract as chapter IO.
local function cacheValid(app,owner)
    return valid(app,owner)and app.cacheOwner==owner and not app.suspended and app.mode=='cache'and not app.document
end
function M.cancelCache(app)
    if app.cacheStart then require('ui/uimanager'):unschedule(app.cacheStart);app.cacheStart=nil end
    if app.cacheJobs then app.cacheJobs:cancel()end
    if app.cachePlan then require('readinknative/cacheindex').close(app);app.cachePlan=nil end
    app.cacheOwner=nil;app.cacheBusy=nil
end
local function cacheWork(app,owner,kind)
    if not cacheValid(app,owner)then return end
    app.cacheBusy=kind or'scan';app.cacheError=nil
    app.cacheStart=function()
        app.cacheStart=nil
        if not cacheValid(app,owner)then return end
        app.cacheJobs=app.cacheJobs or require('readinknative/jobs').new()
        local C=require('readinknative/cache');local indexed=type(C.inventory)=='function'
        local I=indexed and require('readinknative/cacheindex');local w=I and I.ensure(app);local plan=w and I.plan(w)
        if plan then app.cachePlan=plan end
        app.cacheJobs:run('',function()
            local clock=require('ui/time');local began=clock.monotonic()
            local removed,failed,remaining;local rows;local stages={};local mark=began
            local function stage(label)local now=clock.monotonic();stages[#stages+1]=label..'='..math.floor(clock.to_ms(now-mark));mark=now end
            if kind then
                local baseline=plan and I.collect(plan)
                if plan then plan.pending,plan.ledgerOffset=require('readinknative/cachefiles').pending(plan.root)end
                removed,failed,remaining=C.clear(owner.vid,kind,owner.state,plan and I.observer(plan),baseline)
                rows=remaining

            elseif plan then rows=I.collect(plan)end
            stage('inventory')
            local groups,entries=C.groups(owner.vid,owner.state,nil,rows and function()return rows end)
            stage('categories-and-engine')
            if plan then
                local stored=pcall(require('readinknative/cacheledger').save,owner.vid,entries,plan.ledgerOffset,plan.pending)
                if not stored then require('readinknative/cachefiles').invalidate(plan.root)end
            end
            local saved=pcall(require('readinknative/cachesnapshot').save,owner.vid,entries,groups)
            if not saved then require('logger').warn('ReadInk cache summary persistence failed')end
            stage('persist')
            local snapshot=plan and I.pack(plan,entries)
            require('logger').info('ReadInk cache stages ms:',table.concat(stages,' '))
            require('logger').info('ReadInk cache worker ms/files/clear:',math.floor(clock.to_ms(clock.monotonic()-began)),groups.all.count,kind or'scan',removed or 0,failed or 0,groups.mp.count,groups.mp.bytes)
            if snapshot then require('logger').info('ReadInk cache index full/checked/rows:',snapshot.full,snapshot.checked,#snapshot.rows,snapshot.restored)end
            return {groups=groups,removed=removed,failed=failed,index=snapshot}
        end,function(ok,result)
            if not cacheValid(app,owner)then return end
            app.cachePlan=nil;app.cacheBusy=nil
            if not ok then
                if I then I.close(app)end
                app.cacheSummary=nil;app.cacheError=true;app:draw()
                require('logger').warn('ReadInk cache worker failed:',require('readinknative/errors').code(result))
                app:message('缓存处理未完成，请返回后重新进入缓存管理。');return
            end
            if I then I.accept(app,w,result.index,result.groups)end
            app.cacheSummary=result.groups
            if kind then
                local L=require('readinknative/chapterloader');L.engineCacheKnown={};L.engineCacheCount=0
                for _,image in pairs(app.view.coverObjects or{})do image:free()end
                app.view.coverObjects={};app.view.coverOrder={};app.view.badCovers={}
            end
            app:draw()
            if kind then app:message('已清理 '..result.removed..' 个文件'..(result.failed>0 and('，失败 '..result.failed..' 个')or''))end
        end,false)
    end
    -- Allow the cache scene and its back hit target to paint before fork/IO.
    require('ui/uimanager'):scheduleIn(0.05,app.cacheStart)
end
function M.cache(app)
    if app.closed or app.suspended then return end
    if app.document then app:message('请先返回书架再管理缓存。');return end
    M.cancelCache(app);app.jobs:cancel();app.coverJobs:cancel()
    require('readinknative/offline').beforeForeground(app)
    require('readinknative/chapterloader').stop(app);require('readinknative/chapterloader').cancel(app)
    require('readinknative/articleimages').cancel(app)
    app.cacheOwner={state=app.state,vid=app.client.data.vid}
    local saved,summary=pcall(function()return require('readinknative/cachesnapshot').summary(app.client.data.vid)end)
    app.cacheSummary=app.cacheIndex and app.cacheIndex.id==tostring(app.client.data.vid or'guest')and app.cacheIndex.summary or(saved and summary or nil)
    app.mode='cache';cacheWork(app,app.cacheOwner);app:draw();return app.view
end
function M.refreshCache(app)
    if not cacheValid(app,app.cacheOwner)or app.cacheBusy then return end
    cacheWork(app,app.cacheOwner);app:draw()
end
function M.clearCache(app,kind)
    if not cacheValid(app,app.cacheOwner)or(app.cacheBusy and app.cacheBusy~='scan')then return end
    local names={mp='公众号',books='全部书籍',unread='30天未读书籍',cover='图片'}
    local group=app.cacheSummary and app.cacheSummary[kind]
    if not names[kind]or not group or group.count==0 then return end
    local owner=app.cacheOwner
    require('ui/uimanager'):show(require('ui/widget/confirmbox'):new{text=(app.cacheBusy=='scan'and'按上次统计约 'or'即将清理 ')..string.format('%.2fM',group.bytes/1024/1024)..' 的「'..names[kind]..'」缓存\n再次阅读可能需要重新下载。书架、收藏、笔记、进度和登录设置会保留。',ok_text='清理',ok_callback=function()
        if not cacheValid(app,owner)or(app.cacheBusy and app.cacheBusy~='scan')then return end
        if app.cacheStart then require('ui/uimanager'):unschedule(app.cacheStart);app.cacheStart=nil end
        if app.cacheJobs then app.cacheJobs:cancel()end
        if app.cachePlan then require('readinknative/cacheindex').close(app);app.cachePlan=nil end
        app.cacheBusy=nil
        if kind=='books'or kind=='unread'then require('readinknative/offline').invalidate(app)end
        require('readinknative/resident').drop(app)
        if kind=='mp'then require('readinknative/articleimages').cancel(app);app.articles=nil end
        cacheWork(app,owner,kind);app:draw()
    end})
end
return M
