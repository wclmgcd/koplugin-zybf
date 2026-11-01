-- Render the adjacent body in a cancellable fork of the current DOM. Never
-- advance the visible document or hold a second native document in the UI.
local P={MAX_FRAME=4*1024*1024}
function P.stop(a)
 if a.pagePreloadTask then require('ui/uimanager'):unschedule(a.pagePreloadTask);a.pagePreloadTask=nil end
 if a.pagePreloadJobs then a.pagePreloadJobs:cancel()end;a.pagePreload=nil
end
local function valid(a,o)
 return not a.closed and not a.suspended and a.mode=='reader'and not a.toolbar and not a.panel and not a.activeInput and not a.textSelection and not a.readerOverlay and not a.footnote and not a.quickMenu
  and a.document==o.doc and o.doc.doc and a.state==o.state and o.doc.path==o.path and o.doc:page()==o.page and o.doc.format==o.format
  and o.doc.frameGeneration==o.generation and o.doc:frameKey(o.target)==o.key
end
function P.request(a)
 if not(a.pagePreloadEnabled or require('device'):isKindle())or a.pagePreloadEnabled==false or not a.document then return end
 local d=a.document;if d.isScroll and d:isScroll()then return end
 local target=d:page()+(a.readingDirection==-1 and -1 or 1)
 if d.w*d.h*(d.doc.render_color and 4 or 1)>P.MAX_FRAME then return end
 if target<1 or target>d:count()then return end
 local o={doc=d,state=a.state,path=d.path,page=d:page(),target=target,format=d.format,generation=d.frameGeneration,key=d:frameKey(target)}
 if not valid(a,o)or d:hasFrame(o.key)then return end
 if a.pagePreload and a.pagePreload.key==o.key and a.pagePreload.doc==d then return end
 P.stop(a);a.pagePreload=o
 a.pagePreloadTask=function()
  a.pagePreloadTask=nil
  if not valid(a,o)then a.pagePreload=nil;return end
  local free=require('util').calcFreeMem()
  if not free or free<48*1024*1024 or a.windowBuilding or a.chapterLoading or(a.offlineRuntime and a.offlineRuntime.busy)or require('readinknative/socialreader').busy(a)then a.pagePreload=nil;return end
  a.pagePreloadJobs=a.pagePreloadJobs or require('readinknative/inkjobs').new{NICE=10,TIMEOUT=12}
  a.pagePreloadJobs:run('',function()
   d:jump(target)
   local BB=require('ffi/blitbuffer');local targetBuffer=BB.new(d.w,d.h,BB.TYPE_BB8)
   d.doc:drawCurrentView(targetBuffer,0,0,require('ui/geometry'):new{w=d.w,h=d.h});targetBuffer:free()
   local b=assert(d.doc.buffer);assert(tonumber(b.stride)*tonumber(b.h)<=P.MAX_FRAME,'FRAME_SIZE')
   return{w=tonumber(b.w),h=tonumber(b.h),stride=tonumber(b.stride),kind=b:getType(),rotation=b:getRotation(),inverse=b:getInverse(),data=BB.tostring(b),
    images=d.doc._drawn_images_count,surface=d.doc._drawn_images_surface_ratio}
  end,function(ok,r)
   if a.pagePreload~=o then return end;a.pagePreload=nil
   if not ok or not valid(a,o)or type(r)~='table'or type(r.data)~='string'or #r.data>P.MAX_FRAME or r.w~=d.w or r.h~=d.h or type(r.stride)~='number'or r.stride<=0 or #r.data~=r.stride*r.h then return end
   local BB=require('ffi/blitbuffer');local bpp=BB.TYPE_TO_BPP[tonumber(r.kind)]
   if not bpp or r.stride<math.ceil(r.w*bpp/8)or type(r.rotation)~='number'or r.rotation<0 or r.rotation>3 or(r.inverse~=0 and r.inverse~=1)then return end
   local buffer=BB.fromstring(r.w,r.h,r.kind,r.data,r.stride,r.rotation,r.inverse)
   d:cacheFrame(o.key,buffer,r.images,r.surface);buffer:free()
  end,false)
 end
 require('ui/uimanager'):scheduleIn(0.35,a.pagePreloadTask)
end
return P
