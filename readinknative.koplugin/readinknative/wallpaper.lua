-- Device-local images, prepared while awake. Suspend only selects a ready file.
-- Never changes KOReader settings or lastfile; native widgets own sleep/resume.
local W={owners={}}
local N=require('readinknative/nativewallpapers')
local function UI()return require('ui/uimanager')end
local function file(path)return type(path)=='string'and require('libs/libkoreader-lfs').attributes(path,'mode')=='file'end
local function setting(key,default)return G_reader_settings:readSetting('readinknative_wallpaper_'..key,default)end
function W.mode()local m=setting('mode','follow');return(m=='cover'or m=='wallpaper'or m=='native')and m or'follow'end
function W.label()return({follow='跟随 KOReader',cover='纯封面',wallpaper='纯壁纸',native='原生壁纸'})[W.mode()]end
function W.supported()local d=require('device');return d.supportsScreensaver and d:supportsScreensaver()end
function W.root()
 if W.directory then return W.directory end
 local root=require('datastorage'):getDataDir()..'/readink-wallpapers';require('util').makePath(root);W.directory=root;return root
end
function W.size()
 local s=require('device').screen;local w,h=s:getWidth(),s:getHeight();return math.min(w,h),math.max(w,h)
end
local function stamp(path)
 local a=path and require('libs/libkoreader-lfs').attributes(path)
 return a and a.mode=='file'and(path..':'..a.size..':'..a.modification)or nil
end
function W.compose(source,target,w,h,preserveAlpha)
 local R=require('ui/renderimage');local image
 if type(source)=='string'then
  assert(file(source),'WALLPAPER_MISSING');assert(require('libs/libkoreader-lfs').attributes(source,'size')<=16*1024*1024,'WALLPAPER_TOO_LARGE')
  image=assert(R:renderImageFile(source,false),'WALLPAPER_DECODE_FAILED')
 else image=assert(source,'WALLPAPER_DECODE_FAILED')end
 local gray
 local ok,err=pcall(function()
  local ratio=math.min(w/image:getWidth(),h/image:getHeight())
  image=R:scaleBlitBuffer(image,math.max(1,math.floor(image:getWidth()*ratio)),math.max(1,math.floor(image:getHeight()*ratio)))
  local BB=require('ffi/blitbuffer');local alpha=false
  if preserveAlpha~=false and(image:getType()==BB.TYPE_BB8A or image:getType()==BB.TYPE_BBRGB32)then
   for y=0,image:getHeight()-1 do
    for x=0,image:getWidth()-1 do if image:getPixel(x,y):getAlpha()<255 then alpha=true;break end end
    if alpha then break end
   end
  end
  gray=BB.new(w,h,alpha and BB.TYPE_BB8A or BB.TYPE_BB8)
  local x,y=math.floor((w-image:getWidth())/2),math.floor((h-image:getHeight())/2)
  if alpha then
   -- BB's general fill/blit routines may discard alpha. Write each straight
   -- gray/alpha pair directly; the zeroed allocation leaves transparent margins.
   for row=0,image:getHeight()-1 do for column=0,image:getWidth()-1 do
    local sourcePixel=image:getPixel(column,row):getColor8A();local targetPixel=gray:getPixelP(column+x,row+y)
    targetPixel[0].alpha=sourcePixel.alpha
    targetPixel[0].a=sourcePixel.alpha>0 and math.min(255,math.floor(sourcePixel.a*255/sourcePixel.alpha+0.5))or 0
   end end
  else
   gray:fill(BB.COLOR_WHITE);gray:pmulalphablitFrom(image,x,y,0,0,image:getWidth(),image:getHeight())
  end
  if alpha then
   assert(require('ffi/png').encodeToFile(target..'.part',require('ffi').cast('const uint8_t*',gray.data),w,h,2),'WALLPAPER_WRITE_FAILED')
  else assert(gray:writePNG(target..'.part')~=false,'WALLPAPER_WRITE_FAILED')end
  assert(os.rename(target..'.part',target),'WALLPAPER_WRITE_FAILED')
 end)
 if gray then gray:free()end;image:free()
 if not ok then os.remove(target..'.part');error(err,0)end
 return target
end
local legacyPresets={
 ['original-601ed567b96165194a3de888c31b148926a23e0f45add13f6a3b84b5dd32685a.jpg']='betta.png',
 ['original-e14f348036500f4a0ac779041829535846ec1b7691bda4f3771b754cf9d074c2.png']='betta.png',
 ['original-789bd1fe1bc2c621089c2c780e26760217027b2de869653aeaab0b370fa93b3d.jpg']='dolphin.png',
 ['original-4e7134341de7ac495cbd175ad194290013920400358e999d354772169da0aa62.jpg']='dragonfly.png',
}
function W.slot(slot)
 local path=setting(slot)
 local preset=type(path)=='string'and legacyPresets[path:match('[^/]+$')]
 if preset and W.presetRoot then
  local replacement=W.presetRoot..'/'..preset
  if file(replacement)then return replacement end
 end
 return file(path)and path or nil
