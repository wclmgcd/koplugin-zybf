-- Rebuild input widgets after sleep so a keyboard cannot retain old geometry.
-- The factory captures the original note/range, while draft text stays in memory.
local M={}
function M.show(app,build,draft)
    M.close(app)
    local dialog=build(draft)
    app.activeInput={dialog=dialog,build=build}
    require('readinknative/readingstats').update(app);require('readinknative/readingstats').schedule(app)
    local original=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget,...)
        if app.activeInput and app.activeInput.dialog==widget then
            app.activeInput=nil;require('readinknative/readingstats').update(app);require('readinknative/readingstats').schedule(app)
        end
        if original then return original(widget,...)end
    end
    local UI=require('ui/uimanager');UI:show(dialog);dialog:onShowKeyboard()
    -- A key highlight requires a painted FrameContainer.dimen, including on wake.
    if UI.forceRePaint then UI:forceRePaint()end
    return dialog
end
function M.close(app,retain)
    app.inputGeneration=(app.inputGeneration or 0)+1
    local active=app.activeInput
    if not retain then app.resumeInput=nil end
    if not active then return end
    if retain then app.resumeInput={build=active.build,text=active.dialog:getInputText()}end
    app.activeInput=nil
    require('ui/uimanager'):close(active.dialog)
end
function M.resume(app)
    local saved=app.resumeInput
    if not saved then return end
    local UI=require('ui/uimanager');local generation=app.inputGeneration
    app.inputResumeTask=function()
        app.inputResumeTask=nil
        if not app.closed and not app.suspended and not app.activeInput and app.inputGeneration==generation and app.resumeInput==saved then M.show(app,saved.build,saved.text)end
    end
    UI:nextTick(app.inputResumeTask)
end
return M
