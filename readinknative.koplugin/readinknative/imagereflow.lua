-- A completed image repair can require reopening CRe's archive. Never do
-- that from an arbitrary draw or a page-turn callback; wait for settled UI.
local R={DELAY=0.75}
function R.stop(a)
 if a.imageReflowTask then require('ui/uimanager'):unschedule(a.imageReflowTask);a.imageReflowTask=nil end
end
function R.request(a)
 R.stop(a)
 local d=a.document
 if not d or a.pendingImageReload~=d or a.mode~='reader'or a.closed or a.suspended then return end
 local state,book,chapter,path,key=a.state,a.book,a.chapter,d.path,d:frameKey()
 a.imageReflowTask=function()
  a.imageReflowTask=nil
  if a.closed or a.suspended or a.state~=state or a.book~=book or a.chapter~=chapter or a.document~=d or not d.doc or d.path~=path or d:frameKey()~=key or a.mode~='reader'or a.pendingImageReload~=d then return end
  if a.resumeSettling or a.activeInput or a.textSelection or a.toolbar or a.panel or a.readerOverlay or a.footnote or a.chapterLoading or a.view and a.view.scrollDrag then return end
  require('readinknative/pagepreload').stop(a);require('readinknative/chapterwindow').stop(a)
  require('readinknative/socialreader').cancel(a);require('readinknative/offline').beforeDocument(a)
  a.pendingImageReload=nil
  local ok,err=pcall(d.reloadImages,d)
  if not ok then a.document=nil;a.mode='catalog';a:failure(err)
  else
   pcall(require('readinknative/pagination').request,a)
   require('readinknative/socialreader').start(a,true)
  end
  a:draw()
 end
 require('ui/uimanager'):scheduleIn(R.DELAY,a.imageReflowTask)
end
return R
