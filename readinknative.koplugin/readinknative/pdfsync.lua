-- PDF pages are the official cloud coordinate, never a fabricated text offset.
-- This ReaderUI module owns its timers/hooks; no global reader method changes.
local UI=require('ui/uimanager');local Sync=require('readinknative/readsync')
local Module=require('ui/widget/container/widgetcontainer'):extend{}
local P={INTERVAL=30}
local function flush(state)(state.flushProgress or state.flush)(state)end
local function number(n,lo,hi)return type(n)=='number'and n==n and n%1==0 and n>=lo and n<=hi end
function Module:now()return require('ui/time').to_s(require('ui/time').monotonic())end
function Module:owned()
 return not self.closed and self.app.state==self.owner and self.app.client.data.vid==self.vid
  and self.ui.document==self.document
end
function Module:foreground()
 return self:owned()and not self.paused and not self.app.suspended
  and UI:isWidgetShown(self.ui.dialog or self.ui)and UI:getTopmostVisibleWidget()==(self.ui.dialog or self.ui)
end
function Module:page()
 local page=self.ui.paging and self.ui.paging.current_page;local total=self.document and self.document:getPageCount()
 if number(total,1,2147483647)and number(page,1,total)then return page,total end
end
function Module:sample(now,wall)
 now=math.floor(now or self:now());wall=wall or os.time()
 local active=self:foreground();local previous=self.interval
 -- Both endpoints must be visible. Input hooks sample immediately before/after
 -- menu input; the timer is conservative for programmatically shown overlays.
 if previous and previous.active and active then
  local delta=math.floor(now-previous.now)
  if delta>0 and delta<=90 then
   local stats=require('readinknative/readingstats');local value=self.owner.readingStats or stats.normalize();self.owner.readingStats=value
   local id=tostring(self.app.book.bookId);value.books[id]=(value.books[id]or 0)+delta
   for t=wall-delta,wall-1 do local day=os.date('%Y-%m-%d',t);value.days[day]=(value.days[day]or 0)+1 end
   Sync.record(self.app,{book=self.app.book,wall=previous.wall},delta,wall)
   require('readinknative/shelforder').touch(self.owner,self.app.book,wall)
  end
 end
 self.interval={now=now,wall=wall,active=active}
end
function Module:capture(updated)
 if not self:owned()or self.app.syncApplying then return end
 local page,total=self:page();if not page then return end
 if self.pageNumber and self.pageNumber~=page then self.positionUpdated=updated or os.time()end
 self.pageNumber=page;self.positionUpdated=updated or self.positionUpdated or 0
 local position={pdf=true,page=page,pages=total,updated=self.positionUpdated}
 self.owner:position(self.app.book,nil,position)
 return Sync.capturePdf(self.app,page,total,self.positionUpdated)
end
function Module:tick()
 if not self:owned()then self:finish();return end
 self:sample();self:capture();flush(self.owner)
 if self:foreground()then Sync.request(self.app)end
 UI:scheduleIn(P.INTERVAL,self.tickTask)
end
function Module:onInputEvent()
 if not self:owned()then return end
 self:sample();self.app.pdfEpoch=self.app.pdfEpoch+1
 UI:unschedule(self.inputTask);UI:nextTick(self.inputTask)
end
function Module:onPageUpdate()
 if not self:owned()then return end
 self:sample();self.app.pdfEpoch=self.app.pdfEpoch+1
 if not self.app.syncApplying then self:capture();flush(self.owner)end
end
function Module:onSuspend()
 if not self:owned()then return end
 require('readinknative/wallpaper').stop(self.app)
 self:sample();self:capture();flush(self.owner)
 self.paused=true;self.app.suspended=true;self.interval=nil
 UI:unschedule(self.tickTask);UI:unschedule(self.inputTask);UI:unschedule(self.startTask)
 self.app.pdfEpoch=self.app.pdfEpoch+1
end
function Module:onResume()
 if not self:owned()then return end
 self.paused=false;self.app.suspended=false;self.interval=nil;self:sample()
 require('readinknative/wallpaper').refresh(self.app)
 UI:unschedule(self.tickTask);UI:scheduleIn(P.INTERVAL,self.tickTask)
end
function Module:onReadingPaused()
 if not self:owned()then return end
 self:sample();self.paused=true;self.interval=nil;self.app.pdfEpoch=self.app.pdfEpoch+1
end
function Module:onReadingResumed()
 if not self:owned()then return end
 self.paused=false;self.interval=nil;self:sample()
end
function Module:onSaveSettings()
 if self:owned()then self:sample();self:capture();flush(self.owner)end
