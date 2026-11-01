-- Row-aligned shelf windows follow the first incomplete item, including its
-- bottom spacing. Search and bottom navigation stay fixed.
local P={}
local function metrics(l,options)
    options=options or{}
    local g=l.shelfGrid;local bottom=l.h-l.bottom
    local nextTop=options.editing and g.firstTop or g.nextTop
    local summary=options.counts==false and 0 or l.s(50)
    local function capacity(top)
        return math.max(0,math.floor((bottom-top-summary-g.rowHeight)/g.stride)+1)
    end
    local function step(top)
        return math.max(1,math.floor((bottom-top)/g.stride))
    end
    return g,bottom,nextTop,capacity(g.firstTop),capacity(nextTop),step(g.firstTop),step(nextTop)
end
function P.page(l,total,requested,options)
    total=math.max(0,math.floor(total or 0))
    local g,bottom,nextTop,firstCapacity,nextCapacity,firstStep,nextStep=metrics(l,options)
    local rows=math.ceil(total/l.shelfColumns);local pages=1
    if rows>firstCapacity then
        pages=math.max(2,2+math.ceil((rows-nextCapacity-firstStep)/nextStep))
    end
    local page=math.max(1,math.min(pages,math.floor(requested or 1)))
    local row=page==1 and 1 or math.min(rows,1+firstStep+(page-2)*nextStep)
    local top=page==1 and g.firstTop or nextTop
    local first=(row-1)*l.shelfColumns+1;local cells={}
    local visibleRows=math.max(1,math.ceil((bottom-top)/g.stride))
    for r=0,visibleRows-1 do for c=0,l.shelfColumns-1 do
        local index=first+r*l.shelfColumns+c
        if index<=total then
            local x=l.side+c*(g.cell+g.gap);local y=top+r*g.stride
            local cx=x+math.floor((g.cell-g.coverWidth)/2)
            local titleY=y+g.coverHeight+g.titleGap
            cells[#cells+1]={index=index,cover={x=cx,y=y,w=g.coverWidth,h=g.coverHeight},
                title={x=cx,y=titleY,w=g.coverWidth,h=g.titleBand-g.titleGap},
                titleVisible=titleY+g.titleBand-g.titleGap<=bottom,
                hit={x=x,y=y,w=g.cell,h=math.min(g.rowHeight,bottom-y)}}
        end
    end end
    return {page=page,pages=pages,first=first,firstRow=row,cells=cells,top=top,bottom=bottom,
        showHeader=page==1 or options and options.editing==true,last=page==pages}
end
function P.forIndex(l,total,index,options)
    index=math.max(1,math.min(math.max(1,total),index or 1))
    local row=math.floor((index-1)/l.shelfColumns)+1
    local _,_,_,_,_,firstStep,nextStep=metrics(l,options)
    local page=row<=firstStep and 1 or 2+math.floor((row-1-firstStep)/nextStep)
    return P.page(l,total,page,options).page
end
return P
