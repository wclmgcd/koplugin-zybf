-- KOReader painting and gestures, based on official 2.1.2 resources and REA
-- findings. Android classes are reference evidence, never runtime dependencies.
local BB=require('ffi/blitbuffer')
local C=require('readinknative/collections');local Stats=require('readinknative/readingstats')
local V={}
local function rule(v,bb,y)
    bb:paintRect(v.layout.side,y,v.layout.w-2*v.layout.side,v.layout.s(1),BB.COLOR_LIGHT_GRAY)
end
local function heading(v,bb,title,extra)
    local a,l=v.app,v.layout;local s=l.s
    local extraWidth=extra and(s(extra[3]or 76)+(extra[4]and s(76)or 0))or 0
    v:icon(bb,'icon_toolbar_back',0,0,s(56),s(56),function()a:back()end)
    v:text(bb,title,s(60),s(15),s(80),s(22),true)
    v:text(bb,a.book.title,s(150),s(21),math.max(1,l.w-s(150)-l.side-extraWidth),s(14))
    if extra then
        local primary=s(extra[3]or 76);v:button(bb,extra[1],l.w-l.side-primary,0,primary,s(56),extra[2])
        if extra[4]then v:button(bb,extra[4][1],l.w-l.side-extraWidth,0,s(76),s(56),extra[4][2])end
    end
    rule(v,bb,s(55))
end
function V.mark(v,bb,x,y,selected)
    local s=v.layout.s
    bb:paintRect(x,y,s(22),s(22),BB.COLOR_BLACK)
    bb:paintRect(x+s(2),y+s(2),s(18),s(18),BB.COLOR_WHITE)
    if selected then bb:paintRect(x+s(6),y+s(6),s(10),s(10),BB.COLOR_BLACK)end
end
function V.pager(v,bb,page,pages,center,action)
    local a,l=v.app,v.layout;local y=l.listFooter
    rule(v,bb,y)
    v:button(bb,'‹',0,y,l.w/4,l.bottom,function()a:listTurn(-1)end)
    v:button(bb,center or (page..' / '..pages),l.w/4,y,l.w/2,l.bottom,action or function()end)
    v:button(bb,'›',l.w*3/4,y,l.w/4,l.bottom,function()a:listTurn(1)end)
end
-- Shared native e-ink footer follows the official back / bookmark / up-down layout.
function V.navigation(v,bb,page,pages,center,action)
    local a,l=v.app,v.layout;local s=l.s;local y=l.listFooter
    rule(v,bb,y)
    v:icon(bb,'icon_toolbar_back',0,y,s(72),l.bottom,function()a:back()end)
    local gw=s(136);local gx=l.w-l.side-gw
    bb:paintBorder(gx,y+s(8),gw,l.bottom-s(16),s(1),BB.COLOR_BLACK,s(20))
    bb:paintRect(gx+gw/2,y+s(8),s(1),l.bottom-s(16),BB.COLOR_LIGHT_GRAY)
    v:button(bb,'↑',gx,y,gw/2,l.bottom,function()a:listTurn(-1)end)
    v:button(bb,'↓',gx+gw/2,y,gw/2,l.bottom,function()a:listTurn(1)end)
    if center then
        local cx=s(84);local cw=math.max(1,gx-cx-s(16))
        bb:paintBorder(cx,y+s(8),cw,l.bottom-s(16),s(1),BB.COLOR_BLACK,s(20))
        v:button(bb,center,cx,y,cw,l.bottom,action)
    end
