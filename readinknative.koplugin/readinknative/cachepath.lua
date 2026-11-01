-- Account-local cache v2 lives beside the legacy directory: a full legacy FAT
-- directory must not prevent creating new buckets. Settings/notes stay put.
local P={}
local function lfs()return require('libs/libkoreader-lfs')end
local function data()return require('datastorage'):getDataDir()..'/readink-native/'end
function P.root(root)
 local account=type(root)=='string'and root:match('/([a-f0-9]+)$')
 if account and #account==24 and root==data()..account then return root..'-cache-v2' end
end
local function hash(name)
 for h in name:gmatch('[a-f0-9]+')do if #h==64 then return h end end
 return require('ffi/sha2').sha256(name)
end
function P.file(root,name)
 assert(P.root(root)and type(name)=='string'and #name<=240 and name:match('^[A-Za-z0-9_.%-]+$')and not name:find('..',1,true),'CACHE_PATH_INVALID')
 return P.root(root)..'/data/'..hash(name):sub(1,2)..'/'..name
end
function P.meta(root,name)return assert(P.root(root))..'/meta/'..name end
function P.parse(path)
 if type(path)~='string'then return end
 local account,tail=path:match('^'..data():gsub('([^%w])','%%%1')..'([a-f0-9]+)(.*)$')
 if not account or #account~=24 then return end
 local root=data()..account
 if tail:sub(1,1)=='/'then return root,tail:sub(2),false end
 if tail:sub(1,10)=='-cache-v2/'then return root,tail:sub(11),true end
end
function P.plain(name)
 local bucket,leaf=name:match('^data/([a-f0-9][a-f0-9])/([^/]+)$')
 if bucket then
  local plain=leaf:gsub('^legacy%-','')
  if hash(plain):sub(1,2)==bucket then return plain end
  return
 end
 local b,source,file=name:match('^mirrors/([a-f0-9][a-f0-9])/([^/]+)/([^/]+)$')
 if b then if hash(source):sub(1,2)==b then return file,source end;return end
 if not name:find('/',1,true)then return name end
 local source,file=name:match('^([^/]+)/([^/]+)$');if source then return file,source end
end
local function body(leaf)
 local stem,suffix=leaf:match('^([a-f0-9]+%-[a-z]+%.epub)(.*)$')
 if stem and #stem:match('^([a-f0-9]+)')==64 then return stem,suffix end
end
local function exists(path)return lfs().symlinkattributes(path,'mode')=='file'end
-- Writes to an old body's sidecars go to a distinct legacy generation. New
-- bodies never inherit an old complete-image marker after a failed new write.
function P.write(path)
 local root,name,new=P.parse(path);if not root or new then return path end
 if name:find('/',1,true)then return path end
 local stem,suffix=body(name)
 if stem then
  if suffix==''and exists(path)then return path end -- replace existing legacy body only
  if suffix~=''and not suffix:match('^%.access%.json')then return P.file(root,'legacy-'..name)end
 end
 return P.file(root,name)
end
function P.candidates(path)
 local root,name,new=P.parse(path);if not root then return{path}end
 local leaf=new and name:match('^data/[a-f0-9][a-f0-9]/([^/]+)$')or(not name:find('/',1,true)and name)
 if not leaf then return{path}end
 local legacy=leaf:match('^legacy%-(.+)$')
 if new and legacy then return{path,root..'/'..legacy}end
 local stem,suffix=body(leaf)
 if not new and stem and suffix==''then return{path}end
 local target=new and path or P.write(path)
 if stem and suffix~=''and not suffix:match('^%.access%.json')then
  local fresh=P.file(root,stem)
  if new and exists(fresh)then return{target}end
  local shadow=P.file(root,'legacy-'..leaf)
  return new and{target,shadow,root..'/'..leaf}or{shadow,path}
 end
 return{target,root..'/'..leaf}
end
function P.read(path)
 if not P.parse(path)then return path end
 for _,p in ipairs(P.candidates(path))do
  if not P.safe(p)then return nil end
  local mode,err,code=lfs().symlinkattributes(p,'mode')
  if not mode and code~=2 then return nil end
  if mode then return mode=='file'and P.safe(p)and p or nil end
 end
 return P.safe(path)and path or nil
end
-- Validate every owned parent, never follow a cache-supplied symlink.
function P.safe(path)
 local root,name,new=P.parse(path);if not root then return true end
 local base=new and P.root(root)or root
 local baseMode,baseErr,baseCode=lfs().symlinkattributes(base,'mode')
 if not baseMode and baseCode~=2 then return false end
 if baseMode and baseMode~='directory'then return false end
 local current=base
 for part in name:gmatch('[^/]+')do
  if part=='.'or part=='..'then return false end
  current=current..'/'..part
  local mode,err,code=lfs().symlinkattributes(current,'mode')
  if not mode and code~=2 then return false end
  if mode=='link'or(mode and current~=path and mode~='directory')then return false end
 end
 return true
end
function P.ensure(path)
 local root,name,new=P.parse(path);if not root then return true end
 local base=new and P.root(root)or root
 local current=new and data():sub(1,-2)or root
 if lfs().symlinkattributes(current,'mode')~='directory'then return nil,'CACHE_DIRECTORY_INVALID',20 end
 local relative=new and(base:match('([^/]+)$')..'/'..name)or name
 for part in relative:gmatch('[^/]+')do
  if part=='.'or part=='..'then return nil,'CACHE_PATH_INVALID',13 end
  current=current..'/'..part
  if current~=path then
   local mode=lfs().symlinkattributes(current,'mode')
   if not mode then local ok,err,code=lfs().mkdir(current);if not ok and lfs().symlinkattributes(current,'mode')~='directory'then return nil,err,code end
   elseif mode~='directory'then return nil,'CACHE_DIRECTORY_INVALID',20 end
  elseif lfs().symlinkattributes(current,'mode')=='link'then return nil,'CACHE_SYMLINK_REJECTED',13 end
 end
 return true
end
function P.mirror(root,name)return assert(P.root(root))..'/mirrors/'..hash(name):sub(1,2)..'/'..name..'/'..name end
return P
