-- Speculative first/last body frame for short illustrated chapters. Never
-- fetch, wait on a turn, retain a second UI DOM, or alter the source images.
local P={MAX_FILE=2*1024*1024,MAX_FRAME=4*1024*1024,MIN_FREE=160*1024*1024,MAX_WORDS=1500}
function P.stop(a,drop)
    if a.chapterPreviewTask then require('ui/uimanager'):unschedule(a.chapterPreviewTask);a.chapterPreviewTask=nil end
    if a.chapterPreviewJobs then a.chapterPreviewJobs:cancel()end
    a.chapterPreview=nil
    if drop then a.chapterPreviewCache=nil end
end
local function same(a,o)
    return not a.closed and not a.suspended and a.mode=='reader'and a.state==o.state and a.book==o.book
        and tostring(a.client.data.vid)==o.vid and a.document==o.document and o.document.doc
        and not a.toolbar and not a.panel and not a.activeInput and not a.textSelection
end
local function stamp(path)return require('readinknative/pagination').fileStamp(path)end
local function signature(a,path)
    local b=a.view.layout.body
    return require('readinknative/chapterloader').spec(a.client.data.vid,a.book,path,b.w,b.h,a.state.font,a.state:format(a.book))
end
function P.request(a,book,chapter,path,kind)
    if kind~='next'or a.pagePreloadEnabled==false or not a.document or not a.document.doc or a.document.window or book.localFile or book.article then return end
    local words=tonumber(chapter.wordCount);local current=a.chapter and tonumber(a.chapter.wordCount)
    local d=a.document;local size=require('libs/libkoreader-lfs').attributes(path,'size')
    -- This exception to single-reader preparation is deliberately small. The
    -- fork inherits a short illustrated DOM; it opens only one bounded neighbor.
    if d.format.view_mode==1 or not words or words<0 or words>P.MAX_WORDS or not current or current<0 or current>P.MAX_WORDS
        or d:count()>12 or(d.doc._drawn_images_count or 0)==0 or not size or size>P.MAX_FILE
        or d.w*d.h*(d.doc.render_color and 4 or 1)>P.MAX_FRAME then return end
    local s=signature(a,path);local direction=a.readingDirection==-1 and -1 or 1
    local key=s.key..':'..direction..':'..tostring(require('device').screen.night_mode)..':'..tostring(require('device').screen.sw_dithering)
    local ready=a.chapterPreviewCache
    if ready and ready.state==a.state and ready.book==book and ready.key==key and ready.stamp==stamp(path)then return end
    if a.chapterPreview and a.chapterPreview.key==key then return end
    P.stop(a);a.chapterPreviewCache=nil
    local o={key=key,spec=s,path=path,stamp=stamp(path),state=a.state,book=book,chapter=chapter,
        document=d,vid=tostring(a.client.data.vid),direction=direction,attempts=0}
    a.chapterPreview=o
    local UI=require('ui/uimanager')
    local function start()
        a.chapterPreviewTask=nil
        if a.chapterPreview~=o or not same(a,o)then if a.chapterPreview==o then a.chapterPreview=nil end;return end
        local free=require('util').calcFreeMem()
        if not free or free<P.MIN_FREE then a.chapterPreview=nil;return end
        if a.windowBuilding or a.chapterLoading or(a.offlineRuntime and a.offlineRuntime.busy)
            or a.pagePreload or a.jobs.widget or require('readinknative/socialreader').busy(a)
            or require('readinknative/underlinenext').busy(a)then
            o.attempts=o.attempts+1
            if o.attempts<10 then a.chapterPreviewTask=start;UI:scheduleIn(0.3,start)else a.chapterPreview=nil end
            return
        end
        if require('readinknative/cache').find(o.vid,book,chapter)~=path or stamp(path)~=o.stamp
            or not require('readinknative/images').ready(path)or signature(a,path).key~=s.key then a.chapterPreview=nil;return end
        a.chapterPreviewJobs=a.chapterPreviewJobs or require('readinknative/inkjobs').new{NICE=15,TIMEOUT=12}
        a.chapterPreviewJobs:run('',function()
            local doc=require('readinknative/document').open(path,s.w,s.h,s.format.size,nil,s.format,'prepare')
            require('readinknative/chapterloader').track(doc,s)
            local ok,result=pcall(function()
                doc:edge(direction<0 and'end'or'start')
                local BB=require('ffi/blitbuffer');local b=BB.new(s.w,s.h,BB.TYPE_BB8)
                local drawn,err=pcall(doc.paint,doc,b,0,0);b:free();assert(drawn,err)
                local buffer=assert(doc.doc.buffer);local bytes=tonumber(buffer.stride)*tonumber(buffer.h)
                assert(bytes<=P.MAX_FRAME,'FRAME_SIZE')
                return{w=tonumber(buffer.w),h=tonumber(buffer.h),stride=tonumber(buffer.stride),kind=buffer:getType(),
                    rotation=buffer:getRotation(),inverse=buffer:getInverse(),data=BB.tostring(buffer),frameKey=doc:frameKey(),
                    images=doc.doc._drawn_images_count,surface=doc.doc._drawn_images_surface_ratio}
            end)
            doc:close();assert(ok,result);return result
        end,function(ok,result)
            if a.chapterPreview~=o then return end;a.chapterPreview=nil
            if not ok or not same(a,o)or stamp(path)~=o.stamp or signature(a,path).key~=s.key then return end
            a.chapterPreviewCache={key=o.key,spec=s,path=path,stamp=o.stamp,state=o.state,book=book,chapter=chapter,vid=o.vid,frame=result}
            require('logger').info('ReadInk short illustrated chapter frame ready')
        end,false)
    end
    a.chapterPreviewTask=start;UI:scheduleIn(0.35,start)
end
function P.apply(a,d)
    local o=a.chapterPreviewCache;if not o then return end
    a.chapterPreviewCache=nil
    local buffer
    local ok=pcall(function()
    local free=require('util').calcFreeMem();if not free or free<48*1024*1024 then return end
    if d.window or o.state~=a.state or o.book~=a.book or o.vid~=tostring(a.client.data.vid)or d.path~=o.path
        or stamp(d.path)~=o.stamp or signature(a,d.path).key~=o.spec.key
        or require('readinknative/cache').find(o.vid,a.book,o.chapter)~=d.path then return end
    local r=o.frame;local BB=require('ffi/blitbuffer')
    if type(r)~='table'or r.w~=d.w or r.h~=d.h or r.frameKey~=d:frameKey()or type(r.data)~='string'
        or #r.data>P.MAX_FRAME or type(r.stride)~='number'or r.stride<=0 or #r.data~=r.stride*r.h then return end
    local bpp=BB.TYPE_TO_BPP[tonumber(r.kind)]
    if not bpp or r.stride<math.ceil(r.w*bpp/8)or type(r.rotation)~='number'or r.rotation<0 or r.rotation>3
        or(r.inverse~=0 and r.inverse~=1)then return end
    buffer=BB.fromstring(r.w,r.h,r.kind,r.data,r.stride,r.rotation,r.inverse)
    d:cacheFrame(r.frameKey,buffer,r.images,r.surface)
    require('logger').info('ReadInk short illustrated chapter frame reused')
    end)
    if buffer then pcall(buffer.free,buffer)end
    if not ok then require('logger').info('ReadInk short illustrated chapter frame skipped')end
end
return P
