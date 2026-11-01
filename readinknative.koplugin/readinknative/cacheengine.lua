-- CRe keeps DOM files outside account roots. Match only stems derived from
-- recognized MP filenames; never follow cachePath from a JSON sidecar.
local M={}
function M.stem(leaf)
    local hash,mode=leaf:match('^([a-f0-9]+)%-([a-z]+)%.epub$')
    if not hash or #hash~=64 or(mode~='full'and mode~='preview')then return end
    return #leaf>25 and(leaf:sub(1,12)..'-'..leaf:sub(-12))or leaf
end
local function leaf(name)name=require('readinknative/cachefiles').basename(name)or name;return name:match('^([a-f0-9]+%-[a-z]+%.epub)')end
function M.append(entries,vid)
    local lfs=require('libs/libkoreader-lfs');local data=require('datastorage'):getDataDir()
    local directory=data..'/cache/cr3cache'
    if lfs.symlinkattributes(directory,'mode')~='directory'then return end
    local pool={}
    for _,e in ipairs(entries)do if e.category=='mp'then
        local name=leaf(e.name);local stem=name and M.stem(name)
        if stem then
            if pool[stem]and pool[stem]~=name then pool[stem]=false
            elseif pool[stem]==nil then pool[stem]=name end
        end
    end end
    if next(pool)==nil then return end
    -- The engine's global key can be shared for identical source filenames and
    -- bytes. Preserve any stem also owned by another account, including mirrors.
    local root=require('readinknative/paths').account(vid);local parent=root:match('^(.*)/[^/]+$');local foreign={}
    local function protect(name)local source=leaf(name);local stem=source and M.stem(source);if stem and pool[stem]then foreign[stem]=true end end
    local seen={}
    for account in lfs.dir(parent)do
        local id=account:match('^([a-f0-9]+)%-cache%-v2$')or account
        local folder=parent..'/'..id
        if #id==24 and id:match('^[a-f0-9]+$')and folder~=root and not seen[id]then
            seen[id]=true
            require('readinknative/cachefiles').walk(folder,nil,function(name)protect(name)end)
        end
    end
    local inUse={}
    for _,e in pairs(require('document/documentregistry').registry)do
        if e.doc and e.doc.provider=='crengine'and e.doc.getCacheFilePath then
            local ok,path=pcall(e.doc.getCacheFilePath,e.doc)
            if ok and type(path)=='string'then inUse[path:match('([^/]+)$')or'']=true end
        end
    end
    for name in lfs.dir(directory)do
        local stem,crc,flags=name:match('^(.-)%.([a-f0-9]+)%.(%d+)%.cr3$')
        local source=stem and pool[stem]
        if source and #crc==8 and not foreign[stem]then
            local path=directory..'/'..name;local attrs=lfs.symlinkattributes(path)
            if attrs and attrs.mode=='file'then
                entries[#entries+1]={name=source..'.engine/'..name,path=path,size=attrs.size or 0,kind='engine',category='mp',protected=inUse[name]or nil}
            end
        end
    end
end
return M
