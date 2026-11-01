-- Official 2.1.2 BottomBarWithPager: icons at left, one prev/next capsule at right.
local BB=require('ffi/blitbuffer');local B={}
function B.draw(v,bb,selected,options)
    options=options or{};local a,l=v.app,v.layout;local s=l.s;local y=l.h-l.bottom
    bb:paintRect(0,y,l.w,s(1),BB.COLOR_LIGHT_GRAY)
    local half=math.min(s(64),math.floor((l.w*0.4-s(16))/2))
    local left=options.left or 0;local cell=(l.w-left-s(16)-2*half)/(options.actions and math.max(3,#options.actions)or 3)
    if options.actions then
        for i,item in ipairs(options.actions)do
            local x=left+(i-1)*cell
            v:icon(bb,item.icon,x,y,cell,l.bottom,item.action,nil,item.metrics or{w=28,h=28})
        end
    elseif options.back then
        v:icon(bb,'icon_toolbar_back',left,y,cell,l.bottom,options.back,nil,{w=28,h=28})
    else
        local tabs={{'store','icon_tab_bar_find','icon_tab_bar_find_selected',function()require('readinknative/store').enter(a)end},
            {'shelf','bookshelf','bookshelf_active',function()a:home()end},
            {'account','me','me_active',function()a:account()end}}
        for i,t in ipairs(tabs)do v:icon(bb,selected==t[1]and t[3]or t[2],left+(i-1)*cell,y,cell,l.bottom,t[4],nil,{w=28,h=28})end
    end
    local page,pages=options.page or 1,options.pages or 1
    local prev=page>1;local next=page<pages or options.more==true
    local x=l.w-s(8)-half*2
    v:icon(bb,prev and'icon_page_up'or'icon_page_up_disabled',x,y,half,l.bottom,nil,nil,{pixel_w=half,h=40})
    v:icon(bb,next and'icon_page_down'or'icon_page_down_disabled',x+half,y,half,l.bottom,nil,nil,{pixel_w=half,h=40})
    local turn=options.turn or function(delta)a:turn(delta)end
    v:hit({x=x,y=y,w=half,h=l.bottom},function()if prev then turn(-1)end end)
    v:hit({x=x+half,y=y,w=half,h=l.bottom},function()if next then turn(1)end end)
end
return B