end
function Module:onNetworkConnected()
 if self:foreground()then self:capture();Sync.request(self.app,false,true)end
end
function Module:manual()
 if not self:owned()then return end
 self:sample();self:capture();flush(self.owner);Sync.request(self.app,true,true)
end
function Module:addToMainMenu(items)
 items.readink_pdf_sync={text='同步阅墨 PDF 阅读进度',enabled_func=function()return self:owned()end,
  callback=function()if self.ui.menu then self.ui.menu:onTapCloseMenu()end;self:manual()end}
end
function Module:offerRemote(remote,book,position)
 if not remote or not remote.pdf or not position or not self:foreground()or self.ui.tearing_down or not self.app.book
  or tostring(book.bookId)~=tostring(self.app.book.bookId)or remote.appId==self.app.client.data.deviceId
  or remote.updated<=(position.updated or 0)or position.pdfEpoch~=self.app.pdfEpoch then return end
 if remote.version and tostring(remote.version)~=tostring(self.app.book.version or 0)then return end
 local page,total=self:page();local target=tonumber(remote.chapterUid)
 if not page or page~=position.page or not number(target,0,total-1)or target+1==page then return end
 local key=tostring(book.bookId)..':'..remote.updated
 if self.app.syncPrompt==key then return end;self.app.syncPrompt=key
 local epoch=self.app.pdfEpoch
 local function valid()return self:owned()and not self.app.suspended and self.app.pdfEpoch==epoch and self.ui.paging.current_page==page end
 UI:show(require('ui/widget/confirmbox'):new{text='其他设备的 PDF 阅读进度已更新，是否跳转到第 '..tostring(target+1)..' 页？',ok_text='跳转',cancel_text='留在这里',
  ok_callback=function()
   if not valid()then return end
   self:sample();self.app.syncApplying=true
   self.ui.paging:onGotoPage(target+1)
   self.app.syncApplying=nil;self.positionUpdated=remote.updated;self.pageNumber=target+1
   self:capture(remote.updated);flush(self.owner);self.interval=nil
  end,
  cancel_callback=function()
   if valid()then self:capture(os.time());flush(self.owner);self.interval=nil end
  end})
 self.interval=nil
end
function Module:finish()
 require('readinknative/wallpaper').detach(self.app)
 if self.closed then return end
 if self:owned()then
  self:sample();self:capture();flush(self.owner)
  -- Start before marking the UI closed. The bounded worker writes its durable
  -- receipt after ReaderUI closes; no callback may revive or mutate that UI.
  self.app.suspended=false;Sync.request(self.app,false,true)
 end
 self.closed=true;self.app.closed=true;self.interval=nil
 Sync.stop(self.app);UI:unschedule(self.tickTask);UI:unschedule(self.inputTask);UI:unschedule(self.startTask)
 if self.inputHook then UI.event_hook:unregister('InputEvent',self.inputHook);self.inputHook=nil end
end
Module.onCloseDocument=Module.finish
Module.onCloseWidget=Module.finish
function P.attach(reader,context)
 if reader.readinkPdfSync then return reader.readinkPdfSync end
 if not context or not context.state or not context.state.root or not context.book or context.book.localFile
  or not context.client or not context.client:ready()or context.client.data.vid==nil
  or not reader.document or not reader.document.is_pdf then return end
 local app={state=context.state,client=context.client,book=context.book,document=reader.document,mode='reader',
  syncEnabled=context.syncEnabled,pdfEpoch=0}
 local module=Module:new{ui=reader,app=app,owner=app.state,vid=app.client.data.vid,document=reader.document}
 app.pdfSync=module;reader.readinkPdfSync=module
 app.message=function(_,message)
  if module:owned()then module.interval=nil;UI:show(require('ui/widget/infomessage'):new{text=message,timeout=3})end
 end
 local previous=app.state:position(app.book,nil)
 module.positionUpdated=previous and previous.pdf and previous.page==(reader.paging and reader.paging.current_page)and previous.updated or 0
 module.tickTask=function()module:tick()end
 module.inputTask=function()if module:owned()then module:sample();module:capture();flush(module.owner)end end
 module.startTask=function()
  if not module:owned()then return end
  module:sample();module:capture();flush(module.owner);Sync.request(app,false,true)
  UI:scheduleIn(P.INTERVAL,module.tickTask)
 end
 module.inputHook=function()module:onInputEvent()end;UI.event_hook:register('InputEvent',module.inputHook)
 reader:registerModule('readink_pdf_sync',module,true)
 require('readinknative/wallpaper').attach(app,module)
 if reader.menu then reader.menu:registerToMainMenu(module)end
 UI:nextTick(module.startTask)
 return module
end
return P