end
function W.renderPath(source,w,h)
 local key=require('ffi/sha2').sha256(assert(stamp(source))..':'..w..'x'..h..':fit-gray-alpha2')
 return W.root()..'/render-'..key..'.png'
end
-- Only ready, screen-sized PNGs are decoded at sleep. Transparent pixels
-- are blended over a snapshot of the current screen, never a white matte.
function W.transparent(path)
 local f=path and io.open(path,'rb');if not f then return false end
 local header=f:read(26)
 if not header or header:sub(1,8)~='\137PNG\r\n\26\n' then f:close();return false end
 if header:byte(26)==4 or header:byte(26)==6 then f:close();return true end
 -- PNG may encode binary transparency with a tRNS chunk instead of an alpha
 -- channel, including an encoder-optimized grayscale or palette image.
 f:seek('set',8);local consumed=8
 while consumed<65536 do
  local chunk=f:read(8);if not chunk or #chunk~=8 then break end
  local a,b,c,d=chunk:byte(1,4);local length=((a*256+b)*256+c)*256+d;local kind=chunk:sub(5,8)
  if kind=='tRNS'then f:close();return true end
  if kind=='IDAT'or kind=='IEND'or length>65536-consumed then break end
  if not f:seek('cur',length+4)then break end;consumed=consumed+length+12
 end
 f:close();return false
end
function W.capture()
 local screen=require('device').screen;local BB=require('ffi/blitbuffer')
 local frame=BB.new(screen:getWidth(),screen:getHeight(),BB.TYPE_BB8);frame:blitFrom(screen.bb)
 if frame:getWidth()>frame:getHeight()then local rotated=frame:rotatedCopy(90);frame:free();frame=rotated end
 return frame
end
function W.overlay(path,frame)
 frame=frame or W.capture();local image
 local ok,err=pcall(function()
  image=assert(require('ui/renderimage'):renderImageFile(path,false),'WALLPAPER_DECODE_FAILED')
  assert(image:getWidth()==frame:getWidth()and image:getHeight()==frame:getHeight(),'WALLPAPER_SCREEN_CHANGED')
  frame:pmulalphablitFrom(image,0,0,0,0,image:getWidth(),image:getHeight())
 end)
 if image then image:free()end
 if not ok then frame:free();error(err,0)end
 return frame
end
function W.preview(path,frame)
 if W.transparent(path)then
  return require('ui/widget/imageviewer'):new{image=W.overlay(path,frame),image_disposable=true,fullscreen=true,with_title_bar=false,buttons_visible=false}
 end
 if frame then frame:free()end
 return require('ui/widget/imageviewer'):new{file=path,fullscreen=true,with_title_bar=false,buttons_visible=false}
end
local function identity(owner)
 local a=owner.app;local b=a.book
 if not b or not a.document or(a.mode~='reader'and a.mode~='catalog'and a.mode~='social'and a.mode~='notes'and a.mode~='settings'and a.mode~='search')then return end
 return tostring(a.client and a.client.data and a.client.data.vid)..':'..tostring(b.bookId)..':'..tostring(b.cover)..':'..tostring(b.localFile)
end
local function coversource(owner)
 local a=owner.app;local b=a.book
 if not identity(owner)then return end
 -- Whole-book account cover only: a chapter document's first page is not a cover.
 local vid=a.client and a.client.data and a.client.data.vid
 local source=require('readinknative/media').find(vid,b.cover)
 if source then return source,tostring(vid)..':'..tostring(b.bookId)..':'..stamp(source)end
 local doc=owner.pdf and owner.pdf.document or b.localFile and a.document.doc
 if doc and doc.getCoverPageImage then
  return nil,tostring(vid)..':'..tostring(b.bookId)..':'..tostring(stamp(b.localFile or doc.file)),doc
 end
end
local function visible(owner)
 local a=owner.app
 local reader=require('apps/reader/readerui').instance
 if not owner.pdf and reader and reader~=a.host then return false end
 return not owner.closed and(owner.pdf and owner.pdf:owned()or not a.closed and a.hasBeenShown)
  and UI():isWidgetShown(owner.widget)
end
local function current()
 for i=#W.owners,1,-1 do local o=W.owners[i];if visible(o)then return o end end
