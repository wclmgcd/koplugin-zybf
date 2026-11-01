-- Record actions and secondary settings use KOReader dialogs. This
-- module contains no network or account-write behavior.
local UI=require('ui/uimanager');local R={}
function R.menu(title,items)
    local menu
    menu=require('ui/widget/menu'):new{title=title,item_table=items,
        width=require('device').screen:getWidth(),height=require('device').screen:getHeight(),
        onMenuSelect=function(_,item)UI:close(menu);if item.callback then item.callback()end end,
        close_callback=function()UI:close(menu)end}
    UI:show(menu);return menu
end
function R.extraFormat(app)
    local dialog
    local function modify(key,delta)
        local f=app.state:format(app.book);app:changeFormat{[key]=f[key]+delta}
    end
    dialog=require('ui/widget/buttondialog'):new{title='其他排版选项',buttons={
        {{text='上下留白 −',callback=function()modify('vertical',-4)end},{text='上下留白 ＋',callback=function()modify('vertical',4)end}},
        {{text='切换横屏双栏',callback=function()app:changeFormat{columns=not app.state:format(app.book).columns}end}},
        {{text='恢复默认',callback=function()app:resetFormat();UI:close(dialog);app:draw()end}},
        {{text='完成',callback=function()UI:close(dialog)end}}}}
    UI:show(dialog)
end
function R.annotation(app,record)if record.cloud then if record.kind=='highlight'then return require('readinknative/cloudjump').open(app,record)end;return require('readinknative/social').openCloud(app,record)end;return require('readinknative/actionpages').record(app,record)end
function R.cache(app)return require('readinknative/actionpages').cache(app)end
return R
