-- A selection belongs to one live document, account state and chapter.
local T={}
function T.current(app)
    local s=app.textSelection
    if s and s.document==app.document and s.state==app.state and s.book==app.book and s.chapter==app.chapter then return s end
end
function T.clear(app)
    app.textSelection=nil
    if app.document and app.document.clearSelection then app.document:clearSelection()end
end
function T.begin(app,point)
    T.clear(app)
    if app.closed or app.suspended or app.mode~='reader' or app.panel or not app.document then return false end
    local range=app.document:selectRange(point,point)
    if not range then return false end
    app.toolbar=false
    app.textSelection={document=app.document,state=app.state,book=app.book,chapter=app.chapter,anchor=point,range=range,dragging=true}
    app:draw();return true
end
function T.move(app,point)
    local s=T.current(app);if not s or not s.dragging then return false end
    local range=app.document:selectRange(s.anchor,point)
    if range then s.range=range;app:draw()end
    return true
end
function T.finish(app)
    local s=T.current(app);if not s then return false end
    s.dragging=false;app:draw();return true
end
function T.copy(app)
    local s=T.current(app);if not s then return end
    local input=require('device').input
    if not input or not input.setClipboardText then app:message('本机暂不支持剪贴板。');return end
    input.setClipboardText(s.range.text);T.clear(app);app:draw();app:message('已复制选中原文。')
end
function T.lookup(app)
    local s=T.current(app);if not s then return end
    if #s.range.text>512 then app:message('请选择较短的词句查词。');return end
    local dictionary=app.host and app.host.dictionary
    if not dictionary or not dictionary.onLookupWord then app:message('当前宿主没有可用词典，请从 KOReader 文件管理器打开 ReadInk。');return end
    local text=s.range.text;T.clear(app);app:draw()
    local ok,err=pcall(dictionary.onLookupWord,dictionary,text,true)
    if not ok then app:message('词典查询未完成，请检查 KOReader 词典设置。')end
end
function T.position(range)
    return {xpointer=range.pos0,endXPointer=range.pos1,page=range.page}
end
function T.highlight(app)
    local s=T.current(app);if not s then return end
    -- Tapping twice on an unchanged range should not create duplicate records.
    local A=require('readinknative/annotations');local uid=s.chapter and tostring(s.chapter.chapterUid)or nil
    for _,row in ipairs(A.list(app.state,app.book.bookId,'highlight'))do
        if row.chapterUid==uid and row.position.xpointer==s.range.pos0 and row.position.endXPointer==s.range.pos1 then
            T.clear(app);app:draw();return row
        end
    end
    local row=A.add(app.state,app.book,app.chapter,'highlight',T.position(s.range),s.range.text)
    app.state:flush();T.clear(app);require('readinknative/annotationsync').changed(app);app:draw();return row
end
function T.note(app)
    local s=T.current(app);if not s then return end
    local selected={position=T.position(s.range),quote=s.range.text,chapter=s.chapter}
    T.clear(app);app:draw();return app:editNote(nil,selected)
end
return T