end
function W.pick(owner)
 if not owner or W.mode()=='follow'or not W.supported()then return end
 local w,h=W.size();local path
 if W.mode()=='cover'then
  local key=identity(owner)
  if key and owner.coverIdentity==key and owner.coverSize==w..'x'..h then path=owner.coverReady end
 elseif W.mode()=='native'then
  path=N.pick(w,h)
 else
  local source=W.slot('image');if source then path=W.renderPath(source,w,h)end
 end
 if file(path)then return path end
 local fallback=W.slot('fallback');if fallback then path=W.renderPath(fallback,w,h);if file(path)then return path end end
end
function W.install()
 if W.wrapper then return end
 local S=require('ui/screensaver');W.original=S.setup
 W.wrapper=function(s,event,...)
  local ok,owner,path=pcall(function()local o=current();return o,not event and W.pick(o)end)
  if ok and path then
   -- Known native image fields; do not open any book engine at power press.
   s.ui=owner.pdf and owner.pdf.ui or owner.app.host
    or require('apps/reader/readerui').instance or require('apps/filemanager/filemanager').instance
   if s.ui then
    local image
    if W.transparent(path)then
     local composed,result=pcall(W.overlay,path)
     if not composed then return W.original(s,event,...)end
     image=result
     -- Native auto-rotation rotates inverted portrait by 180 degrees. The
     -- captured screen already has that orientation, so compensate once.
     if require('device').screen:getRotationMode()==3 and G_reader_settings:isTrue('screensaver_rotate_auto_for_best_fit')then
      local rotated=image:rotatedCopy(180);image:free();image=rotated
     end
    end
    s.screensaver_type='cover';s.image=image;s.image_file=not image and path or nil;s.show_message=false
    s.prefix='';s.event_message=nil;s.overlay_message=nil;s.screensaver_background='white'
    if W.mode()=='native'then N.used(path)end
    return
   end
  end
  return W.original(s,event,...)
 end
 S.setup=W.wrapper
