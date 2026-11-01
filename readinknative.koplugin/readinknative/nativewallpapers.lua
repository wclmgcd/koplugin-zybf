-- Bundled Kindle artwork. Pick while awake; sleep only uses a prepared file.
local N={count=12,bag={}}
local moduleRoot=debug.getinfo(1,'S').source:match('^@(.+)/readinknative/nativewallpapers%.lua$')
local function file(path)return type(path)=='string'and require('libs/libkoreader-lfs').attributes(path,'mode')=='file'end
local function basename(path)return path and path:match('[^/]+$')end
function N.choose(root)
 root=root or(moduleRoot and moduleRoot..'/resources/wallpapers')
 if not root then return end
 if N.root~=root then N.root=root;N.bag={};N.source=nil end
 if file(N.source)then return N.source end
 N.source=nil
 if #N.bag==0 then
  for i=0,N.count-1 do
   local path=root..'/native/'..string.format('bg_ss%02d.png',i)
   if file(path)then N.bag[#N.bag+1]=path end
  end
  for i=#N.bag,2,-1 do local j=math.random(i);N.bag[i],N.bag[j]=N.bag[j],N.bag[i]end
  -- A full round shows every image once; its boundary must not repeat either.
  local last=G_reader_settings:readSetting('readinknative_wallpaper_native_last')
  if #N.bag>1 and basename(N.bag[#N.bag])==last then
   N.bag[1],N.bag[#N.bag]=N.bag[#N.bag],N.bag[1]
  end
 end
 while #N.bag>0 do
  local source=table.remove(N.bag)
  if file(source)then N.source=source;return source end
 end
end
function N.pick(w,h)
 if N.width==w and N.height==h and file(N.ready)then return N.ready end
end
function N.prepared(source,path,w,h)
 if N.source~=source or not file(path)then return end
 N.readySource=source;N.ready=path;N.width=w;N.height=h
end
function N.used(path)
 if path~=N.ready then return end
 local name=basename(N.readySource)
 if name then G_reader_settings:saveSetting('readinknative_wallpaper_native_last',name)end
 if N.source==N.readySource then N.source=nil end
end
function N.failed(source)
 if N.source==source then N.source=nil end
end
function N.prune(root,keep,previous)
 local lfs=require('libs/libkoreader-lfs')
 for name in lfs.dir(root)do
  if name:match('^native%-render%-%x+%.png$')then
   local path=root..'/'..name
   if path~=keep and path~=previous then os.remove(path)end
  end
 end
end
return N
