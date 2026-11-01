local BB=require('ffi/blitbuffer');local A=require('readinknative/actionpages');local V={}
local function rule(v,bb,y)bb:paintRect(v.layout.side,y,v.layout.w-2*v.layout.side,v.layout.s(1),BB.COLOR_LIGHT_GRAY)end
local function header(v,bb,title)
    local l=v.layout;local s=l.s
    v:icon(bb,'icon_toolbar_back',0,0,s(56),s(56),function()v.app:back()end)
    v:text(bb,title,s(60),s(16),l.w-s(84),s(22),true);rule(v,bb,s(55))
end
function V.sort(v,bb)
    local a,l=v.app,v.layout;local s=l.s;header(v,bb,'书架排序')
    for i,row in ipairs({{'server','书架原顺序','保留同步后的书架排列'}, {'recent','最近阅读','最近在本机阅读的书排在前面'}, {'title','书名字序','按书名排列，保留同名书原顺序'}})do
        local y=s(76)+(i-1)*s(92);local selected=a.state.sort==row[1]
        bb:paintBorder(l.side,y,l.w-2*l.side,s(78),s(1),BB.COLOR_BLACK,s(16))
        require('readinknative/collectionview').mark(v,bb,l.w-l.side-s(40),y+s(26),selected)
        v:text(bb,row[2],l.side+s(18),y+s(13),l.w-2*l.side-s(82),s(20),true)
        v:text(bb,row[3],l.side+s(18),y+s(46),l.w-2*l.side-s(82),s(13))
        v:hit({x=l.side,y=y,w=l.w-2*l.side,h=s(78)},function()A.chooseSort(a,row[1])end)
    end
    v:icon(bb,'icon_toolbar_back',0,l.listFooter,s(72),l.bottom,function()a:back()end)
end
function V.cache(v,bb)
    local a,l=v.app,v.layout;local s=l.s
    v:text(bb,'清理缓存',0,s(16),l.w,s(22),false,1,nil,nil,nil,'center');rule(v,bb,s(55))
    local rows={{'cover','图片'},{'mp','公众号'},{'unread','30天未读书籍'},{'books','全部书籍'}}
    local height=math.min(s(100),math.floor((l.listFooter-s(90))/#rows))
    local compact=height<s(74)
    for i,row in ipairs(rows)do
        local group=(a.cacheSummary or{})[row[1]]or{count=0,bytes=0};local y=s(78)+(i-1)*height
        v:text(bb,row[2],l.side,y+s(compact and 4 or 10),l.w-2*l.side-s(100),s(compact and 17 or 20))
        local size=a.cacheBusy=='scan'and(a.cacheSummary and(string.format('%.2fM',group.bytes/1024/1024)..' · 更新中')or'正在统计…')or a.cacheBusy==row[1]and'正在清理…'or a.cacheError and'统计未完成'or string.format('%.2fM',group.bytes/1024/1024)
        v:text(bb,size,l.side,y+s(compact and 30 or 44),l.w-2*l.side-s(100),s(13))
        if(a.cacheBusy and a.cacheBusy~='scan')or a.cacheError or not a.cacheSummary then
            v:text(bb,'清理',l.w-l.side-s(80),y+math.floor(height/2)-s(10),s(80),s(17),false,1,nil,nil,nil,'center')
        else v:button(bb,'清理',l.w-l.side-s(80),y,s(80),height,function()A.clearCache(a,row[1])end)end
    end
    v:icon(bb,'icon_toolbar_back',0,l.listFooter,s(72),l.bottom,function()a:back()end)
end

function V.noteDetail(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local row=A.currentRecord(a)
    header(v,bb,row and ({note='笔记',highlight='划线',bookmark='书签'})[row.kind]or'记录已失效')
    if not row then
        v:text(bb,'这条记录已被删除或不属于当前书籍。',l.side,s(92),l.w-2*l.side,s(18),false,2);return
    end
    v:text(bb,row.chapterTitle or a.book.title,l.side,s(74),l.w-2*l.side,s(19),true)
    v:text(bb,'本机记录 · '..os.date('%Y-%m-%d %H:%M',row.updated),l.side,s(108),l.w-2*l.side,s(12))
    local text=row.kind=='bookmark' and ('记录时第 '..tostring(row.position.page or '?')..' 页')or row.kind=='note' and ((row.quote and ('原文\n'..row.quote..'\n\n笔记\n')or'')..row.text)or row.text
    a.detailPage,a.detailPages=v:pageText(bb,text,l.side,s(146),l.w-2*l.side,l.listFooter-s(230),s(17),a.detailPage or 1)
    local y=l.listFooter-s(76);rule(v,bb,y)
    local actions={{'定位原文',function()if A.currentRecord(a)==row then a:jumpAnnotation(row)end end},{'复制',function()A.copyRecord(a)end},
        {row.kind=='note' and '编辑' or '删除',function()if A.currentRecord(a)~=row then return end;if row.kind=='note'then a:editNote(row)else A.deleteRecord(a)end end}}
    if row.kind=='note'then actions[#actions+1]={'删除',function()A.deleteRecord(a)end}end
    for i,item in ipairs(actions)do v:button(bb,item[1],(i-1)*l.w/#actions,y,l.w/#actions,s(48),item[2])end
    v:text(bb,'第 '..a.detailPage..' / '..a.detailPages..' 页',l.side,l.listFooter-s(20),l.w-2*l.side,s(11))
    require('readinknative/collectionview').navigation(v,bb,a.detailPage,a.detailPages)
end
return V
