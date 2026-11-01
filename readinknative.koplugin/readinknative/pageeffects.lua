-- Native MTK page swipe, using the same capability/API as KOReader ReaderView.
local E={}
function E.supported()
    local ok,D=pcall(require,'device')
    return ok and type(D.canDoSwipeAnimation)=='function'and D:canDoSwipeAnimation()==true
end
function E.arm(app,delta)
    if app.document and app.document.isScroll and app.document:isScroll()then app.view.pageTurnEffect=nil;return end
    if app.document then app.view.pageTurnEffect={document=app.document,page=app.document:page(),forward=delta>0}end
end
function E.consume(view,refresh)
    local pending=view.pageTurnEffect;view.pageTurnEffect=nil
    if not pending then return end
    local a=view.app
    if not a or a.closed or a.suspended or a.mode~='reader'or a.toolbar or a.panel or a.quickMenu or a.activeInput or a.textSelection
        or a.document~=pending.document or a.document:page()~=pending.page or refresh~='partial' then return end
    if not require('readinknative/preferences').normalize(a.state.preferences).pageTurnEffect or not E.supported()then return end
    local screen=require('device').screen
    screen:setSwipeDirection(pending.forward);screen:setSwipeAnimations(true)
end
return E
