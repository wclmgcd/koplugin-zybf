-- Design tokens traced in reports/official-ui-evidence.md. dp are adapted to
-- KOReader's screen scale, not claimed to be pixel-identical Android layouts.
local L={coverRatio=0.6948052048683167,tokens={side=20,top=48,search=56,gap=28,titleGap=9,chapter=56,bottom=56}}
local function rect(x,y,w,h)return{x=math.floor(x),y=math.floor(y),w=math.floor(w),h=math.floor(h)}end
function L.build(w,h,scale,density)
    local function s(n)return math.max(1,math.floor(n*(scale or 1)+0.5))end
    local side=s(20);local top=s(48);local bottom=s(56);local search=s(56)
    local columns=({large=3,standard=4,compact=5})[density]or 4
    local gap=s(columns==3 and 28 or columns==4 and 20 or 16)
    local cell=math.floor((w-2*side-gap*(columns-1))/columns)
    local shelfY=search+s(72)
    local titleSize=s(columns==5 and 13 or 14);local titleGap=s(9)
    local titleBand=titleGap+math.ceil(titleSize*1.55)+s(4);local rowGap=s(16)
    -- Covers fill the chosen column width. Do not shrink every row to fit a
    -- whole number of rows: clipped bottom covers continue on the next page.
    local nextTop=search+s(16)
    local maxCover=math.max(1,h-bottom-nextTop-s(50)-titleBand)
    local cover=math.min(math.floor(cell/L.coverRatio),maxCover)
    local coverWidth=math.min(cell,math.floor(cover*L.coverRatio+0.5))
    if columns==4 then
        cover=math.max(1,math.floor(cover*0.95+0.5))
        coverWidth=math.max(1,math.floor(coverWidth*0.95+0.5))
    end
    local stride=cover+titleBand+rowGap
    local grid={firstTop=shelfY,nextTop=nextTop,cell=cell,gap=gap,coverHeight=cover,coverWidth=coverWidth,
        titleGap=titleGap,titleBand=titleBand,rowHeight=cover+titleBand,stride=stride}
    local listTop=s(140);local notesTop=s(254)
    local layout={w=w,h=h,s=s,side=side,top=top,bottom=bottom,search=search,shelfGrid=grid,shelfColumns=columns,shelfTitleSize=titleSize,
        listHeader=s(56),listTop=listTop,listFooter=h-bottom,
        catalogRows=math.max(1,math.floor((h-bottom-listTop)/s(56))),
        notesTop=notesTop,noteRows=math.max(1,math.floor((h-bottom-notesTop)/s(152))),
        searchRows=math.max(1,math.floor((h-bottom-listTop)/s(88))),
        settingsRows=math.max(1,math.floor((h-bottom-s(56))/s(72))),
        body=rect(0,s(32),w,h-s(64)),footer=rect(0,h-bottom,w,bottom)}
    layout.cells=require('readinknative/shelfpaging').page(layout,100000,1).cells
    layout.shelfRows=#layout.cells/columns
    return layout
end
function L.contains(rect,x,y)return x>=rect.x and y>=rect.y and x<rect.x+rect.w and y<rect.y+rect.h end
return L
