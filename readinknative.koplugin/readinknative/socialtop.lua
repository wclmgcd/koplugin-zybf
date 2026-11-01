-- ReaderTopBookmarkView: two counts, then the single show/hide action.
local T={}
function T.paint(v,bb)
    local a,l=v.app,v.layout;local s=l.s;local M=require('readinknative/social');local c=M.context(a)
    local related=require('readinknative/relatededitions').isCB(a.book);local BB=require('ffi/blitbuffer');local w=math.min(l.w-s(24),s(300));local h=s(210)
    local x=l.w-s(12)-w;local y=l.top+s(18)
    v:hit({x=0,y=l.top,w=l.w,h=l.h-l.top-l.bottom},function(x)v:readerTap(x)end)
    bb:paintRect(x,y,w,h,BB.COLOR_WHITE);bb:paintBorder(x,y,w,h,s(1),BB.COLOR_BLACK,s(16))
    local arrow=math.max(x+s(16),math.min(x+w-s(32),l.w-s(242)))
    v:icon(bb,'icon_general_bubble_arrow',arrow,y-s(10),s(20),s(12),nil,nil,{w=16,h=10,rotation=180})
    v:hit({x=x,y=y,w=w,h=h},function()end)
    local half=w/2
    v:text(bb,'书评',x+s(14),y+s(24),half-s(28),s(18),true,1,nil,nil,nil,'center')
    v:text(bb,c.hotRelated and '关联版热门划线'or'热门划线',x+half+s(10),y+s(24),half-s(20),s(18),true,1,nil,nil,nil,'center')
    bb:paintRect(x+half,y+s(24),s(1),s(70),BB.COLOR_LIGHT_GRAY)
    for i,key in ipairs{'reviews','hot'}do
        local count;if key=='reviews'then count=c.reviewsTotal else count=c.hotTotal end
        v:text(bb,count and tostring(count)..'条 ›'or'查看 ›',x+(i-1)*half+s(10),y+s(62),half-s(20),s(23),true,1,nil,nil,nil,'center')
        v:hit({x=x+(i-1)*half,y=y+s(8),w=half,h=s(110)},function()M.openBookList(a,key)end)
    end
    local bx,by,bw,bh=x+s(20),y+s(140),w-s(40),s(50)
    bb:paintBorder(bx,by,bw,bh,s(1),BB.COLOR_LIGHT_GRAY,s(14))
    v:button(bb,require('readinknative/socialreader').hidden(a)and'显示书友想法'or'隐藏书友想法',bx,by,bw,bh,function()require('readinknative/socialreader').toggle(a)end)

end
return T