end
function W.attach(app,pdf)
 if app.path then W.presetRoot=app.path..'/resources/wallpapers'end
 if app.wallpaperOwner then return app.wallpaperOwner end
 W.root()
 local owner={app=app,pdf=pdf,widget=pdf and(pdf.ui.dialog or pdf.ui)or app.view,
  jobs=require('readinknative/inkjobs').new{TIMEOUT=30}}
 app.wallpaperOwner=owner;W.owners[#W.owners+1]=owner;W.install();W.refresh(app);return owner
end
function W.stop(app)
 local o=app.wallpaperOwner;if not o then return end
 if o.task then UI():unschedule(o.task);o.task=nil end
 o.jobs:cancel();o.request=o.completed
end
function W.detach(app)
 local o=app.wallpaperOwner;if not o then return end
 W.stop(app);o.closed=true;app.wallpaperOwner=nil
 for i=#W.owners,1,-1 do if W.owners[i]==o then table.remove(W.owners,i)end end
 if #W.owners==0 and W.wrapper then
  local S=require('ui/screensaver');if S.setup==W.wrapper then S.setup=W.original end
  -- If a later plugin wrapped ours, retain its captured delegate safely.
  if S.setup==W.original then W.wrapper=nil;W.original=nil end
 end
end
function W.refresh(app)
 local o=app.wallpaperOwner;if not o or o.closed or app.suspended or W.mode()=='follow'or not W.supported()then return end
 if o.task then return end
 o.task=function()
  o.task=nil;if o.closed or app.suspended or not visible(o)then return end
  local mode=W.mode();local w,h=W.size();local source,key,document=coversource(o);local bookIdentity=identity(o)
  local nativeSource=mode=='native'and N.choose(W.presetRoot)or nil
  local nativeTarget=nativeSource and W.renderPath(nativeSource,w,h):gsub('/render%-','/native-render-')
  local previousNative=N.ready
  local signature=mode..':'..w..'x'..h..':'..tostring(key)..':'..tostring(stamp(W.slot('image')))..':'..tostring(stamp(W.slot('fallback')))..':'..tostring(stamp(nativeSource))
  if o.request==signature then return end;o.request=signature
  local coverTarget=key and W.root()..'/cover-'..require('ffi/sha2').sha256(key..':'..w..'x'..h)..'.png'
  local slots={};for _,slot in ipairs{'image','fallback'}do local s=W.slot(slot);if s then slots[#slots+1]={source=s,target=W.renderPath(s,w,h)}end end
  o.jobs:run('准备锁屏图片',function()
   if nativeSource then
    if not file(nativeTarget)then W.compose(nativeSource,nativeTarget,w,h,false)end
    N.prune(W.root(),nativeTarget,previousNative);return nativeTarget
   end
   for _,slot in ipairs(slots)do if not file(slot.target)then pcall(W.compose,slot.source,slot.target,w,h)end end
   if key and mode=='cover'then
    if not file(coverTarget)then W.compose(source or document:getCoverPageImage(),coverTarget,w,h,false)end
    W.pruneCovers();return coverTarget
   end
   return false
  end,function(ok,result)
   if o.closed or app.suspended or o.request~=signature then return end
   if mode=='native'and nativeSource then
    if ok then N.prepared(nativeSource,result,w,h);o.completed=signature
    else N.failed(nativeSource);o.request=nil end
    return
   end
   o.completed=signature
   if ok then o.coverKey=key;o.coverIdentity=bookIdentity;o.coverSize=w..'x'..h;o.coverReady=result or nil end
  end,false)
 end
 UI():scheduleIn(0.25,o.task)
end
function W.changed()
 for _,o in ipairs(W.owners)do W.stop(o.app);o.request=nil;o.completed=nil;o.coverKey=nil;o.coverReady=nil;W.refresh(o.app)end
end
function W.setMode(mode)
 assert(mode=='follow'or mode=='cover'or mode=='wallpaper'or mode=='native');G_reader_settings:saveSetting('readinknative_wallpaper_mode',mode);W.changed()
end
function W.import(source,slot)
 assert(slot=='image'or slot=='fallback');assert(file(source),'WALLPAPER_MISSING')
 local f=assert(io.open(source,'rb'));local data=f:read(16*1024*1024+1);f:close()
 assert(#data<=16*1024*1024,'WALLPAPER_TOO_LARGE')
 local kind=require('readinknative/media').kind(data);assert(kind and(kind=='.png'or kind=='.jpg'),'WALLPAPER_FORMAT')
 local path=W.root()..'/original-'..require('ffi/sha2').sha256(data)..kind
 local w,h=W.size();local render=W.renderPath(source,w,h)
 -- Validate/render before changing the setting. A failed import keeps the old image.
 W.compose(source,render,w,h)
 local out=assert(io.open(path..'.part','wb'));local wrote=out:write(data);local closed=out:close();assert(wrote and closed,'WALLPAPER_WRITE_FAILED')
 assert(os.rename(path..'.part',path),'WALLPAPER_WRITE_FAILED')
 local ready=W.renderPath(path,w,h)
 if ready~=render then assert(os.rename(render,ready),'WALLPAPER_WRITE_FAILED')end
 return path
end
function W.pruneCovers()
 local root=W.root();local lfs=require('libs/libkoreader-lfs');local covers={}
 for name in lfs.dir(root)do
  if name:match('^cover%-%x+%.png$')then local full=root..'/'..name;covers[#covers+1]={path=full,time=lfs.attributes(full,'modification')or 0}end
 end
 table.sort(covers,function(a,b)return a.time>b.time end)
 for i=9,#covers do os.remove(covers[i].path)end
end
function W.commit(path,slot)
 assert(file(path));G_reader_settings:saveSetting('readinknative_wallpaper_'..slot,path);W.changed()
 local keep={};local w,h=W.size()
 for _,name in ipairs{'image','fallback'}do local original=W.slot(name);if original then keep[original]=true;keep[W.renderPath(original,w,h)]=true end end
 local root=W.root();local lfs=require('libs/libkoreader-lfs')
 for name in lfs.dir(root)do
  local full=root..'/'..name
  if name:match('^original%-%x+%.%w+$')or name:match('^render%-%x+%.png$')then
   if not keep[full]then os.remove(full)end
  end
 end
 W.pruneCovers()
end
-- Local PDFs do not have a cloud sync module; still bind their native lifetime.
function W.attachPdf(reader,context)
 if reader.readinkPdfSync then return end
 if reader.readinkWallpaper or not context or not context.book or not reader.document then return end
 local a={state=context.state,client=context.client,book=context.book,document=reader.document,mode='reader'}
 local module=require('ui/widget/container/widgetcontainer'):extend{ui=reader,app=a,document=reader.document}
 function module:owned()return not self.closed and self.ui.document==self.document end
 function module:onSuspend()self.app.suspended=true;W.stop(self.app)end
 function module:onResume()self.app.suspended=false;W.refresh(self.app)end
 function module:onCloseDocument()self.closed=true;W.detach(self.app)end
 module.onCloseWidget=module.onCloseDocument
 reader.readinkWallpaper=module;reader:registerModule('readink_wallpaper',module,true);W.attach(a,module)
end
function W.blocked()return require('ui/screensaver').screensaver_widget~=nil end
function W.out(app)
 if not app.wallpaperResumePending then return end
 UI():nextTick(function()if app.wallpaperResumePending and not W.blocked()then app.wallpaperResumePending=nil;app:resume()end end)
end
return W
