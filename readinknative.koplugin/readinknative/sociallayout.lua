-- Shaped vertical content: pagination is a viewport into the official list flow,
-- rather than a fixed number of cards or an invented separate thought tab.
local L={}
function L.measure(a,text,size,width,maxLines)
    local Box=require('ui/widget/textboxwidget');local Font=require('ui/font')
    local box=Box:new{text=text,face=Font:getFace('cfont',size/a.view.fontScale),width=width,height=size*2}
    local line=box:getLineHeight();local lines=box:getAllLineCount();box:free()
    return math.max(1,math.min(lines,maxLines or lines))*line,line
end
function L.card(a,row)
    local l=a.view.layout;local width=l.w-2*l.side-l.s(32);local text=row.content~=''and row.content or'划线'
    local key=width..':'..l.s(17)..':'..a.view.fontScale..':'..text
    if row.cardLayout and row.cardLayout.key==key then return row.cardLayout end
    local height=L.measure(a,text,l.s(17),width)
    local c={key=key,body=height,height=l.s(94)+height};row.cardLayout=c;return c
end
function L.thoughts(a,r)
    local l=a.view.layout;local s=l.s;local top=s(12);local viewport=l.listFooter-top
    local quote=r.quote or(r.groups[1]and r.groups[1].quote)or'划线想法'
    -- Display provenance without changing the quote used for CB annotations.
    if r.foreign then quote='关联版本想法 · '..r.foreign.title..'\n\n'..quote end
    local width=l.w-2*l.side;local textWidth=width-s(104)
    local key=textWidth..':'..s(17)..':'..a.view.fontScale..':'..quote
    if not r.quoteLayout or r.quoteLayout.key~=key then
        local h=L.measure(a,quote,s(17),textWidth)
        r.quoteLayout={key=key,text=quote,body=h,height=math.max(s(86),h+s(30)),width=textWidth}
    end
    local all={{kind='quote',y=0,height=r.quoteLayout.height}};local offset=r.quoteLayout.height+s(12)
    for _,g in ipairs(r.groups)do
        for _,row in ipairs(g.rows)do local c=L.card(a,row);all[#all+1]={row=row,group=g,y=offset,height=c.height};offset=offset+c.height+s(12)end
    end
    if not r.loaded or #all==1 then
        all[#all+1]={kind='status',y=offset,height=s(100)};offset=offset+s(112)
    end
    offset=math.max(0,offset-s(12));local pages={};local count=math.max(1,math.ceil(offset/viewport))
    for i=1,count do
        local p={rows={},cards={},items={},offset=(i-1)*viewport,top=top,viewport=viewport,totalHeight=offset,group=r.groups[#r.groups]}
        for _,item in ipairs(all)do
            if item.y<p.offset+viewport and item.y+item.height>p.offset then
                p.items[#p.items+1]=item
                if item.row then p.cards[#p.cards+1]=item;p.rows[#p.rows+1]=item.row end
            end
        end
        p.last=i==count;pages[#pages+1]=p
    end
    return pages
end
function L.detail(a,r)
    local l=a.view.layout;local s=l.s;local row=r.data and r.data.review or r.row;local blocks={};local height=0
    local list=r.data and(r.tab=='likes'and r.data.likes or r.data.comments)or{}
    local signature={l.w,l.listFooter,a.view.fontScale,r.tab,row,row.content,row.quote,a.book.title,a.book.author or'',row.likesCount or-1,row.commentsCount or-1}
    for _,value in ipairs(list)do signature[#signature+1]=value;signature[#signature+1]=value.content or''end
    local equal=r.detailSignature and #r.detailSignature==#signature
    if equal then for i,value in ipairs(signature)do if r.detailSignature[i]~=value then equal=false;break end end end
    if equal then return r.detailFlow end
    local function add(kind,h,values)
        local b=values or{};b.kind=kind;b.y=height;b.height=h;blocks[#blocks+1]=b;height=height+h;return b
    end
    local function text(value,size,pad)
        local h,line=L.measure(a,value,s(size),l.w-2*l.side)
        return add('text',h+s(pad or 20),{text=value,size=s(size),line=line,textHeight=h})
    end
    add('author',s(64),{row=row})
    text(row.content~=''and row.content or'划线',20,24)
    if row.quote~=''then add('rule',s(18));text(row.quote,17,20)end
    add('book',s(78),{row=row})
    if row.created then text('发表于 '..os.date('%Y/%m/%d %H:%M',row.created),14,18)end
    add('divider',s(12))
    local tabs=add('tabs',s(58),{row=row});r.tabsY=tabs.y
    local data=r.data
    for _,value in ipairs(list)do
        if r.tab=='likes'then add('user',s(62),{value=value})
        else
            local content=(value.replyUser and('回复 '..value.replyUser.name..'：')or'')..value.content
            local h,line=L.measure(a,content,s(17),l.w-2*l.side-s(42))
            add('comment',s(58)+h,{value=value,text=content,textHeight=h,line=line})
        end
    end
    if #list==0 then text(data and(r.tab=='likes'and'暂无赞'or'暂无评论')or'正在读取',17,20)end
    local result={blocks=blocks,height=height,pages=math.max(1,math.ceil(height/l.listFooter)),viewport=l.listFooter}
    r.detailSignature=signature;r.detailFlow=result;return result
end
return L
