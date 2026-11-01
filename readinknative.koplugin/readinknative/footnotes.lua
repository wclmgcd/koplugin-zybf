-- Restore explicit local note links without treating arbitrary pictures as notes.
local F={MAX_NOTE=65536,knownImages={['25dfb82dd9c31060e81b4a1b6e1e579ce5d3f145d288a1b59efb65144689ac54']=true}}
local function attribute(tag,key)
    for k,q,v in tag:gmatch('([%w:_%-]+)%s*=%s*([\'"])(.-)%2')do if k:lower()==key then return require('util').htmlEntitiesToUtf8(v)end end
end
local function encode(text)return(text:gsub('[^%w%-_%.~]',function(c)return string.format('%%%02X',c:byte())end))end
local function anchor(tag,note)
    if type(note)~='string'or #note>F.MAX_NOTE or not note:find('%S')then return tag end
    return'<a href="footnote://'..encode(note)..'">'..tag..'</a>'
end
local function resolve(source,ref)
    if not ref or ref:match('^%a[%w+.-]*:')or ref:sub(1,1)=='/'then return end
    ref=ref:gsub('[?#].*$',''):gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
    local parts={};for part in((source:match('^(.*)/')or'')..'/'..ref):gmatch('[^/]+')do
        if part=='..'then if #parts==0 then return end;table.remove(parts)elseif part~='.'then parts[#parts+1]=part end
    end
    return table.concat(parts,'/')
end
function F.rewrite(html,source,files)
    local changed=0
    -- Official EPubIndexer serializes qqreader-footnote's alt as a note target.
    local depth=0
    html=html:gsub('<[^>]+>',function(tag)
        if tag:match('^</[aA]%s*>')then depth=math.max(0,depth-1);return tag end
        if tag:match('^<[aA]%f[%s>]')then depth=depth+1;return tag end
        if depth>0 or not tag:match('^<[iI][mM][gG]%f[%s/>]')then return tag end
        local class=attribute(tag,'class')or'';local alt=attribute(tag,'alt')
        if(' '..class..' '):find(' qqreader%-footnote ')and alt and #alt<=F.MAX_NOTE then changed=changed+1;return anchor(tag,alt)end
        return tag
    end)
    -- An unanchored .* prefix retries the entire chapter at every byte when
    -- there is no <hr>. Most books have none: that made opening quadratic.
    local lower=html:lower();local hr
    for at in lower:gmatch('()<hr%f[%s/>]')do hr=at end
    if not hr then return html,changed end
    local tail=html:sub(hr);local list=tail:match('<[oO][lL]%f[%s>][^>]*>(.-)</[oO][lL]%s*>')
    if not list then return html,changed end
    local notes={};for note in list:gmatch('<[lL][iI]%f[%s>][^>]*>(.-)</[lL][iI]%s*>')do
        if #note>F.MAX_NOTE then return html,changed end;notes[#notes+1]=note
    end
    if #notes==0 then return html,changed end
    local function marker(body)
        if body:lower():find('<a%f[%s>]')then return false end
        local tag=body:match('<[iI][mM][gG]%f[%s/>][^>]*>');if not tag then return false end
        local _,count=body:gsub('<[iI][mM][gG]%f[%s/>]','');if count~=1 then return false end
        local path=resolve(source,attribute(tag,'src'));local data=path and files[path]
        return data and F.knownImages[require('ffi/sha2').sha256(data)]==true
    end
    local head=html:sub(1,hr-1);local count=0
    for body in head:gmatch('<[sS][uU][pP]%f[%s>][^>]*>(.-)</[sS][uU][pP]%s*>')do if marker(body)then count=count+1 end end
    -- No guessed ordinal when lists and recognized icon references disagree.
    if count~=#notes then return html,changed end
    local index=0
    head=head:gsub('(<[sS][uU][pP]%f[%s>][^>]*>)(.-)(</[sS][uU][pP]%s*>)',function(open,body,close)
        if not marker(body)then return open..body..close end
        index=index+1;return open..anchor(body,notes[index])..close
    end)
    return head..html:sub(hr),changed+index
end
return F
