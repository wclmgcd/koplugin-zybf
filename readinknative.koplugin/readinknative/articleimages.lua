-- Article text is readable before optional images finish. Repair and CRe warmup
-- run in a silent, cancellable worker; apply only to the same idle reader.
local M={RETRY=300}
local function same(a,t)
 return not a.closed and not a.suspended and a.articleImageTask==t and a.state==t.state and a.book==t.book
  and a.client.data.vid==t.vid and a.document==t.document and a.document and a.document.path==t.path
end
function M.cancel(a)
 if a.articleImageApply then require('ui/uimanager'):unschedule(a.articleImageApply);a.articleImageApply=nil end
 a.articleImageTask=nil
 if a.articleImageJobs then a.articleImageJobs:cancel()end
end
function M.input(a)
 if a.articleImageTask then a.articleImageTask.idleAfter=require('ui/time').monotonic()+require('ui/time').s(1)end
end
local function apply(a,t)
 if not same(a,t)then return end
 if a.mode~='reader'then M.cancel(a);return end
 local UI=require('ui/uimanager');local clock=require('ui/time')
 if a.toolbar or a.panel or a.textSelection or a.jobs.widget or a.chapterLoading or clock.monotonic()<(t.idleAfter or 0)then
  a.articleImageApply=function()a.articleImageApply=nil;apply(a,t)end;UI:scheduleIn(0.3,a.articleImageApply);return
 end
 a.articleImageTask=nil;a:savePosition();a.document:close();a.document=nil
 a:openDocument(t.path)
 require('logger').info('ReadInk article images applied to idle reader')
end
function M.start(a,row,record)
 M.cancel(a)
 if not a.document or not a.book or not a.book.article or not record.images or(record.images.complete or record.images.missing==0)
  or not a.client:ready()or os.time()-(record.imagesAttemptAt or 0)<M.RETRY then return end
 local doc=a.document;local t={state=a.state,book=a.book,document=doc,vid=a.client.data.vid,path=doc.path,
  idleAfter=require('ui/time').monotonic()+require('ui/time').s(1)};a.articleImageTask=t
 local w,h,font,format=doc.w,doc.h,doc.font,doc.format
 a.articleImageJobs=a.articleImageJobs or require('readinknative/jobs').new()
 a.articleImageJobs:run('',function()
  -- These are fork-local engine references. Close them before replacing the
  -- source/provider file; the parent's current text remains open and usable.
  doc:close();require('readinknative/resident').drop(a)
  local result=require('readinknative/articlecontent').repair(t.vid,row)
  if result.meta.images and result.meta.images.changed then
   local D=require('readinknative/document');local L=require('readinknative/chapterloader')
   local warmed=D.open(t.path,w,h,font,nil,format,'article-images-prepare',true)
   L.track(warmed,L.spec(t.vid,t.book,t.path,w,h,font,format));warmed:close()
  end
  return result
 end,function(ok,result)
  if not same(a,t)then return end
  if not ok then a.articleImageTask=nil;require('logger').warn('ReadInk article image repair failed:',require('readinknative/errors').code(result));return end
  local images=result.meta and result.meta.images
  require('logger').info('ReadInk article image repair complete/missing:',images and images.complete,images and images.missing)
  if not(images and images.changed)then a.articleImageTask=nil;return end
  apply(a,t)
 end,false)
end
return M
