local BB=require('ffi/blitbuffer');local S=require('readinknative/articles');local V={}
local function publisher(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local c=a.articles;local r=c.routes[c.kind]
    local left=math.floor(l.w/3);local side=s(24);local width=l.w-left-2*side
    if a.document then a.document:paint(bb,l.body.x,l.body.y);bb:lightenRect(0,0,left,l.h)end
    bb:paintRect(left,0,l.w-left,l.h,BB.COLOR_WHITE);bb:paintRect(left,0,s(1),l.h,BB.COLOR_LIGHT_GRAY)
    v:text(bb,c.publisher.title,left+side,s(22),width,s(24),true,1)
    bb:paintRect(left+side,s(76),width,s(1),BB.COLOR_LIGHT_GRAY)
    v:hit({x=left+side,y=0,w=width,h=s(76)},function()S.retry(a)end)
    local cap=S.capacity(a);local rows=r.data and r.data.rows or{};local pages=math.max(1,math.ceil(#rows/cap));r.page=math.max(1,math.min(pages,r.page or 1))
    for slot=1,cap do
        local row=rows[(r.page-1)*cap+slot];if not row then break end
        local y=s(88)+(slot-1)*s(112);local image=s(70);local x=l.w-side-image
        local selected=a.book and a.book.articleReviewId==row.reviewId
        v:text(bb,row.title,left+side,y+s(16),width-image-s(18),s(19),true,2,selected and BB.COLOR_BLACK or BB.COLOR_WHITE,selected and BB.COLOR_WHITE or BB.COLOR_BLACK)
        v:cover(bb,{cover=row.cover,coverSquare=true},{x=x,y=y+s(16),w=image,h=image})
        bb:paintRect(left+side,y+s(111),width,s(1),BB.COLOR_LIGHT_GRAY)
        v:hit({x=left+side,y=y,w=width,h=s(111)},function()S.open(a,row)end)
    end
    if r.loading or r.error then v:text(bb,r.loading or require('readinknative/errors').message(r.error),left+side,l.h-l.bottom-s(28),width,s(11),false,1)end
    if #rows==0 and not r.loading then
        v:text(bb,r.error and require('readinknative/errors').message(r.error)or'暂无可读文章',left+side,s(150),width,s(17),false,5)
        if r.error then v:button(bb,'重试',left+side,s(310),s(90),s(42),function()S.retry(a)end)end
    end
    v:hit({x=0,y=0,w=left,h=l.h},function()S.back(a)end)
    require('readinknative/homebar').draw(v,bb,nil,{left=left,back=function()S.back(a)end,page=r.page,pages=pages,more=r.data and r.data.more,turn=function(d)S.turn(a,d)end})
end
function V.draw(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local c=a.articles;if not c then return end
    local r=c.routes[c.kind];if not r then return end
    if c.publisher then publisher(v,bb);return end
    -- Official MpTabView: one outlined capsule, black active half, no extra
    -- title bar or invented category/toolbar controls.
    local top=s(20);local height=s(48);local width=(l.w-2*l.side)/2
    bb:paintBorder(l.side,top,2*width,height,s(1),BB.COLOR_BLACK,s(24))
    for i,label in ipairs{'文章收藏','微信浮窗文章'}do
        local x=l.side+(i-1)*width;local active=c.kind==i-1
        if active then bb:paintRoundedRect(x+s(3),top+s(3),width-s(6),height-s(6),BB.COLOR_BLACK,s(21))end
        v:text(bb,label,x+s(16),top+s(12),width-s(32),s(18),true,1,active and BB.COLOR_BLACK or BB.COLOR_WHITE,active and BB.COLOR_WHITE or BB.COLOR_DARK_GRAY,nil,'center')
        v:hit({x=x,y=top,w=width,h=height},function()if active then S.retry(a)else S.tab(a,i-1)end end)
    end
    local rows=r.data and r.data.rows or{};local cap=S.capacity(a);local pages=math.max(1,math.ceil(#rows/cap))
    r.page=math.max(1,math.min(pages,r.page or 1))
    for slot=1,cap do
        local row=rows[(r.page-1)*cap+slot];if not row then break end
        local y=s(88)+(slot-1)*s(112);local image=s(76);local x=l.w-l.side-image;local tw=x-l.side-s(18)
        v:text(bb,row.title,l.side,y+s(12),tw,s(18),true,2)
        v:text(bb,row.account..(row.fromWechat and c.kind==0 and' · 微信收藏'or''),l.side,y+s(78),tw,s(12),false,1,nil,BB.COLOR_DARK_GRAY)
        v:cover(bb,{cover=row.cover,coverSquare=true},{x=x,y=y+s(14),w=image,h=image})
        bb:paintRect(l.side,y+s(111),l.w-2*l.side,s(1),BB.COLOR_LIGHT_GRAY)
        v:hit({x=l.side,y=y,w=l.w-2*l.side,h=s(111)},function()S.open(a,row)end)
    end
    if #rows==0 then
        local message=r.loading or(r.error and require('readinknative/errors').message(r.error))or(c.kind==0 and'暂无文章收藏'or'暂无微信浮窗文章')
        v:text(bb,message,l.side,s(166),l.w-2*l.side,s(18),false,5)
        if r.error then v:button(bb,'重试',l.side,s(316),s(100),s(44),function()S.retry(a)end)end
    elseif r.loading or r.error then
        -- Reserve one footer-adjacent line rather than covering article rows.
        v:text(bb,r.loading or require('readinknative/errors').message(r.error),l.side,l.h-l.bottom-s(22),l.w-2*l.side,s(11),false,1,BB.COLOR_WHITE)
    end
    require('readinknative/homebar').draw(v,bb,nil,{back=function()S.back(a)end,page=r.page,pages=pages,more=r.data and r.data.more,turn=function(d)S.turn(a,d)end})
end
return V
