-- Explicit, public font download. No WeRead token or Cookie.
local M={MAX=48*1024*1024,READ_SIZE=16384}
function M.url(url)
 assert(type(url)=='string'and url:match('^https://cdn%.weread%.qq%.com/app/assets/app_fonts_new/[%w_-]+%.zip$'),'FONT_URL_REJECTED');return url
end
function M.request(args)
 M.url(args.url)
 local trace=args.fontTrace;args.fontTrace=nil
 local clock=require('socket')
 local https=require('ssl.https');local source=debug.getinfo(1,'S').source
 local ca=assert(source:match('^@(.*/)[^/]+$'))..'../resources/font-ca.pem'
 local create=https.tcp{protocol='any',options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'},verify='peer',cafile=ca}
 args.redirect=false;args.proxy=nil
 args.create=function()
  local connection=create();local connect=connection.connect
  local receive=require('readinknative/fontsocket').inspect(connection.sock)
  connection.connect=function(self,host,port)
   if host~='cdn.weread.qq.com'or tonumber(port)~=443 then self:close();return nil,'FONT_HOST_REJECTED'end
   local started=clock.gettime()
   local ok,err=connect(self,host,port);if not ok then return nil,err end
   local cert=self.sock:getpeercertificate();local ext=cert and cert:extensions();local san=ext and ext['2.5.29.17']
   for _,name in ipairs(san and san.dNSName or{})do if name=='cdn.weread.qq.com'or name=='*.weread.qq.com'then
    receive=receive or require('readinknative/fontsocket').inspect(connection.sock)
    if trace then trace(math.floor((clock.gettime()-started)*1000),receive)end;return 1
   end end
   self:close();return nil,'FONT_TLS_HOSTNAME_REJECTED'
  end
  return connection
 end
 -- A public font is a large binary response. Scope the larger TLS-record-sized
 -- reads to this request, restoring LuaSocket even on transport exceptions.
 local http=require('socket.http');local oldSize=clock.BLOCKSIZE;clock.BLOCKSIZE=M.READ_SIZE
 local ok,a,b,c,d=pcall(http.request,args)
 clock.BLOCKSIZE=oldSize;if not ok then error(a,0)end;return a,b,c,d
end
function M.response(status,headers,size)
 headers=headers or{};local range=headers['content-range'];local length=headers['content-length']
 if length and tonumber(length)~=size then return false end
 if tonumber(status)==200 then return not range end
 if tonumber(status)~=206 or type(range)~='string'or #range>80 then return false end
 local last,total=range:lower():match('^bytes%s+0%-(%d+)/(%d+)$')
 return tonumber(last)==size-1 and tonumber(total)==size
end
function M.path(item)
 assert(type(item)=='table'and type(item.font)=='string'and item.font:match('^[%w_-]+$')and #item.font<80 and(item.suffix=='ttf'or item.suffix=='otf'),'FONT_ITEM_REJECTED')
 return require('datastorage'):getDataDir()..'/fonts/readink/'..item.font..'.'..item.suffix
end
function M.download(item,progress,token)
 local clock=require('socket');local started=clock.gettime();local phase;local cpu=os.clock()
 local metrics={}
 local function report(name,bytes,total)
  if phase~=name then require('logger').info('ReadInk font stage/ms:',name,math.floor((clock.gettime()-started)*1000));io.stdout:flush();phase=name end
  if progress then progress(name,bytes,total)end
 end
 -- KOReader already forks these at background nice 5. Do not add nice(+15)
 -- here: combined with the silent job's increment it starved fonts at 19.
 local ffi=require('ffi');require('ffi/posix_h')
 pcall(ffi.cdef,'int getpriority(int which, int who);')
 local priority=pcall(function()metrics.nice=tonumber(ffi.C.getpriority(ffi.C.PRIO_PROCESS,0))end)
 local target=M.path(item);M.url(item.url)
 require('logger').info('ReadInk font task/id/bytes/nice:',item.font,item.zipSize,priority and metrics.nice or'unknown')
 assert(item.isVIPFont==0,'FONT_MEMBER_RIGHT_REQUIRED')
 assert(type(item.fileSize)=='number'and item.fileSize>0 and item.fileSize<=M.MAX,'FONT_SIZE_REJECTED')
 assert(type(item.zipSize)=='number'and item.zipSize>0 and item.zipSize<=M.MAX,'FONT_SIZE_REJECTED')
 local lfs=require('libs/libkoreader-lfs');local dir=target:match('^(.*)/');require('util').makePath(dir)
 assert(lfs.symlinkattributes(dir,'mode')=='directory'and not lfs.symlinkattributes(target),'FONT_PATH_EXISTS')
 pcall(ffi.cdef,'int getpid(void);int getppid(void);int kill(int, int);');local pid=tonumber(ffi.C.getpid())
 local owner;if token then assert(type(token)=='string'and #token<=80 and token:match('^owner%-%d+%-%d+%-%d+$'),'FONT_TEMP_OWNER');owner=tonumber(token:match('^owner%-(%d+)'));assert(tonumber(ffi.C.getppid())==owner,'FONT_TEMP_OWNER')end
 -- A cancelled subprocess may not execute finally: remove only this font's
 -- regular temporary files whose creating process no longer exists.
 local prefix=target:match('([^/]+)$'):gsub('([^%w])','%%%1');local checked=0
 for name in lfs.dir(dir)do
  checked=checked+1;if checked>2048 then break end
  local owner,suffix=name:match('^'..prefix..'%.(%d+)%.part(.*)$');owner=tonumber(owner)
  if not owner then owner=tonumber(name:match('^'..prefix..'%.owner%-(%d+)%-%d+%-%d+%.part$'));if owner then suffix=''end end
  if owner and owner>1 and owner~=pid and(suffix==''or suffix=='.zip'or suffix=='.raw')and ffi.C.kill(owner,0)~=0 and ffi.errno()==3 then
   local old=dir..'/'..name;if lfs.symlinkattributes(old,'mode')=='file'then os.remove(old)end
  end
 end
 local temp=target..'.'..(token or pid)..'.part';local archive=temp..'.zip'
 for _,path in ipairs{temp,archive}do assert(not lfs.symlinkattributes(path),'FONT_TEMP_PATH_EXISTS')end
 local stream=require('readinknative/fontstream').new(temp,item.fileSize,item.zipSize);local bytes=0;local overflow=false
 local timer=require('socketutil');timer:set_timeout(10,90)
 local ok,result=pcall(function()
  report('download',0,item.zipSize)
  local transfer=clock.gettime();local transferCpu=os.clock()
  local accepted,status,headers=M.request{url=item.url,method='GET',fontTrace=function(ms,receive)
   metrics.connectTlsMs=ms;if receive then metrics.receiveBefore=receive.before;metrics.receiveAfter=receive.after end
  end,headers={['User-Agent']='ReadInk/'..require('readinknative/version'),['Accept-Encoding']='identity',Range='bytes=0-'},sink=function(chunk)
   if owner and tonumber(ffi.C.getppid())~=owner then return nil,'FONT_OWNER_EXITED'end
   if chunk and not metrics.firstByteMs then metrics.firstByteMs=math.floor((clock.gettime()-transfer)*1000)end
   if chunk then bytes=bytes+#chunk;if bytes>M.MAX or bytes>item.zipSize then overflow=true;return nil,'FONT_TOO_LARGE'end
    local good=pcall(stream.feed,stream,chunk);if not good then return nil,'FONT_ARCHIVE_FAILED'end;report('download',bytes,item.zipSize)end;return 1
  end}
  metrics.transferMs=math.floor((clock.gettime()-transfer)*1000);metrics.transferCpuMs=math.floor((os.clock()-transferCpu)*1000);metrics.bytes=bytes;metrics.httpStatus=tonumber(status);metrics.pipeline=true
  assert(accepted and M.response(status,headers,item.zipSize)and not overflow and bytes==item.zipSize,'FONT_DOWNLOAD_FAILED')
  local decoded=stream:finish();metrics.extractMs=decoded.workMs;metrics.extractCpuMs=decoded.cpuMs;metrics.zipStaged=false;metrics.zipEntries=decoded.entries;metrics.fontBytes=decoded.bytes
  require('logger').info('ReadInk font receive+extract/id/connectTLS/firstByte/total/work/cpu/bytes:',item.font,metrics.connectTlsMs or-1,metrics.firstByteMs or-1,metrics.transferMs,metrics.extractMs,metrics.transferCpuMs,bytes)
  require('logger').info('ReadInk font response/id/status/receiveBefore/receiveAfter:',item.font,metrics.httpStatus or-1,metrics.receiveBefore or-1,metrics.receiveAfter or-1)
  local family='ReadInk-'..item.font
  report('install',0,item.fileSize)
  require('readinknative/fontsfnt').inplace(temp,family,function(n,total)report('install',n,total)end)
  -- No FreeType/CRe in this file-only worker. Register exactly once in the UI
  -- after atomic installation, never in the fork inherited from a live book.
  assert(not lfs.symlinkattributes(target)and os.rename(temp,target),'FONT_INSTALL_FAILED')
  metrics.totalMs=math.floor((clock.gettime()-started)*1000);metrics.cpuMs=math.floor((os.clock()-cpu)*1000)
  return{path=target,face=family,metrics=metrics}
 end)
 timer:reset_timeout();stream:abort();os.remove(archive)
 if not ok then report('failed');error(result,0)end;report('done');return result
end
function M.select(a,item)
 local selectedAt=require('socket').gettime()
 if a.fontDownload then local same=a.fontDownload.font==item.font;require('readinknative/fontprogress').cancel(a);if same then return end end
 local fonts=require('readinknative/readerfonts')
 if item.font then
  -- A stale menu item may still carry a matching host family. Resolve the
  -- official ID again and never use that cached face as an installation test.
  local current=fonts.get(item.font)
  if not current then a:message(require('readinknative/errors').message('FONT_ITEM_REJECTED'));return end
  item={};for k,v in pairs(current)do item[k]=v end
  item.bundled=require('readinknative/fontidentity').bundled[item.font]~=nil
 end
 if item.creSupported==false then a:message('此字体目前无法由 CRengine 加载，请选择其他字体。');return end
 local face,err
 if item.font then face,err=fonts.load(a.document,item)
 elseif item.face then face,err=fonts.ensure(a.document,item.face)end
 if face then a:changeFormat{face=face};a.panel=a.panel=='faces'and'faces'or'font';a:draw();return end
 if item.bundled and err=='FONT_FILE_MISSING'then a:message('内置字体文件缺失，请重新安装完整阅墨插件。');return end
 if err and(err~='FONT_FILE_MISSING'or not item.font)then a:message(require('readinknative/errors').message(err));return end
 if not item.url or item.url==''then a:message('此字体尚未安装。可将自有字体放入 KOReader/fonts 后重启。');return end
 if item.isVIPFont~=0 then a:message('此字体需要对应会员授权，当前版本暂不下载。');return end
 local network=require('ui/network/manager');if not network:isWifiOn()or not network:isConnected()then a:message('请先连接 Wi-Fi 下载字体。');return end
 local state,book,document=a.state,a.book,a.document
 require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel()
 require('readinknative/chapterloader').stop(a);require('readinknative/socialreader').cancel(a);require('readinknative/underlinenext').stop(a)
 require('readinknative/resident').drop(a);document:clearPageImages();collectgarbage('collect')
 require('logger').info('ReadInk font foreground prep/id/ms:',item.font,math.floor((require('socket').gettime()-selectedAt)*1000))
 return require('readinknative/fontprogress').run(a,item,function(report,token)return M.download(item,report,token)end,function(ok,result)
  if a.closed or a.suspended or a.state~=state or a.book~=book or a.document~=document then return end
  if not ok then require('logger').warn('ReadInk font download failed');a:message('字体下载未完成，请稍后重试。');return end
  local clock=require('socket');local started=clock.gettime()
  local registered,problem;local good=pcall(function()
   assert(result.face==fonts.expected(item)and result.path==M.path(item),'FONT_ITEM_REJECTED')
   local face=require('ffi/freetype').newFaceSize(result.path,20);local valid=face:getInfo().name==result.face and face:hasGlyph(0x4e2d);face:done();assert(valid,'FONT_FACE_REJECTED')
   registered,problem=fonts.load(document,item)
  end)
  require('logger').info('ReadInk font register ms:',math.floor((clock.gettime()-started)*1000))
  if not good or not registered then a:message('字体已下载，但未能加载。'..require('readinknative/errors').message(problem or'FONT_LOAD_FAILED'));return end
  a.fontGridDocument=nil;a:changeFormat{face=registered};a:draw()
  require('logger').info('ReadInk font apply ms:',math.floor((clock.gettime()-started)*1000))
 end,true)
end
return M
