-- Official /review/comment contract. Only the explicit publish action writes.
-- A durable sending receipt turns retries after interruption into readback.
local M={}
local function path(state)return state.root..'/comment-publish.json'end
function M.load(state)
    local f=io.open(path(state),'rb');if not f then return end
    local s=f:read(32769);f:close();if not s or #s>32768 then return end
    local ok,v=pcall(require('rapidjson').decode,s)
    if ok and type(v)=='table'and v.schema==1 then return v end
end
function M.save(state,op)
    op.schema=1;local data=require('rapidjson').encode(op);assert(#data<=32768,'THOUGHT_DRAFT_WRITE_FAILED')
    local f=assert(io.open(path(state)..'.part','wb'),'THOUGHT_DRAFT_WRITE_FAILED')
    assert(f:write(data));assert(f:close());assert(os.rename(path(state)..'.part',path(state)))
end
local function id(v)return type(v)=='string'and #v>0 and #v<=160 and v:match('^[A-Za-z0-9_%-]+$')end
function M.payload(op)
    assert(id(op.reviewId),'SOCIAL_ID_INVALID')
    local s=op.text
    assert(type(s)=='string'and #s<=4000 and s:find('%S')and not s:find('%z')and require('util').fixUtf8(s,'')==s,'COMMENT_TEXT_INVALID')
    -- Android String.length() counts UTF-16 units, including emoji pairs.
    local _,continuations=s:gsub('[\128-\191]','');local _,pairs=s:gsub('[\240-\244]','')
    assert(#s-continuations+pairs<=1000,'COMMENT_TEXT_INVALID')
    local body={reviewId=op.reviewId,content=s}
    if op.toCommentId then
        assert(id(op.toCommentId)and tostring(op.toUserVid):match('^%d+$')and tonumber(op.toUserVid)>0 and tonumber(op.toUserVid)<=2147483647,'SOCIAL_ID_INVALID')
        body.toCommentId=op.toCommentId;body.toUserVid=tonumber(op.toUserVid)
    end
    return body
end
local function same(x,y)
    return x and x.operation==y.operation and tostring(x.vid)==tostring(y.vid)and x.reviewId==y.reviewId and x.text==y.text and x.toCommentId==y.toCommentId
end
function M.reconcile(client,op)
    local data=require('readinknative/socialapi').detail(client,op.reviewId,op.bookId)
    local found
    for _,row in ipairs(data.comments)do
        if row.author.vid==tostring(op.vid)and row.content==op.text and row.toCommentId==op.toCommentId
            and row.created and row.created>=op.started-2 and not(op.before and op.before[row.commentId])then
            if found then return{unknown=true}end;found=row
        end
    end
    if found then op.phase='confirmed';op.commentId=found.commentId;return{confirmed=true,data=data,row=found}end
    return{unknown=true,data=data}
end
function M.process(client,state,op)
    assert(tostring(client.data.vid)==tostring(op.vid),'INVALID_ACCOUNT')
    local saved=M.load(state)
    if same(saved,op)and(saved.phase=='sending'or saved.phase=='confirmed')then op=saved end
    if op.phase=='confirmed'then return{confirmed=true}end
    if op.phase=='sending'then local value=M.reconcile(client,op);if value.confirmed then M.save(state,op)end;return value end
    assert(op.phase=='draft'or op.phase=='rejected','COMMENT_OUTCOME_UNKNOWN')
    local body=M.payload(op);op.phase='sending';M.save(state,op)
    client.write_path='/review/comment'
    local ok,reply=pcall(client.api,client,'/review/comment',nil,body);client.write_path=nil
    if not ok then
        if client.write_state=='unsent'or client.write_state=='rejected'or tostring(reply):find('API_',1,true)then op.phase='rejected';M.save(state,op);return{rejected=true}end
        return{unknown=true}
    end
    local cid=type(reply)=='table'and reply.commentId and tostring(reply.commentId)
    local target=type(reply)=='table'and reply.toCommentId and tostring(reply.toCommentId)
    if target==''or target=='0'then target=nil end
    local author=type(reply)=='table'and type(reply.author)=='table'and(reply.author.userVid or reply.author.vid)
    if not id(cid)or reply.reviewId and tostring(reply.reviewId)~=op.reviewId
        or reply.content and reply.content~=op.text or target~=op.toCommentId
        or author and tostring(author)~=tostring(op.vid)then return{unknown=true}end
    op.phase='confirmed';op.commentId=cid;M.save(state,op)
    return{confirmed=true,row=require('readinknative/socialapi').comment(reply,op.reviewId)}
end
local function owner(a,c,r)return require('readinknative/social').valid(a,c,r)and r.kind=='detail'end
local function busy(a,r)
    if r.commentSending and r.commentEpoch==a.jobs.epoch and a.jobs.widget then return true end
    r.commentSending=nil
end
function M.send(a,c,r,op)
    if not owner(a,c,r)or busy(a,r)then return end
    r.commentSending=true;local state=a.state
    local result=require('readinknative/social').run(a,c,r,op.phase=='sending'and'核对评论结果'or'发表评论',function(client)return M.process(client,state,op)end,function(result)
        r.commentSending=nil
        if not result.ok then a:message('评论未完成，草稿已保留。');return end
        local value=result.value
        if value.confirmed then
            r.expandedComment=nil;r.tab='comments';r.page=1
            if value.data then r.data=value.data
            elseif r.data and value.row then
                r.data.comments=require('readinknative/socialapi').merge({value.row},r.data.comments,'commentId')
                r.data.review.commentsCount=nil
            end
            local social=require('readinknative/social')
            local review=r.data and r.data.review or r.row
            if review then
                local updated={};for k,v in pairs(review)do updated[k]=v end
                if not value.data then updated.commentsCount=nil end
                social.updateReview(a,c,updated)
                r.row=updated;if r.data then r.data.review=updated end
            end
            social.fetchDetail(a);a:message('评论已发表。')
        elseif value.unknown then a:message('评论结果尚未确认，草稿已保留。再次点评论将核对结果，不会重复发表。')
        else a:message('评论未发表，草稿已保留，可重试。')end
    end)
    if r.commentSending then r.commentEpoch=a.jobs.epoch end
    return result
end
function M.compose(a,target)
    local social=require('readinknative/social');local c=social.context(a);local r=c.route
    if not owner(a,c,r)or busy(a,r)then return end
    if not a.client:ready()then a:message('请先登录微信读书。');return end
    local row=r.data and r.data.review or r.row;if not row or not id(row.reviewId)then return end
    if target then
        local owned=false;for _,v in ipairs(r.data and r.data.comments or{})do if v==target then owned=true end end
        if not owned or not target.author.vid then return end
    end
    local old=M.load(a.state)
    if old and old.phase=='sending'then
        if tostring(old.vid)~=tostring(c.vid)or old.reviewId~=row.reviewId then a:message('上一条评论结果尚未确认，请返回原想法核对。');return end
        return M.send(a,c,r,old)
    end
    local op={vid=tostring(c.vid),reviewId=row.reviewId,bookId=row.bookId or c.bookId,text='',phase='draft',before={},operation=tostring(os.time())..':'..tostring(require('ui/time').monotonic())}
    if target then op.toCommentId=target.commentId;op.toUserVid=target.author.vid end
    if old and(old.phase=='draft'or old.phase=='rejected')and tostring(old.vid)==op.vid and old.reviewId==op.reviewId and old.toCommentId==op.toCommentId then op=old end
    op.before=op.before or{}
    for i,v in ipairs(r.data and r.data.comments or{})do if i>100 then break end;op.before[v.commentId]=true end
    local function build(draft)
        if draft then op.text=draft end
        local d;local submitted=false
        d=require('readinknative/officialinput'):new{app=a,input=op.text,official={kind='comment',quote=target and('回复 '..target.author.name..'：'..target.content)or row.content,
            submit=function(value)
                if not owner(a,c,r)then require('ui/uimanager'):close(d);return end
                op.text=value:match('^%s*(.-)%s*$')
                if not pcall(M.payload,op)then a:message('请输入评论，最多 1000 字。');return end
                submitted=true;op.phase='draft';op.started=os.time();M.save(a.state,op);require('ui/uimanager'):close(d);M.send(a,c,r,op)
            end}}
        local onClose=d.onCloseWidget
        d.onCloseWidget=function(widget,...)
            if not submitted and owner(a,c,r)and(op.phase=='draft'or op.phase=='rejected')then
                op.text=d:getInputText();if not pcall(M.save,a.state,op)then a:message('评论草稿未能保存，请检查文字长度和存储空间。')end
            end
            if onClose then return onClose(widget,...)end
        end
        return d
    end
    return require('readinknative/input').show(a,build,op.text)
end
return M
