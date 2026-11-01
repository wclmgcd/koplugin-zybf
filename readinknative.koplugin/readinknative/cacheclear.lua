-- Fresh discovery for one official category. The saved inventory supplies only
-- untouched display rows; it never supplies candidates or paths to unlink.
local Q={}
function Q.plan(vid,kind,state,baseline,observe)
 local C=require('readinknative/cache');local F=require('readinknative/cachefiles');local G=require('readinknative/cachegroups');local lfs=require('libs/libkoreader-lfs')
 local root=require('readinknative/paths').account(vid);assert(lfs.symlinkattributes(root,'mode')=='directory','CACHE_DIRECTORY_FAILED')
 local rows,present,attrs={},{},{};local metrics={files=0,markers=0,pages=0,mirrorDirs=0}
 local function attributes(path)
  if attrs[path]==nil then attrs[path]=lfs.symlinkattributes(path)or false;metrics.files=metrics.files+1 end
  return attrs[path]
 end
 local function entry(name,path,kind,a)
  return{name=name,path=path,kind=kind,size=a and a.size or 0,modified=a and a.modification,changed=a and a.change}
 end
 F.walk(root,observe,function(name,path)
  local k=F.kind(name)
  if k then
   local row=entry(name,path,k);local plain=C.classify(F.basename(name):gsub('%.part$',''))
   if kind~='cover'and plain=='article'then row._a=attributes(path);metrics.markers=metrics.markers+1
   elseif kind~='cover'and k=='pagination'then row._a=attributes(path);metrics.pages=metrics.pages+1 end
   if row._a==nil or(row._a and row._a.mode=='file')then
    if row._a then row.size=row._a.size or 0;row.modified=row._a.modification;row.changed=row._a.change end
    rows[#rows+1]=row;present[name]=row
   end
  end
 end)
 if kind=='cover'then
  for _,row in ipairs(rows)do row.category=C.classify(row.name:gsub('%.part$',''))=='cover'and'cover'or'books'end
 else G.decorate(rows,state)end
 local selected,chosen={},{}
 for _,row in ipairs(rows)do
  if C.matches(kind,row)then
   local a=attributes(row.path)
   if a and a.mode=='file'then
    local value=entry(row.name,row.path,row.kind,a);value.refs=row.refs;value.category=row.category;value.unread=row.unread
    selected[#selected+1]=value;chosen[row.name]=true
   end
  end
 end
 local remaining={}
 for _,old in ipairs(baseline)do
  if type(old.name)=='string'and F.kind(old.name)==old.kind and present[old.name]and not chosen[old.name]then
   local path=F.target(root,old.name)
   if path then local row=entry(old.name,path,old.kind,{size=old.size,modification=old.modified,change=old.changed});row.refs=old.refs;remaining[#remaining+1]=row end
  end
 end
 for _,row in ipairs(selected)do remaining[#remaining+1]=row end
 if kind=='mp'then require('readinknative/cacheengine').append(selected,vid)end
 return selected,remaining,metrics
end
return Q
