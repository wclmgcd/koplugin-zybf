-- Passive article source parsing. No JavaScript is evaluated.
local M={}
function M.image(a)
    local had=false
    for _,key in ipairs({'data-src','data-original','data-backsrc','src'})do
        local src=a[key]
        if type(src)=='string'and src:find('%S')then
            had=true
            if not src:match('^data:')then return src end
        end
    end
    return nil,had and'unsupported'or'empty'
end
local function utf8(n)
    if n<128 then return string.char(n)end
    if n<2048 then return string.char(192+math.floor(n/64),128+n%64)end
    if n<65536 then assert(n<55296 or n>57343,'ARTICLE_HTML_INVALID');return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64)end
    assert(n<=1114111,'ARTICLE_HTML_INVALID');return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end
function M.embedded(raw,limit)
    local at=1
    while true do
        local _,b=raw:find('["\']?content_noencode["\']?%s*:%s*',at);if not b then return end
        local q=raw:sub(b+1,b+1);at=b+1
        if q=='"'or q=="'"then
            local out,size={},0;local i=b+2
            while i<=#raw do
                local c=raw:sub(i,i)
                if c==q then return table.concat(out)end
                if c=='\\'then
                    i=i+1;local esc=raw:sub(i,i);local replacements={n='\n',r='\r',t='\t',b='\b',f='\f'}
                    if esc=='x'or esc=='u'then
                        local count=esc=='x'and 2 or 4;local hex=raw:sub(i+1,i+count);assert(#hex==count and hex:match('^[%da-fA-F]+$'),'ARTICLE_HTML_INVALID')
                        local n=tonumber(hex,16);i=i+count
                        if n>=55296 and n<=56319 and raw:sub(i+1,i+2)=='\\u'then
                            local low=tonumber(raw:sub(i+3,i+6),16);assert(low and low>=56320 and low<=57343,'ARTICLE_HTML_INVALID');n=65536+(n-55296)*1024+low-56320;i=i+6
                        end
                        c=esc=='x'and string.char(n)or utf8(n)
                    elseif esc=='\n'or esc=='\r'then c='';if esc=='\r'and raw:sub(i+1,i+1)=='\n'then i=i+1 end
                    else c=replacements[esc]or esc end
                end
                size=size+#c;assert(size<=limit,'ARTICLE_TOO_LARGE');out[#out+1]=c;i=i+1
            end
            error('ARTICLE_HTML_INVALID')
        end
    end
end
return M
