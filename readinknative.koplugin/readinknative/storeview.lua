local BB=require('ffi/blitbuffer');local S=require('readinknative/store');local V={}
local function rule(v,bb,y)bb:paintRect(v.layout.side,y,v.layout.w-2*v.layout.side,v.layout.s(1),BB.COLOR_LIGHT_GRAY)end
local function outline(v,bb,x,y,w,h,r)bb:paintBorder(x,y,w,h,v.layout.s(1),BB.COLOR_BLACK,v.layout.s(r or 16))end
local function sectionText(v,bb,text,x,y,w)
    -- Open-source CJK serif subset: the reference uses SiYuanSongTiHeavy.
    v:text(bb,text,x,y,w,v.layout.s(24),false,nil,nil,nil,(v.app.path or'.')..'/resources/fonts/ReadInkSectionSerif.otf')
end
local function cover(v,bb,b,x,y,w,h)
    if not v:cover(bb,b,{x=x,y=y,w=w,h=h})then
        bb:paintRect(x,y,w,h,BB.COLOR_LIGHT_GRAY)
        v:text(bb,b.title,x+v.layout.s(8),y+v.layout.s(18),math.max(1,w-v.layout.s(16)),v.layout.s(14),true,2,BB.COLOR_LIGHT_GRAY)
    end
end
local function book(v,bb,b,x,y,w,h,compact,rank)
    if not b then return end
    local s=v.layout.s;local cw=s(compact and 48 or 72);local ch=s(compact and 70 or 104)
    local numberWidth=not compact and rank and s(24)or 0
    if numberWidth>0 then v:text(bb,tostring(rank),x,y+s(44),numberWidth,s(16),true)end
    cover(v,bb,b,x+numberWidth,y+s(compact and 6 or 10),cw,ch)
    local tx=x+numberWidth+cw+s(compact and 12 or 18);local tw=math.max(1,w-(tx-x)-s(8))
    if compact and rank then v:text(bb,tostring(rank),tx,y+s(6),s(16),s(16),true);tx=tx+s(18);tw=tw-s(18)end
    v:text(bb,b.title,tx,y+s(8),tw,s(16),true,2)
    v:text(bb,b.author,tx,y+s(54),tw,s(12),compact)
    if rank and type(b.newRating)=='number'and b.newRating>=0 and b.newRating<=1000 then
        v:text(bb,string.format('推荐值 %.1f%%',b.newRating/10),tx,y+s(compact and 77 or 82),tw,s(11),true)
    end
    v:hit({x=x,y=y,w=w,h=h},function()S.detail(v.app,b)end)
end
local function search(v,bb,label)
    local a,l=v.app,v.layout;local s=l.s;local sy=s(6);local width=l.w-2*l.side
    outline(v,bb,l.side,sy,width,s(48),24)
    v:icon(bb,'abc_ic_search_api_material',l.side+s(10),sy,s(28),s(48),nil,nil,{w=20,h=20})
    v:text(bb,label or'搜索',l.side+s(46),sy+s(12),width-s(62),s(18),true,nil,nil,BB.COLOR_DARK_GRAY)
    v:hit({x=l.side,y=sy,w=width,h=s(48)},function()S.search(a)end)
end
local function header(v,bb,route)
    local a,l=v.app,v.layout;local s=l.s
    if route.kind=='home'then
        if (route.page or 1)==1 then search(v,bb,route.data and route.data.searchHint or'搜索微信读书')end
    elseif route.kind=='search'then
        search(v,bb,route.query);v:text(bb,'搜索结果',l.side,s(65),l.w-2*l.side,s(14),true)
    else
        if route.category and route.category.headerImage and v:cover(bb,{cover=route.category.headerImage},{x=l.side,y=s(20),w=math.min(s(204),l.w-2*l.side),h=s(32)})then
        else v:text(bb,route.title or'书城',l.side,s(20),l.w-2*l.side-s(56),s(24),true)end
        if route.loading then v:text(bb,'…',l.w-l.side-s(40),s(18),s(40),s(22),true)
        else v:icon(bb,'icon_general_reload',l.w-l.side-s(40),s(8),s(40),s(56),function()S.fetch(a,false)end,nil,{w=20,h=20})end
        rule(v,bb,s(75))
    end
