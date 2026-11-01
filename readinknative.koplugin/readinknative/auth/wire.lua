-- ReadInk utility implementation. No dependency on WeReader modules.
local W={}
function W.bytes(count)
    assert(type(count)=='number' and count>=1 and count%1==0 and count<=4096,'RANDOM_SIZE_INVALID')
    local source=assert(io.open('/dev/urandom','rb'),'RANDOM_FAILED')
    local data=source:read(count);source:close()
    assert(data and #data==count,'RANDOM_FAILED')
    return data
end
function W.hex(count)
    return (W.bytes(count):gsub('.',function(ch)return string.format('%02x',ch:byte())end))
end
function W.random1000()
    -- Match SecureRandom.nextInt(1000)'s range without modulo bias.
    while true do
        local data=W.bytes(2)
        local value=data:byte(1)*256+data:byte(2)
        if value<65000 then return value%1000 end
    end
end
function W.escape(value)
    return (tostring(value):gsub('[^A-Za-z0-9_.~%-]',function(ch)return string.format('%%%02X',ch:byte())end))
end
function W.query(values)
    local fields={}
    for name,value in pairs(values or {})do
        assert(type(name)=='string' and (type(value)=='string' or type(value)=='number' or type(value)=='boolean'),'QUERY_INVALID')
        fields[#fields+1]=W.escape(name)..'='..W.escape(value)
    end
    table.sort(fields)
    return table.concat(fields,'&')
end
function W.url(base,query)
    local suffix=W.query(query)
    return suffix=='' and base or base..'?'..suffix
end
function W.nonempty(value)
    return type(value)=='string' and #value>0
end
return W