end
function V.catalog(v,bb)
    local a,l=v.app,v.layout;local s=l.s
    local rows=C.catalog(a);local page,pages=C.page(a.catalogPage,#rows,l.catalogRows);a.catalogPage=page
    v:text(bb,a.book.title,l.side,s(18),l.w-2*l.side-s(116),s(27),true)
    v:button(bb,page==pages and '↑ 去顶部' or '↓ 去底部',l.w-l.side-s(112),s(6),s(112),s(48),function()
        a.catalogPage=page==pages and 1 or pages;a:draw()
    end)
    local sy=s(66);local sw=l.w-2*l.side
    bb:paintBorder(l.side,sy,sw,s(40),s(1),BB.COLOR_BLACK,s(20))
    v:icon(bb,'abc_ic_search_api_material',l.side+s(8),sy,s(32),s(40))
    v:text(bb,(a.catalogQuery or '')~='' and a.catalogQuery or '搜索目录 / 已打开正文',l.side+s(48),sy+s(9),sw-s(64),s(17),true)
    v:hit({x=l.side,y=sy,w=sw,h=s(40)},function()a:searchCatalog()end)
    v:button(bb,'当前章节',l.side,s(107),s(100),s(32),function()a:showCatalog()end)
    if a.book.cloudProgress and not a.book.localFile then
        v:button(bb,'同步进度',l.side+s(108),s(107),s(108),s(32),function()a:openCloudChapter()end)
    end
    if not a.book.localFile then
        v:button(bb,'更新',l.w-l.side-s(68),s(107),s(68),s(32),function()a:refreshCatalog()end)
    else v:text(bb,page..' / '..pages,l.w-l.side-s(60),s(117),s(60),s(11))end
    rule(v,bb,l.listTop-s(1))
    local current=C.current(a)
    for i=1,l.catalogRows do
        local row=rows[(page-1)*l.catalogRows+i]
        if row then
            local chapter=row.chapter;local y=l.listTop+(i-1)*s(56)
            local locked=require('readinknative/catalogrights').locked(a,chapter)

            local selected=row.index==current
            local depth=tonumber(chapter.level or chapter.depth)or 1
            local indent=math.min(3,math.max(0,depth-1))*s(12)
            -- Only CRengine pages from the currently opened local file are comparable.
            local number=a.book.localFile and tonumber(chapter.page)or require('readinknative/pagination').chapterPage(a,chapter)
            if a.book.localFile and chapter.xpointer and a.document and a.document.doc:isXPointerInDocument(chapter.xpointer)then
                number=a.document.doc:getPageFromXPointer(chapter.xpointer)
            end
            v:text(bb,chapter.title,l.side+indent,y+s(16),l.w-2*l.side-s(64)-indent,s(19),selected,nil,
                selected and BB.COLOR_BLACK or nil,selected and BB.COLOR_WHITE or locked and BB.COLOR_DARK_GRAY or nil)
            if locked then v:icon(bb,'icon_reading_chapter_lock',l.w-l.side-s(32),y,s(32),s(56),nil,nil,{w=11,h=12})
            elseif number then v:text(bb,tostring(number),l.w-l.side-s(52),y+s(18),s(52),s(17))end
            rule(v,bb,y+s(55))
            v:hit({x=0,y=y,w=l.w,h=s(56)},function()a:selectChapter(chapter,row.index,{page=1,origin='catalog'})end)
        end
    end
    if #rows==0 then
        v:text(bb,(a.catalogQuery or '')=='' and '这本书没有目录' or '没有匹配的章节',l.side,l.listTop+s(56),l.w-2*l.side,s(19),true)
    end
    V.navigation(v,bb,page,pages,a.document and '书签 / 笔记' or '更新目录',function()
        if a.document then a:notes()else a:refreshCatalog()end
    end)
end
function V.notes(v,bb)
    local a,l=v.app,v.layout;local s=l.s
    heading(v,bb,'笔记',{a.notesEditing and '取消' or '选择',function()a:notesSelect()end})
    local rows=C.records(a);local page,pages=C.page(a.notesPage,#rows,l.noteRows);a.notesPage=page
    local selected=require('readinknative/selection').notes(a)
    v:text(bb,a.notesEditing and ('已选择 '..#selected..' 个') or ('笔记 · '..#rows),l.side,s(74),math.max(1,l.w-2*l.side-s(158)),s(19),true)
    local fx=l.w-l.side-s(148)
    if a.notesEditing then
        v:button(bb,#rows>0 and #selected==#rows and '取消全选' or '全选',fx,s(56),s(148),s(56),function()a:notesAll()end)
    else
    v:icon(bb,a.notesOnlyBookmarks and 'icon_note_header_bookmark_selected' or 'icon_note_header_bookmark',fx,s(56),s(28),s(56))
    v:button(bb,'仅显示书签',fx+s(28),s(56),s(120),s(56),function()
        a.notesOnlyBookmarks=not a.notesOnlyBookmarks;a.notesPage=1;a:draw()
    end,a.notesOnlyBookmarks)
    -- Include the icon in the filter's touch target.
    v:hit({x=fx,y=s(56),w=s(148),h=s(56)},function()a.notesOnlyBookmarks=not a.notesOnlyBookmarks;a.notesPage=1;a:draw()end)
    end
    -- The official notes page starts with a book overview card. Counts are local;
    -- an unavailable whole-book progress or duration must not become a fake zero.
    local cy=s(116);local ch=s(122);local cw=l.w-2*l.side
    bb:paintBorder(l.side,cy,cw,ch,s(1),BB.COLOR_BLACK,s(18))
    local cr={x=l.w-l.side-s(76),y=cy+s(14),w=s(60),h=s(88)}
    local hasCover=v:cover(bb,a.book,cr)
    local tx=l.side+s(18);local tw=cw-s(36)-(hasCover and s(82)or 0)
    v:text(bb,a.book.title,tx,cy+s(15),tw,s(21),true)
    v:text(bb,C.progress(a),tx,cy+s(53),tw,s(14),true)
    local total=#require('readinknative/annotations').list(a.state,a.book.bookId)
    local cloud=#require('readinknative/social').records(a)
    local context=a.social
    local cloudLabel=cloud>0 and(' · 云端已读 '..cloud..' 条')or(context and context.mineAt and' · 云端已更新'or'')
    if context and context.mine and context.mine.more then cloudLabel=cloudLabel..'（部分）'end
    if context and context.mineError then cloudLabel=cloudLabel..' · 云端读取未完成'end
    v:text(bb,'共 '..total..' 条本机记录'..cloudLabel..'\n本机时长 '..Stats.duration(Stats.total(a.state,a.book.bookId)),tx,cy+s(83),tw,s(12),false,2)
    for i=1,l.noteRows do
        local row=rows[(page-1)*l.noteRows+i]
        if row then
            local y=l.notesTop+(i-1)*s(152)
            v:text(bb,row.chapterTitle or a.book.title,l.side,y+s(11),l.w-2*l.side-(a.notesEditing and s(30)or 0),s(17),true)
            if a.notesEditing then V.mark(v,bb,l.w-l.side-s(22),y+s(11),(a.noteSelection or {})[row.id])end
            v:icon(bb,row.kind=='bookmark' and 'icon_note_bookmark' or row.kind=='highlight' and 'icon_note_underline' or 'icon_note_review',l.side,y+s(40),s(24),s(24),nil,nil,{w=24,h=24})
            local text=row.kind=='highlight' and row.text or row.kind=='note' and ((row.quote and (row.quote..' · ')or'')..row.text) or (row.cloud and row.quote or('记录时第 '..tostring(row.position.page or '?')..' 页'))
            v:text(bb,require('readinknative/annotations').summary(text),l.side+s(38),y+s(40),l.w-2*l.side-s(38),s(15),false,3)
            local meta=(row.cloud and('云端'..(row.kind=='bookmark'and'书签'or row.kind=='highlight'and'划线'or'想法'))or(row.kind=='bookmark' and '书签' or row.kind=='highlight' and '本地划线' or '本地笔记'))..' · '..(row.cloud and row.updated==0 and'时间未知'or os.date('%Y-%m-%d',row.updated))
            v:text(bb,meta,l.side+s(38),y+s(123),l.w-2*l.side-s(38),s(12))
            rule(v,bb,y+s(151))
            v:hit({x=0,y=y,w=l.w,h=s(152)},function()
                if a.notesEditing then a:toggleSelection('noteSelection',row.id)else require('readinknative/readingmenu').annotation(a,row)end
            end)
        end
    end
    if #rows==0 then
        local y=l.notesTop;local h=math.min(s(116),l.listFooter-y-s(12))
        bb:paintBorder(l.side,y,l.w-2*l.side,h,s(1),BB.COLOR_BLACK,s(18))
        v:text(bb,a.notesOnlyBookmarks and '尚未添加书签' or '在这里记录本书的想法、划线和书签',l.side+s(22),y+s(24),l.w-2*l.side-s(44),s(18),false,2)
    end
    if a.notesEditing then
        local y=l.listFooter;rule(v,bb,y)
        v:button(bb,'‹',0,y,l.w/4,l.bottom,function()a:listTurn(-1)end)
        v:button(bb,'复制',l.w/4,y,l.w/4,l.bottom,function()a:copySelectedNotes()end)
        v:button(bb,'删除',l.w/2,y,l.w/4,l.bottom,function()a:deleteSelectedNotes()end)
        v:button(bb,'›',l.w*3/4,y,l.w/4,l.bottom,function()a:listTurn(1)end)
    else V.navigation(v,bb,page,pages,'写笔记',function()a:editNote()end)end
end
function V.settings(v,bb)
    local a,l=v.app,v.layout;local s=l.s
    v:icon(bb,'icon_toolbar_back',0,0,s(56),s(56),function()a:back()end)
    v:text(bb,'设置',s(60),s(16),l.w-s(80),s(22),true);rule(v,bb,s(55))
    local rows=a:settingsItems();local page,pages=C.page(a.settingsPage,#rows,l.settingsRows);a.settingsPage=page
    for i=1,l.settingsRows do
        local row=rows[(page-1)*l.settingsRows+i]
        if row then
            local y=s(56)+(i-1)*s(72)
            v:text(bb,row[1],l.side,y+s(13),l.w-2*l.side-s(88),s(18),true)
            if row[2]then v:text(bb,row[2],l.side,y+s(44),l.w-2*l.side-s(88),s(13))end
            if row[4]~=nil then
                local sx=l.w-l.side-s(52);local sy=y+s(25)
                if row[4]then bb:paintRoundedRect(sx,sy,s(52),s(26),BB.COLOR_BLACK,s(13))
                else bb:paintBorder(sx,sy,s(52),s(26),s(1),BB.COLOR_BLACK,s(13))end
                bb:paintRoundedRect(sx+s(row[4] and 29 or 5),sy+s(5),s(16),s(16),row[4] and BB.COLOR_WHITE or BB.COLOR_BLACK,s(8))
            else v:icon(bb,'icon_me_arrow',l.w-l.side-s(16),y,s(16),s(72),nil,nil,{w=12,h=18})end
            rule(v,bb,y+s(71));v:hit({x=0,y=y,w=l.w,h=s(72)},row[3])
        end
    end
    V.navigation(v,bb,page,pages)
end
function V.search(v,bb)
    local a,l=v.app,v.layout;local s=l.s;heading(v,bb,'搜索')
    local rows=a.searchResults or {};local page,pages=C.page(a.searchPage,#rows,l.searchRows);a.searchPage=page
    v:text(bb,a.textQuery or '',l.side,s(70),l.w-2*l.side,s(17),true)
    v:text(bb,require('readinknative/booksearch').scope(a),l.side,s(94),l.w-2*l.side,s(12))
    for i=1,l.searchRows do
        local row=rows[(page-1)*l.searchRows+i]
        if row then
            local y=l.listTop+(i-1)*s(88)
            local previous=i>1 and rows[(page-1)*l.searchRows+i-1]
            local section=not row.chapterUid or not previous or previous.chapterUid~=row.chapterUid
            if section then
                v:text(bb,row.chapterTitle or ('第 '..row.page..' 页'),l.side,y+s(6),l.w-2*l.side-s(18),s(17),true)
                if row.cacheMode=='preview'and require('readinknative/catalogrights').locked(a,a.chapters[row.chapterIndex])then
                    v:icon(bb,'icon_chapter_lock',l.w-l.side-s(16),y+s(7),s(16),s(18))
                end
            end
            local text,matched=require('readinknative/booksearch').snippet(row)
            local sy=y+s(section and 34 or 10)
            local box=v:text(bb,text,l.side,sy,l.w-2*l.side,s(15),false,section and 2 or 3)
            require('readinknative/booksearch').highlight(bb,box,text,matched,l.side,sy)
            rule(v,bb,y+s(87));v:hit({x=0,y=y,w=l.w,h=s(88)},function()a:jumpSearchResult(row)end)
        end
    end
    if #rows==0 then v:text(bb,require('readinknative/booksearch').empty(a),l.side,l.listTop+s(56),l.w-2*l.side,s(19),true,3)end
    V.pager(v,bb,page,pages)
end
function V.homeTabs(v,bb,selected,options)
    require('readinknative/homebar').draw(v,bb,selected,options)
end
function V.account(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local ready=a.client:ready()
    local name=tostring(ready and (a.client.data.name or '微信读书用户') or '登录微信读书')
    local nameWidth=l.w-2*l.side-s(160)
    local nameBox=v:text(bb,name,l.side,s(24),nameWidth,s(28),true)
    local nameHeight=nameBox and nameBox.getSize and nameBox:getSize().h or s(42)
    local header,profileKey=require('readinknative/readprofile').header(v,bb,ready)
    v:hit({x=0,y=0,w=l.w,h=header},function()a:accountDetails()end)
    v:button(bb,require('readinknative/preferences').exitButtonLabel(),l.w-l.side-s(144),s(16),s(144),s(48),function()a:exit()end)
    rule(v,bb,header-s(1))
    local rows={
        {'icon_me_account','账户',ready and require('readinknative/accountinfo').memberText(a.state.accountInfo) or '登录后同步书架与封面',function()a:accountDetails()end},
        {'icon_me_article','微信文章','微信文章收藏 | 微信浮窗文章',function()require('readinknative/articles').enter(a)end},
        {'icon_me_reader','微信读书阅读器','Kindle 原生系统 · KOReader',function()a:about()end},
        {'icon_me_preference','设置','翻页、阅读时间、字体及本机工具',function()a:accountSettings()end},
        {'icon_me_update','版本更新',require('readinknative/version'),function()a:message('阅墨 '..require('readinknative/version')..'\n更新检查尚未接入。')end},
    }
    -- Scrollable Android rows become bounded pages on native e-ink screens.
    local capacity=math.max(1,math.min(#rows,math.floor((l.h-l.bottom-header-s(40))/s(96))))
    local page,pages=C.page(a.accountPage,#rows,capacity);a.accountPage=page
    local rowKeys={tostring(capacity),tostring(page),tostring(pages)};local rowsBottom=header
    for i=1,capacity do
        local index=(page-1)*capacity+i;local row=rows[index]
        if row then
            local y=header+(i-1)*s(96)
            v:icon(bb,row[1],l.side,y,s(36),s(96),nil,nil,{w=36,h=36})
            local tx=l.side+s(52);local tw=l.w-tx-l.side-s(32)
            v:text(bb,row[2],tx,y+s(22),tw,s(20),true)
            if row[3]then v:text(bb,row[3],tx,y+s(56),tw,s(14))end
            v:icon(bb,'icon_me_arrow',l.w-l.side-s(16),y,s(16),s(96),nil,nil,{w=12,h=18})
            rule(v,bb,y+s(95))
            v:hit({x=0,y=y,w=l.w,h=s(96)},row[4])
            rowKeys[#rowKeys+1]=table.concat({tostring(index),row[1],row[2],tostring(row[3]or'')},'\0')
            rowsBottom=y+s(95)+s(1)
        end
    end
    V.homeTabs(v,bb,'account',{page=page,pages=pages,turn=function(delta)a.accountPage=page+delta;a:draw()end})
    -- Record actual measured geometry after painting; the refresh coordinator
    -- compares submitted frames and preserves the native popup's own region.
    local pad=s(2)
    local function padded(x,y,w,h)return{x=x-pad,y=y-pad,w=w+2*pad,h=h+2*pad}end
    local half=math.min(s(64),math.floor((l.w*0.4-s(16))/2))
    local rowsRect=padded(l.side,header-s(1),l.w-2*l.side,rowsBottom-header+s(1))
    rowsRect.h=math.max(0,math.min(rowsRect.y+rowsRect.h,l.h-l.bottom)-rowsRect.y)
    require('readinknative/accountrefresh').painted(v,bb,{layout=l,w=l.w,h=l.h,fontScale=v.fontScale,header=header,
        nameKey=name,profileKey=profileKey,rowKey=table.concat(rowKeys,'\0'),pagerKey=tostring(page>1)..':'..tostring(page<pages),
        nameRect=padded(l.side,s(24),nameWidth,nameHeight),statsRect=padded(l.side,s(78),l.w-2*l.side,header-s(78)),
        rowsRect=rowsRect,pagerRect=padded(l.w-s(8)-2*half,l.h-l.bottom,2*half,l.bottom)})
end
function V.accountDetails(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local ready=a.client:ready()
    local compact=l.h<s(540)
    v:icon(bb,'icon_toolbar_back',0,0,s(56),s(56),function()a:back()end)
    v:text(bb,'账户',s(60),s(16),l.w-s(80),s(22),true);rule(v,bb,s(55))
    local x=l.side;local w=l.w-2*x;local y=s(76)
    bb:paintBorder(x,y,w,s(104),s(1),BB.COLOR_BLACK,s(16))
    v:text(bb,ready and (a.client.data.name or '微信读书用户')or'微信扫码登录',x+s(20),y+s(20),w-s(40),s(24),true)
    v:text(bb,ready and '账号已登录 · 登录信息保存在本机' or '登录后可同步真实书架与封面',x+s(20),y+s(64),w-s(40),s(14))
    local info=a.state.accountInfo or{};local member=require('readinknative/accountinfo')
    local balance=info.balance and string.format('%.2f',info.balance.balance)or'未读取'
    local rows={{'书币余额',balance},{'会员卡',member.memberText(info)}}
    if ready then v:button(bb,'更新',l.w-l.side-s(64),0,s(64),s(56),function()member.refresh(a)end)end
    for i,row in ipairs(rows)do
        local top=s(200)+(compact and 0 or (i-1)*s(92))
        local rw=compact and (w-s(16))/2 or w;local rx=x+(compact and (i-1)*(rw+s(16))or 0)
        bb:paintBorder(rx,top,rw,s(78),s(1),BB.COLOR_BLACK,s(16))
        v:text(bb,row[1],rx+s(20),top+s(14),rw-s(40),s(18),true)
        v:text(bb,row[2],rx+s(20),top+s(45),rw-s(40),s(14))
    end
    local by=s(compact and 304 or 406)
    bb:paintBorder(x,by,w,s(48),s(1),BB.COLOR_BLACK,s(24))
    v:button(bb,ready and '退出账号（需重新扫码）'or'微信扫码登录',x,by,w,s(48),function()
        if ready then a:confirmLogout()else a:login()end
    end)
    local status=(info.balanceError or info.membershipError)and('更新未完成：'..(info.balanceError or info.membershipError))or
        info.membershipUpdated and('账户快照 · '..os.date('%m-%d %H:%M',info.membershipUpdated))or'进入账户时联网读取余额和会员信息'
    v:text(bb,status,x,s(compact and 374 or 476),w,s(12),false,2)
    v:text(bb,'本书可读范围以服务端返回为准。',x,s(compact and 412 or 514),w,s(12))
    v:icon(bb,'icon_toolbar_back',0,l.listFooter,s(72),l.bottom,function()a:back()end)
end
return V