end
local function section(v,bb,row,y)
    local a,l=v.app,v.layout;local s=l.s;local right=row.category or row.action
    local tw=l.w-2*l.side-(right and s(100)or 0)
    if not(row.headerImage and v:cover(bb,{cover=row.headerImage},{x=l.side,y=y+s(20),w=math.min(s(204),tw),h=s(32)}))then
        local title=row.title
        if row.headerImage then title=title:gsub('·出版','榜')end
        sectionText(v,bb,title,l.side,y+s(19),tw)
    end
    if row.localRecent then v:text(bb,'本机',l.w-l.side-s(40),y+s(27),s(40),s(11),false,nil,nil,BB.COLOR_DARK_GRAY)end
    if right then
        local x=l.w-l.side-s(88);local by=y+s(22)
        outline(v,bb,x,by,s(88),s(30),15)
        if row.category then v:button(bb,'查看全部',x,by,s(88),s(30),function()S.category(a,row.category)end)
        else
            local label=require('ui/widget/textwidget'):new{text=a.store.route.shuffling and'加载中'or a.store.route.shuffleError and'重试'or'换一批',face=require('ui/font'):getFace('cfont',s(15)/v.fontScale),max_width=s(60),bold=true}
            v.objects[#v.objects+1]=label
            local z=label:getSize();local iw,gap=s(14),s(5);local left=x+(s(88)-iw-gap-z.w)/2
            -- Text uses its actual shaped font height, sharing the icon's center.
            v:icon(bb,'icon_general_reload',left,by,iw,s(30),nil,nil,{w=14,h=14})
            label:paintTo(bb,math.floor(left+iw+gap),math.floor(by+(s(30)-z.h)/2))
            v:hit({x=x,y=by,w=s(88),h=s(30)},function()S.shuffle(a)end)
        end
    end
    rule(v,bb,y+row.height-s(1))
end
local function categoryCard(v,bb,c,x,y,w,h)
    if not c then return end
    local l=v.layout;local s=l.s;local cy=y+s(8);local ch=h-s(16)
    bb:paintBorder(x,cy,w,ch,s(1),BB.COLOR_LIGHT_GRAY,s(12))
    local coverW=s(36);local coverH=s(52);local coverY=cy+math.floor((ch-coverH)/2)
    if c.cover then cover(v,bb,{cover=c.cover,title=c.title},x+s(16),coverY,coverW,coverH)end
    local tx=x+s(68);local tw=math.max(1,w-s(82))
    v:text(bb,c.title,tx,cy+s(24),tw,s(17),true)
    if c.total then v:text(bb,tostring(c.total)..' 本书籍',tx,cy+s(51),tw,s(12),true)end
    v:hit({x=x,y=cy,w=w,h=ch},function()S.category(v.app,c)end)
end
local function centered(v,bb,text,x,y,w,size,bold,lines)
    return v:text(bb,text,x,y,w,size,bold,lines or 1,nil,nil,nil,'center')
end
local function introText(value)
    local paragraphs={}
    for line in (tostring(value or''):gsub('\r\n','\n'):gsub('\r','\n')..'\n'):gmatch('(.-)\n')do
        line=line:gsub('^[ \t]+',''):gsub('[ \t]+$','')
        if line~=''then paragraphs[#paragraphs+1]=line end
    end
    return #paragraphs>0 and table.concat(paragraphs,'\n\n')or'暂无简介'
end
local function detail(v,bb,route)
    local a,l=v.app,v.layout;local s=l.s;local b=route.data and route.data.book or route.book
    if not b then return end
    local actionY=l.h-l.bottom-s(56)
    if route.detailTab=='intro'then
        v:text(bb,'简介',l.side,s(18),l.w-2*l.side,s(24),true)
        rule(v,bb,s(65))
        local inset=l.side+s(12);local top=s(88)
        local height=actionY-top-s(route.addMessage and 42 or 20)
        route.textPage,route.textPages=v:pageText(bb,introText(b.intro),inset,top,l.w-2*inset,height,s(20),route.textPage or 1,0.55)
    else
        local cardY=s(20);local cardBottom=actionY-s(12);local cardH=cardBottom-cardY
        outline(v,bb,l.side,cardY,l.w-2*l.side,cardH,26)
        local ch=math.min(s(270),math.floor(cardH*0.43));local cw=math.floor(ch/1.44)
        local top=cardY+s(28);local cx=math.floor((l.w-cw)/2)
        cover(v,bb,b,cx,top,cw,ch)
        local ty=top+ch+s(20);local tw=l.w-2*l.side-s(40);local tx=l.side+s(20)
        v:text(bb,b.title,tx,ty,tw,s(23),true,2,nil,nil,nil,'center')
        local authorY=ty+s(68)
        centered(v,bb,b.author,tx,authorY,tw,s(16),true)
        local ry=authorY+s(44)
        if type(b.newRating)=='number'and b.newRating>=0 and b.newRating<=1000 then
            v:text(bb,string.format('微信读书推荐值 %.1f%%',b.newRating/10),tx,ry,tw,s(18),true)
            ry=ry+s(34)
        end
        local detail=b.ratingDetail
        local statsY=cardBottom-s(58)
        if detail and ry+s(76)<statsY then
            if detail.title then v:text(bb,detail.title,tx,ry,tw/2,s(24),true)end
            if b.newRatingCount then v:text(bb,tostring(b.newRatingCount)..' 人点评',tx,ry+s(40),tw/2,s(13))end
            local total=(detail.good or 0)+(detail.fair or 0)+(detail.poor or 0)
            if total>0 then
                local bx=l.w/2+s(28);local bw=l.w-l.side-s(24)-bx
                for i,item in ipairs({{'推荐',detail.good},{'一般',detail.fair},{'不行',detail.poor}})do
                    if item[2]then
                        local by=ry+s((i-1)*24)
                        v:text(bb,item[1],l.w/2-s(14),by,s(40),s(12),true)
                        bb:paintRoundedRect(bx,by+s(6),bw,s(5),BB.COLOR_LIGHT_GRAY,s(2))
                        local filled=math.floor(bw*item[2]/total)
                        if filled>0 then bb:paintRoundedRect(bx,by+s(6),filled,s(5),BB.COLOR_BLACK,s(2))end
                    end
                end
            end
        end
        local meta={}
        if type(b.totalWords)=='number'then meta[#meta+1]=string.format('字数 %.1f 万字',b.totalWords/10000)end
        if type(b.publisher)=='string'then meta[#meta+1]=b.publisher end
        if #meta>0 and ry+s(18)<statsY then centered(v,bb,table.concat(meta,' · '),tx,statsY,tw,s(13),true)end
        centered(v,bb,'← 左滑开始阅读',tx,cardBottom-s(29),tw,s(13),true)
        v:hit({x=tx,y=cardBottom-s(40),w=tw,h=s(36)},function()S.read(a)end)
    end
    local added=S.inShelf(a,b.bookId);local pending=S.pendingAdd(a,b.bookId)
    local gap=s(12);local width=(l.w-2*l.side-2*gap)/3
    local adding=S.adding(a,b.bookId);local checking=adding and a.shelfAddOperation.checkOnly
    local labels={b.localFile and'本地文件'or added and'已在书架'or adding and(checking and'核对中…'or'加入中…')or pending and'核对书架'or'加入书架',route.detailTab=='intro'and'图书封面'or'查看简介',route.readRequested and'正在打开…'or'开始阅读'}
    local actions={function()S.addShelf(a)end,function()route.detailTab=route.detailTab=='intro'and'book'or'intro';a:draw()end,function()S.read(a)end}
    for i,label in ipairs(labels)do local x=l.side+(i-1)*(width+gap);outline(v,bb,x,actionY+s(8),width,s(36),18);v:button(bb,label,x,actionY+s(8),width,s(36),actions[i])end
    if route.addMessage then v:text(bb,route.addMessage,l.side,actionY-s(24),l.w-2*l.side,s(11))end
end
function V.draw(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local ctx=a.store;local route=ctx and ctx.route
    if not route then return end
    if route.kind~='detail'then header(v,bb,route)end
    if route.kind=='detail'then
        detail(v,bb,route)
        require('readinknative/homebar').draw(v,bb,nil,{back=function()S.back(a)end,
            page=route.textPage or 1,pages=route.detailTab=='intro'and(route.textPages or 1)or 1,turn=function(d)S.turn(a,d)end})
        return
    end
    local pages=S.pages(a);local page=math.max(1,math.min(route.page or 1,#pages));route.page=page
    local y=route.kind=='home'and(page==1 and s(60)or 0)or s(88)
    for _,row in ipairs(pages[page])do
        if row.kind=='section'then section(v,bb,row,y)
        elseif row.kind=='recent'then
            local cell=(l.w-2*l.side-s(60))/4;local ch=math.min(math.floor(cell*1.44),row.height-s(24));local cw=math.floor(ch/1.44)
            for i,b in ipairs(row.books)do
                local x=l.side+(i-1)*(cell+s(20))
                cover(v,bb,b,x,y+s(20),cw,ch)
                v:hit({x=x,y=y,w=cell,h=row.height},function()S.detail(a,b)end)
            end
        elseif row.kind=='pair'then
            local width=(l.w-2*l.side-s(24))/2
            book(v,bb,row.left,l.side,y,width,row.height,true,row.leftRank)
            book(v,bb,row.right,l.side+width+s(24),y,width,row.height,true,row.rightRank)
        elseif row.kind=='book'then
            local ranked=route.category and route.category.rank==1
            book(v,bb,row.book,l.side,y,l.w-2*l.side,row.height,false,ranked and((row.sourceIndex or 1))or nil)
        elseif row.kind=='categoryPair'then
            local width=(l.w-2*l.side-s(20))/2
            categoryCard(v,bb,row.leftCategory,l.side,y,width,row.height)
            categoryCard(v,bb,row.rightCategory,l.side+width+s(20),y,width,row.height)
        elseif row.kind=='category'then
            v:text(bb,row.category.title,l.side,y+s(22),l.w-2*l.side-s(42),s(20),true)
            v:icon(bb,'icon_me_arrow',l.w-l.side-s(24),y,s(24),row.height,nil,nil,{w=12,h=18})
            rule(v,bb,y+row.height-s(1))
            v:hit({x=l.side,y=y,w=l.w-2*l.side,h=row.height},function()S.category(a,row.category)end)

        end
        y=y+row.height
    end
    if not route.data or #(route.data.items or{})==0 then
        local searching=route.kind=='search'
        v:text(bb,route.loading and(searching and'正在搜索…'or'正在加载书城')or route.error and(searching and'搜索未完成'or'书城加载未完成')or route.data and(searching and'没有找到相关书籍'or'没有找到可显示的书籍')or(searching and'点击重试搜索'or'点击重试加载书城'),l.side,s(216),l.w-2*l.side,s(21),true)
        if route.error and not route.loading then v:text(bb,'错误 '..route.error,l.side,s(264),l.w-2*l.side,s(14),false,2)end
        if not route.loading then v:button(bb,'重试',l.side,s(316),s(100),s(44),function()S.fetch(a,false)end)end
    elseif route.loading then v:text(bb,'正在加载…',l.side,l.h-l.bottom-s(26),l.w-2*l.side,s(11))
    elseif route.error then v:text(bb,'加载失败：'..route.error,l.side,l.h-l.bottom-s(26),l.w-2*l.side,s(11))end
    require('readinknative/homebar').draw(v,bb,'store',{page=page,pages=#pages,more=route.data and route.data.more,
        back=route.kind~='home'and function()S.back(a)end or nil,turn=function(d)S.turn(a,d)end})
end
return V
