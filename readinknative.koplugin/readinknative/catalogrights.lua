-- Catalog hints share reading's validated cache lookup. Saved display evidence
-- never grants a new download: API.prepareChapter still obtains fresh rights.
local R={}
local function key(book)return tostring(book.bookId)end
local function version(book)return tostring(book.version or 0)end
local function matching(a,book,r)
    return type(r)=='table'and r.bookId==key(book)and r.vid==a.client.data.vid and r.version==version(book)
end
function R.remember(a,book)
    local proof=book._readPermission
    a.state.catalogRights=a.state.catalogRights or{}
    if type(proof)~='table'or proof.bookId~=key(book)or proof.vid~=a.client.data.vid then
        a.state.catalogRights[key(book)]=nil;return
    end
    -- Store only the display scope and expiry, without tokens/signatures.
    a.state.catalogRights[key(book)]={bookId=key(book),vid=proof.vid,version=version(book),
        checkedAt=proof.checkedAt,accessUntil=proof.accessUntil,allowed=proof.allowed==true,reason=proof.reason}
end
function R.proof(a,book)
    local current=a.catalogPermission
    if current and current.state==a.state and current.vid==a.client.data.vid and current.bookId==key(book)and current.version==version(book)then return current.proof end
    local saved=(a.state.catalogRights or{})[key(book)]
    if matching(a,book,saved)then return saved end
end
function R.locked(a,chapter)
    local book=a.book
    if not require('readinknative/permission').catalogLocked(book,chapter,a.client.data.vid,R.proof(a,book))then return false end
    local path,mode=require('readinknative/cache').find(a.client.data.vid,book,chapter)
    return not(path and mode=='full')
end
function R.refresh(a)
    local book=a.book
    if not book or book.localFile or a.closed or a.suspended or not a.client:ready()then return end
    local now=os.time();local saved=(a.state.catalogRights or{})[key(book)]
    if matching(a,book,saved)and type(saved.checkedAt)=='number'and saved.checkedAt<=now and now<saved.checkedAt+300
        and(not saved.allowed or type(saved.accessUntil)=='number'and now<saved.accessUntil)then return end
    local previous=a.catalogRightsAttempt
    if previous and previous.state==a.state and previous.book==book and previous.at<=now and now<previous.at+60 then return end
    a.catalogRightsAttempt={state=a.state,book=book,at=now}
    require('readinknative/offline').beforeForeground(a);a.coverJobs:cancel()
    local owner={state=a.state,book=book,vid=a.client.data.vid,version=version(book)};local snapshot=a.client.data
    -- Invisible worker: show the cached catalog immediately while checking.
    a.jobs:run('',function()
        local client=require('readinknative/client'):new(snapshot)
        local ok,value=pcall(require('readinknative/api').info,client,book)
        return{ok=ok,value=ok and value or nil},client.data
    end,function(ok,result,session)
        if a.closed or a.suspended or a.state~=owner.state or a.book~=owner.book or a.client.data.vid~=owner.vid or version(book)~=owner.version then return end
        if session and a.client.data==snapshot then a.client.data=session;a.client.session.data=session;a.client:commit()end
        if not ok or not result.ok then return end
        a:updateBook(result.value);a:draw()
    end,{})
end
return R
