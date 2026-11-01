-- Card/heart/comment hierarchy observed on the official E-Ink reference phone.
local M=require('readinknative/social');local BB=require('ffi/blitbuffer');local V={}
local function rule(v,bb,y)bb:paintRect(v.layout.side,y,v.layout.w-2*v.layout.side,v.layout.s(1),BB.COLOR_LIGHT_GRAY)end
local function counter(value)return value and value>0 and tostring(value)or''end
local function footer(v,bb,page,pages,row)
    local a,l=v.app,v.layout;local s=l.s;local y=l.listFooter
    local c=a.social;local r=c and c.route;local more=false
    if not r or not M.valid(a,c,r)then r={}end
    if r.kind=='thoughts'then local all=M.pages(a);local last=all[#all];more=r.nextRange<=#r.ranges or last and last.group and last.group.more
    elseif r.kind=='hot'or r.kind=='reviews'then more=r.data and r.data.more and r.data.maxIdx~=nil
    elseif r.data and not r.expandedComment then more=r.tab=='comments'and r.data.moreComments or r.tab=='likes'and r.data.moreLikes end
    if r.kind=='detail'then
        bb:paintRect(0,y,l.w,s(1),BB.COLOR_LIGHT_GRAY)
        v:icon(bb,'icon_toolbar_back',l.side-s(4),y,s(40),l.bottom,function()M.back(a)end,nil,{w=28,h=28})
        local half=math.min(s(64),math.floor((l.w*0.4-s(16))/2));local px=l.w-s(8)-2*half
        local prev,next=page>1,page<pages or more==true
        v:icon(bb,prev and'icon_page_up'or'icon_page_up_disabled',px,y,half,l.bottom,function()if prev then M.turn(a,-1)end end,nil,{pixel_w=half,h=40})
        v:icon(bb,next and'icon_page_down'or'icon_page_down_disabled',px+half,y,half,l.bottom,function()if next then M.turn(a,1)end end,nil,{pixel_w=half,h=40})
        local x=l.side+s(44);local w=math.max(s(70),px-s(48)-x)
        bb:paintBorder(x,y+s(10),w,l.bottom-s(20),s(1),BB.COLOR_BLACK,s(20))
        v:icon(bb,'icon_review_detail_comment',x+s(10),y+s(10),s(22),l.bottom-s(20),nil,nil,{w=20,h=20})
        v:text(bb,r.expandedComment and'回复…'or'写评论…',x+s(40),y+s(17),w-s(46),s(15))
        v:hit({x=x,y=y+s(4),w=w,h=l.bottom-s(8)},function()require('readinknative/commentpublish').compose(a,r.expandedComment)end)
        if row then
            local lx=x+w+s(5);v:icon(bb,row.liked and'icon_review_like_selected'or'icon_review_like',lx,y,s(36),l.bottom,function()M.like(a,row)end,nil,{w=24,h=24})
        end
        return
    end
    require('readinknative/homebar').draw(v,bb,nil,{back=function()M.back(a)end,page=page,pages=pages,more=more==true,turn=function(delta)M.turn(a,delta)end})
    if row then
        local half=math.min(s(64),math.floor((l.w*0.4-s(16))/2));local cell=(l.w-s(16)-2*half)/3;local center=2*cell
        v:icon(bb,row.liked and'icon_review_like_selected'or'icon_review_like',center-s(12),y+s(4),s(24),s(24))
        v:text(bb,counter(row.likesCount),center-s(30),y+s(30),s(60),s(12),false,1,nil,nil,nil,'center')
        v:hit({x=cell,y=y,w=2*cell,h=l.bottom},function()M.like(a,row)end)
    end
end
local function avatar(v,bb,user,x,y,size,screenY,top,bottom)
    local A=require('readinknative/avatarcache');local image=user and user.avatar and A.load(v,v.app.client.data.vid,user.avatar,size)
    if image then bb:blitFrom(image,x,y,0,0,size,size)
    else
        bb:paintBorder(x,y,size,size,1,BB.COLOR_LIGHT_GRAY,math.floor(size/2))
        bb:paintCircle(x+math.floor(size/2),y+math.floor(size*0.35),math.max(1,math.floor(size*0.13)),BB.COLOR_LIGHT_GRAY,math.max(1,math.floor(size*0.1)))
        bb:paintRect(x+math.floor(size*0.28),y+math.floor(size*0.61),math.floor(size*0.44),math.max(1,math.floor(size*0.13)),BB.COLOR_LIGHT_GRAY)
    end
    require('readinknative/avatarpaint').record(v,user,size,x,screenY,top,bottom,image~=nil)
end
local function clippedHit(v,x,y,w,h,top,bottom,action)
    local start=math.max(y,top);local finish=math.min(y+h,bottom)
    if finish>start then v:hit({x=x,y=start,w=w,h=finish-start},action)end
end
local function flowText(v,bb,text,x,y,w,totalHeight,size,top,bottom,bold)
    if y>=bottom or y+totalHeight<=top then return end
    local Box=require('ui/widget/textboxwidget');local Font=require('ui/font')
    local face=Font:getFace('cfont',size/v.fontScale);local line=math.floor(1.3*face.size+0.5)
    local skipped=math.max(0,math.floor((top-y)/line))
    local height=math.min(totalHeight-skipped*line,bottom-y-skipped*line)
    height=math.max(line,math.ceil(height/line)*line)
    local box=Box:new{text=text,face=face,width=w,height=height,bold=bold or false,virtual_line_num=skipped+1}
    local viewport=bb:viewport(0,top,v.layout.w,bottom-top)
    box:paintTo(viewport,x,y+skipped*line-top);viewport:free();v.objects[#v.objects+1]=box
end
-- Only viewport-sized text/widgets are painted, even when a quote or card spans
-- many screens. The quote is the first flow item, never a pinned header.
function V.thoughts(v,bb,r)
    local a,l=v.app,v.layout;local s=l.s;local pages=M.pages(a);r.page=math.max(1,math.min(#pages,r.page));local page=pages[r.page]
    local x,w=l.side,l.w-2*l.side;local viewport=bb:viewport(0,page.top,l.w,l.listFooter-page.top)
    for _,item in ipairs(page.items)do
        local y=page.top+item.y-page.offset;local h=item.height
        if item.kind=='quote'then
            local q=r.quoteLayout;local bx=x+w-s(72)
            flowText(v,bb,q.text,x+s(16),y+s(15),q.width,q.body,s(17),page.top,l.listFooter)
            if y+s(86)>page.top then
                local scratch=BB.new(l.w,s(86),BB.TYPE_BB8);scratch:fill(BB.COLOR_WHITE)
                v:icon(scratch,M.highlighted(a,r)and'icon_reading_menu_delete_underline'or'icon_reading_menu_underline',bx+s(24),s(14),s(24),s(24))
                v:text(scratch,M.highlightBusy(a,r)and'保存中'or M.highlighted(a,r)and'删除划线'or'划线',bx+s(4),s(45),s(64),s(14),false,1,nil,nil,nil,'center')
                local t,b=math.max(y,page.top),math.min(y+s(80),l.listFooter)
                if b>t then bb:blitFrom(scratch,bx+s(1),t,bx+s(1),t-y,s(70),b-t)end;scratch:free()
            end
            viewport:paintBorder(x,y-page.top,w,h,s(1),BB.COLOR_BLACK,s(18))
            viewport:paintRect(bx,y-page.top,s(1),h,BB.COLOR_BLACK)
            clippedHit(v,bx,y,s(72),s(86),page.top,l.listFooter,function()M.highlight(a)end)
        elseif item.kind=='status'then
            local message=r.error=='SOCIAL_REQUEST_CANCELLED'and'已取消读取，点此重试'or r.error and'想法未能加载，点此重试'or not r.loaded and'正在读取这段划线的想法'or'这段划线暂无想法'
            flowText(v,bb,message,x,y+s(20),w,s(80),s(18),page.top,l.listFooter)
            clippedHit(v,x,y,w,h,page.top,l.listFooter,function()M.fetchGroups(a,false)end)
        else
            local row=item.row;local c=require('readinknative/sociallayout').card(a,row)
            if y+s(48)>page.top then
                local scratch=BB.new(l.w,s(48),BB.TYPE_BB8);scratch:fill(BB.COLOR_WHITE)
                avatar(v,scratch,row.author,x+s(16),s(14),s(28),y+s(14),page.top,l.listFooter-((r.error or r.mineError)and s(24)or 0))
                v:text(scratch,row.author.name,x+s(56),s(17),w-s(72),s(18),true)
                local t,b=math.max(y,page.top),math.min(y+s(48),l.listFooter)
                if b>t then bb:blitFrom(scratch,x+s(2),t,x+s(2),t-y,w-s(4),b-t)end;scratch:free()
            end
            flowText(v,bb,row.content~=''and row.content or'划线',x+s(16),y+s(52),w-s(32),c.body,s(17),page.top,l.listFooter)
            local by=h-s(38);local fy=y+by
            if fy<l.listFooter and fy+s(36)>page.top then
                local scratch=BB.new(l.w,s(36),BB.TYPE_BB8);scratch:fill(BB.COLOR_WHITE)
                scratch:paintRect(x+s(16),0,w-s(32),s(1),BB.COLOR_LIGHT_GRAY)
                v:icon(scratch,row.liked and'icon_review_like_selected'or'icon_review_like',x+w/4-s(26),s(4),s(24),s(24))
                v:text(scratch,counter(row.likesCount),x+w/4+s(4),s(8),w/4-s(12),s(14))
                v:icon(scratch,'icon_review_detail_comment',x+3*w/4-s(26),s(4),s(24),s(24))
                v:text(scratch,counter(row.commentsCount),x+3*w/4+s(4),s(8),w/4-s(12),s(14))
                local t,b=math.max(fy,page.top),math.min(fy+s(36),l.listFooter)
                if b>t then bb:blitFrom(scratch,x+s(2),t,x+s(2),t-fy,w-s(4),b-t)end;scratch:free()
            end
            viewport:paintBorder(x,y-page.top,w,h,s(1),BB.COLOR_BLACK,s(18))
            clippedHit(v,x,y,w,by,page.top,l.listFooter,function()M.detail(a,row)end)
            clippedHit(v,x,y+by,w/2,h-by,page.top,l.listFooter,function()M.like(a,row)end)
            clippedHit(v,x+w/2,y+by,w/2,h-by,page.top,l.listFooter,function()M.detail(a,row)end)
        end
    end
    viewport:free()
    local nextPage=pages[r.page+1]
    if nextPage then for _,item in ipairs(nextPage.items)do
        local y=nextPage.top+item.y-nextPage.offset+s(14)
        if item.row and y<l.listFooter and y+s(28)>nextPage.top then require('readinknative/avatarpaint').reserve(v,item.row.author,s(28))end
    end end
    if r.error and #r.groups>0 then
        bb:paintRect(l.side,l.listFooter-s(24),l.w-2*l.side,s(24),BB.COLOR_WHITE)
        v:text(bb,r.error=='SOCIAL_LIKE_UNCERTAIN'and'点赞结果待核对，点想法刷新'or'加载失败，再按向下可重试',l.side,l.listFooter-s(20),l.w-2*l.side,s(11))
    end
    if r.mineError and not r.error then
        bb:paintRect(l.side,l.listFooter-s(24),l.w-2*l.side,s(24),BB.COLOR_WHITE)
        v:text(bb,'自己的想法未能刷新，点此重试',l.side,l.listFooter-s(20),l.w-2*l.side,s(11))
        v:hit({x=l.side,y=l.listFooter-s(28),w=l.w-2*l.side,h=s(28)},function()M.fetchMine(a,true)end)
    end
    footer(v,bb,r.page,#pages)
    if r.singleRange then
        local half=math.min(s(64),math.floor((l.w*0.4-s(16))/2));local cell=(l.w-s(16)-2*half)/3
        local x=cell;local w=math.min(s(146),2*cell-s(6));local y=l.listFooter+s(7)
        bb:paintBorder(x,y,w,l.bottom-s(14),s(1),BB.COLOR_BLACK,math.floor((l.bottom-s(14))/2))
        local label=require('ui/widget/textwidget'):new{text='写想法',face=require('ui/font'):getFace('cfont',17),bold=true}
        v.objects[#v.objects+1]=label;local z=label:getSize();local iw,gap=s(28),s(4);local left=x+(w-iw-gap-z.w)/2
        v:icon(bb,'icon_newidea',left,y,iw,l.bottom-s(14),nil,nil,{w=28,h=28})
        label:paintTo(bb,math.floor(left+iw+gap),math.floor(y+(l.bottom-s(14)-z.h)/2))
        v:hit({x=x,y=y,w=w,h=l.bottom-s(14)},function()require('readinknative/thoughtpublish').compose(a)end)
    end
end
function V.detail(v,bb,r)
    local a,l=v.app,v.layout;local s=l.s;local row=r.data and r.data.review or r.row
    if r.expandedComment then
        local value=r.expandedComment
        v:text(bb,value.author.name,l.side,s(24),l.w-2*l.side,s(19),true)
        local text=(value.replyUser and('回复 '..value.replyUser.name..'：')or'')..value.content
        r.page,r.commentTextPages=v:pageText(bb,text,l.side,s(76),l.w-2*l.side,l.listFooter-s(100),s(17),r.page)
        footer(v,bb,r.page,r.commentTextPages,row);return
    end
    local layout=require('readinknative/sociallayout').detail(a,r);r.textPages=layout.pages;r.page=math.max(1,math.min(layout.pages,r.page));local offset=(r.page-1)*layout.viewport
    for _,block in ipairs(layout.blocks)do
        local y=block.y-offset;local h=block.height
        if y<l.listFooter and y+h>0 then
            if block.kind=='text'then flowText(v,bb,block.text,l.side,y,l.w-2*l.side,block.textHeight,block.size,0,l.listFooter)
            elseif block.kind=='comment'then
                local value=block.value
                local scratch=BB.new(l.w,s(48),BB.TYPE_BB8);scratch:fill(BB.COLOR_WHITE)
                avatar(v,scratch,value.author,l.side,s(6),s(28),y+s(6),0,l.listFooter-(r.error and s(22)or 0))
                v:text(scratch,value.author.name,l.side+s(42),s(5),l.w-2*l.side-s(130),s(15),true)
                if value.created then v:text(scratch,os.date('%Y/%m/%d %H:%M',value.created),l.side+s(42),s(27),l.w-2*l.side-s(42),s(12),false,1,nil,BB.COLOR_DARK_GRAY)end
                v:icon(scratch,value.liked and'icon_review_like_selected'or'icon_review_like',l.w-l.side-s(22),s(5),s(20),s(20))
                v:text(scratch,counter(value.likesCount),l.w-l.side-s(65),s(8),s(38),s(13))
                local t,b=math.max(y,0),math.min(y+s(48),l.listFooter);if b>t then bb:blitFrom(scratch,0,t,0,t-y,l.w,b-t)end;scratch:free()
                flowText(v,bb,block.text,l.side+s(42),y+s(48),l.w-2*l.side-s(42),block.textHeight,s(17),0,l.listFooter)
                clippedHit(v,l.side,y,l.w-2*l.side,h,0,l.listFooter,function()M.openComment(a,value)end)
            else
                local scratch=BB.new(l.w,h,BB.TYPE_BB8);scratch:fill(BB.COLOR_WHITE)
                if block.kind=='author'then avatar(v,scratch,row.author,l.side,s(14),s(36),y+s(14),0,l.listFooter-(r.error and s(22)or 0));v:text(scratch,row.author.name,l.side+s(54),s(22),l.w-2*l.side-s(54),s(22),true)
                elseif block.kind=='rule'then rule(v,scratch,s(4))
                elseif block.kind=='divider'then scratch:paintRect(0,0,l.w,h,BB.COLOR_LIGHT_GRAY)
                elseif block.kind=='book'then
                    local cover={x=l.side,y=s(8),w=s(38),h=s(55)};v:cover(scratch,a.book,cover)
                    v:text(scratch,a.book.title,l.side+s(54),s(10),l.w-2*l.side-s(54),s(19),true,1)
                    v:text(scratch,a.book.author or'',l.side+s(54),s(40),l.w-2*l.side-s(54),s(14),false,1)
                elseif block.kind=='tabs'then
                    local labels={'评论 '..counter(row.commentsCount),'赞 '..counter(row.likesCount)}
                    for i,label in ipairs(labels)do local x=l.side+(i-1)*s(108);v:text(scratch,label,x,s(18),s(104),s(19),(i==1 and r.tab~='likes'or i==2 and r.tab=='likes'))
                        if i==1 and r.tab~='likes'or i==2 and r.tab=='likes'then scratch:paintRect(x,h-s(3),s(84),s(2),BB.COLOR_BLACK)end
                        local tab=i==1 and'comments'or'likes';clippedHit(v,x,y,s(104),h,0,l.listFooter,function()M.selectTab(a,tab)end)
                    end
                    rule(v,scratch,h-s(1))
                elseif block.kind=='user'then avatar(v,scratch,block.value,l.side,s(12),s(32),y+s(12),0,l.listFooter-(r.error and s(22)or 0));v:text(scratch,block.value.name,l.side+s(46),s(20),l.w-2*l.side-s(46),s(17),true)end
                local t,b=math.max(y,0),math.min(y+h,l.listFooter);if b>t then bb:blitFrom(scratch,0,t,0,t-y,l.w,b-t)end;scratch:free()
            end
        end
    end
    if r.error or not r.data then v:icon(bb,'icon_general_reload',l.w-l.side-s(32),s(8),s(32),s(32),function()M.fetchDetail(a)end)end
    if r.error then bb:paintRect(l.side,l.listFooter-s(22),l.w-2*l.side,s(22),BB.COLOR_WHITE);v:text(bb,'加载未完成，可重试',l.side,l.listFooter-s(20),l.w-2*l.side,s(11))end
    footer(v,bb,r.page,layout.pages,row)
end
function V.bookmark(v,bb,r)
    local a,l=v.app,v.layout;local s=l.s
    v:text(bb,r.row.kind=='highlight'and'云端划线'or'云端书签',l.side,s(20),l.w-2*l.side,s(22),true)
    v:text(bb,r.row.chapterTitle,l.side,s(64),l.w-2*l.side,s(17),true)
    r.page,r.textPages=v:pageText(bb,r.row.quote or'',l.side,s(112),l.w-2*l.side,l.listFooter-s(144),s(18),r.page)
    footer(v,bb,r.page,r.textPages)
end
function V.bookList(v,bb,r)
    local a,l=v.app,v.layout;local s=l.s;local capacity=M.bookListCapacity(a);local pages=math.max(1,math.ceil(#r.rows/capacity))
    r.page=math.max(1,math.min(pages,r.page));v:text(bb,r.kind=='hot'and(r.data and r.data.relatedTitle and'关联版本热门划线'or'热门划线')or'书评',l.side,s(20),l.w-2*l.side,s(24),true)
    local total=r.data and r.data.total
    v:text(bb,a.book.title..(total and(' · '..total..'条')or''),l.side,s(62),l.w-2*l.side,s(14))
    for i=1,capacity do
        local row=r.rows[(r.page-1)*capacity+i]
        if row then
            local y=s(110)+(i-1)*s(176)
            v:text(bb,r.kind=='hot'and row.chapter.title or row.author.name,l.side,y,l.w-2*l.side,s(17),true)
            v:text(bb,r.kind=='hot'and row.quote or row.content,l.side,y+s(36),l.w-2*l.side,s(17),false,3)
            if r.kind=='hot'and row.count then v:text(bb,row.count..'人划线',l.side,y+s(132),l.w-2*l.side,s(12))end
            rule(v,bb,y+s(166));v:hit({x=l.side,y=y,w=l.w-2*l.side,h=s(168)},function()
                if r.kind=='hot'then M.openHot(a,row)else M.detail(a,row)end
            end)
        end
    end
    if not r.loaded or r.error then
        v:text(bb,r.error and'读取失败，点此重试'or'正在读取',l.side,s(100),l.w-2*l.side,s(17))
        v:hit({x=l.side,y=s(90),w=l.w-2*l.side,h=s(70)},function()M.fetchBookList(a)end)
    elseif #r.rows==0 then v:text(bb,r.kind=='hot'and'暂无热门划线'or'暂无书评',l.side,s(120),l.w-2*l.side,s(17))end
    if r.loaded and total and #r.rows<total and not(r.data.more and r.data.maxIdx)then
        v:text(bb,'当前已加载 '..#r.rows..' 条',l.side,l.listFooter-s(24),l.w-2*l.side,s(11))
    end
    footer(v,bb,r.page,pages)
end
V.hot=V.bookList;V.reviews=V.bookList
function V.draw(v,bb)
    local c=v.app.social;local r=c and c.route
    if not r or not M.valid(v.app,c,r)or type(V[r.kind])~='function'or r.kind=='draw'then v:text(bb,'内容已变化，请返回重新打开',v.layout.side,v.layout.s(80),v.layout.w-2*v.layout.side,v.layout.s(18));footer(v,bb,1,1);return end
    V[r.kind](v,bb,r)
end
return V
