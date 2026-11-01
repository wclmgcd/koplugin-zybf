-- Remove only terminal Calibre spacer blocks, never spacing within the text.
-- Keep any IDs as zero-height anchors so saved links still have a target.
local S={}
function S.trim(html)
    local start,opening=html:find('<[bB][oO][dD][yY]%f[%s>][^>]*>')
    local closing=html:find('</[bB][oO][dD][yY]%s*>',opening or 1)
    if not start or not closing then return html,0 end
    local body=html:sub(opening+1,closing-1);local anchors={};local count=0;local changed=false
    while true do
        local prefix,tag=body:match('^(.-)(<[dD][iI][vV]%f[%s/>][^<>]*/>)%s*$')
        if not tag or not tag:match('class%s*=%s*["\']mbp_pagebreak["\']')then
            prefix,tag=body:match('^(.-)(<[pP]%f[%s>][^<>]*>[^<>]*</[pP]>)%s*$')
            if not tag then break end
            local attrs,text=tag:match('^<[pP]([^>]*)>(.-)</[pP]>$')
            local empty=text:gsub('&nbsp;',''):gsub('&#160;',''):gsub('&#[xX]0*[aA]0;',''):gsub('\194\160',''):gsub('%s','')==''
            if not empty or not attrs:match('height%s*:%s*1em')or attrs:lower():find('background',1,true)then break end
            count=count+1
        end
        local id=tag:match('%s(id%s*=%s*["\'][^"\']*["\'])')
        if id then table.insert(anchors,1,'<span '..id..'></span>')end
        body=prefix;changed=true
    end
    if not changed then return html,0 end
    return html:sub(1,opening)..body..table.concat(anchors)..html:sub(closing),count
end
return S
