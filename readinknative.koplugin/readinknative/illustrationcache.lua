-- Account-local original image objects. Commit each complete response before
-- returning it to a chapter worker, so cancellation never loses earlier images.
local S={}
local extensions={'.jpg','.png','.webp','.gif'}
local function base(root,url)
    assert(require('readinknative/cachefiles').location(root..'/illustration-'..string.rep('0',64)..'.jpg')==root,'IMAGE_CACHE_ROOT_INVALID')
    assert(require('libs/libkoreader-lfs').symlinkattributes(root,'mode')=='directory','IMAGE_CACHE_ROOT_INVALID')
    return require('readinknative/cachepath').file(root,'illustration-'..require('ffi/sha2').sha256(require('readinknative/media').url(url)))
end
function S.find(root,url,limit)
    local stem=base(root,url);local lfs=require('libs/libkoreader-lfs')
    for _,ext in ipairs(extensions)do
        local path=require('readinknative/cachefiles').readPath(stem..ext);local a=path and lfs.symlinkattributes(path)
        if a and a.mode=='file'and a.size>8 and a.size<=limit then
            local f=require('readinknative/cachefiles').open(path,'rb');local head=f and f:read(32);if f then f:close()end
            if head and require('readinknative/media').kind(head)==ext then return{path=path,ext=ext,size=a.size}end
        end
    end
end
function S.read(value,limit)
    local root,name=require('readinknative/cachefiles').location(value.path)
    assert(root and require('readinknative/cache').classify(name)=='illustration','IMAGE_CACHE_PATH_INVALID')
    assert(require('libs/libkoreader-lfs').symlinkattributes(root,'mode')=='directory','IMAGE_CACHE_ROOT_INVALID')
    local a=require('libs/libkoreader-lfs').symlinkattributes(value.path)
    assert(a and a.mode=='file'and a.size==value.size and a.size<=limit,'IMAGE_CACHE_CHANGED')
    local f=assert(require('readinknative/cachefiles').open(value.path,'rb'),'IMAGE_CACHE_READ_FAILED');local data=f:read(limit+1);f:close()
    assert(data and #data==value.size and require('readinknative/media').kind(data)==value.ext,'IMAGE_CACHE_CHANGED')
    return data,value.ext
end
function S.fetch(root,url,limit,reader)
    local value=S.find(root,url,limit);if value then return value end
    local stem=base(root,url);local part=stem..'.jpg.part';local F=require('readinknative/cachefiles')
    local old=require('libs/libkoreader-lfs').symlinkattributes(part)
    assert(not old or old.mode=='file','IMAGE_CACHE_PATH_INVALID')
    local ok,result=pcall(function()
        -- The normal transport streams directly to this temporary file. Test
        -- readers and authenticated archive seeds may supply bytes instead.
        local data,ext,size=(reader or require('readinknative/media').read)(url,limit,{output=part})
        assert(ext=='.jpg'or ext=='.png'or ext=='.webp'or ext=='.gif','IMAGE_FORMAT_REJECTED')
        if type(data)=='string'then
            assert(#data<=limit and require('readinknative/media').kind(data)==ext,'IMAGE_FORMAT_REJECTED')
            local f=assert(F.open(part,'wb'),'IMAGE_CACHE_WRITE_FAILED');local wrote=f:write(data);local closed=f:close()
            assert(wrote and closed,'IMAGE_CACHE_WRITE_FAILED');size=#data
        else assert(data==true and type(size)=='number'and size>8 and size<=limit,'IMAGE_CACHE_WRITE_FAILED')end
        assert(F.rename(part,stem..ext),'IMAGE_CACHE_WRITE_FAILED')
        return{path=stem..ext,ext=ext,size=size}
    end)
    if not ok then
        F.remove(part)
        local code=tostring(result):match('([A-Z][A-Z_]+)$')
        require('logger').info('ReadInk illustration object failed:',code and #code<=64 and code or require('readinknative/errors').code(result))
        error(result,0)
    end
    return result
end
return S
