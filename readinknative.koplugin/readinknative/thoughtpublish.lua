-- Explicit user publication; durable receipt prevents blind replay after cancel.
local M={choices={{'公开','所有人可见'},{'关注','仅互相关注可见'},{'私密','仅自己可见'},{'屏蔽好友','仅未关注你的人可见'}}}
local function file(state)return state.root..'/thought-publish.json'end
function M.load(state)
 local f=io.open(file(state),'rb');if not f then return end;local raw=f:read(150001);f:close();if #raw>150000 then return end
 local ok,r=pcall(require('rapidjson').decode,raw);if ok and type(r)=='table'and r.schema==1 then return r end
end
function M.save(state,r)
 r.schema=1;local path=file(state);local f=assert(io.open(path..'.part','wb'),'THOUGHT_DRAFT_WRITE_FAILED')
 assert(f:write(require('rapidjson').encode(r)));assert(f:close());assert(os.rename(path..'.part',path));return r
end
function M.flags(choice)
 assert(type(choice)=='number'and choice%1==0 and choice>=1 and choice<=4,'THOUGHT_VISIBILITY_INVALID')
 return{isPrivate=choice==3 and 1 or 0,friendship=choice==2 and 1 or 0,notVisibleToFriends=choice==4 and 1 or 0}
end
function M.payload(op)
 local uid,version=tonumber(op.chapter.chapterUid),tonumber(op.book.version)
 local left,right
 if type(op.range)=='string'then left,right=op.range:match('^(%d+)%-(%d+)$')end
 assert(uid and uid>=0 and uid%1==0 and version and version>=0 and version%1==0,'ANNOTATION_SYNC_METADATA_INVALID')
 assert(left and right and tonumber(right)>tonumber(left)and tonumber(right)<=2*1024*1024,'ANNOTATION_SYNC_RANGE_INVALID')
 assert(type(op.text)=='string'and op.text:find('%S')and #op.text<=65536 and require('util').fixUtf8(op.text,'')==op.text,'THOUGHT_TEXT_INVALID')
 assert(type(op.quote)=='string'and #op.quote>0 and #op.quote<=65536,'THOUGHT_TEXT_INVALID')
 local value=M.flags(op.visibility)
 for k,v in pairs{bookId=tostring(op.book.bookId),bookVersion=version,chapterUid=uid,content=op.text,range=op.range,
  abstract=op.quote,contextAbstract=op.quote,type=1,translateMode='',htmlContent='',title=''}do value[k]=v end
 -- Encode a genuinely empty JSON array, not a Lua table encoded as {}.
 value.atUserVids=require('rapidjson').decode('[]')
 return value
end
function M.matches(r,op)
 local f=M.flags(op.visibility)
 return r.userVid==tostring(op.vid)and r.bookId==tostring(op.book.bookId)and r.chapterUid==tostring(op.chapter.chapterUid)
  and r.range==op.range and r.content==op.text and r.private==(f.isPrivate==1)
  and r.friendship==(f.friendship==1)and r.notVisibleToFriends==(f.notVisibleToFriends==1)
  and r.created and r.created>=op.started-300 and(not r.bookVersion or tostring(r.bookVersion)==tostring(op.book.version))
end
function M.reconcile(client,op)
 local snapshot=require('readinknative/socialapi').mine(client,op.book);local found
 for _,r in ipairs(snapshot.rows)do if M.matches(r,op)then if found then return end;found=r end end
 return found
end
function M.process(client,state,op,path)
 assert(tostring(client.data.vid)==tostring(op.vid),'INVALID_ACCOUNT')
 if op.phase=='sending'then
  local row=M.reconcile(client,op)
  if row then op.phase='confirmed';op.reviewId=row.reviewId;M.save(state,op);return{confirmed=true,row=row}end
  return{unknown=true}
 end
 assert(op.phase=='draft'or op.phase=='rejected','THOUGHT_OUTCOME_UNKNOWN')
 -- Validate the quote against the authorized original, outside the UI thread.
 local mapped=require('readinknative/annotationsync').map({book=op.book,chapter=op.chapter,quote=op.quote,sourceRange=op.range,sourceVersion=op.book.version},client,path)
 assert(mapped==op.range,'ANNOTATION_SYNC_RANGE_UNMATCHED')
 local body=M.payload(op);op.phase='sending';M.save(state,op)
 client.write_path='/review/add';local ok,response=pcall(client.api,client,'/review/add',nil,body);client.write_path=nil
 if not ok then
  if client.write_state=='unsent'or client.write_state=='rejected'or tostring(response):find('API_',1,true)then op.phase='rejected';M.save(state,op);return{rejected=true}end
  return{unknown=true}
 end
 -- The official endpoint returns Review (not the rich-list wrapper).
 local rid=type(response)=='table'and response.reviewId
 if type(rid)~='string'or not rid:match('^[A-Za-z0-9_%-]+$')or #rid>160 then return{unknown=true}end
 if response.bookId and tostring(response.bookId)~=tostring(op.book.bookId)then return{unknown=true}end
 if response.userVid and tostring(response.userVid)~=tostring(op.vid)then return{unknown=true}end
 if response.range and response.range~=op.range then return{unknown=true}end
 for _,key in ipairs{'isPrivate','friendship','notVisibleToFriends'}do
  if response[key]~=nil and tonumber(response[key])~=body[key]and response[key]~=(body[key]==1)then return{unknown=true}end
 end
 if response.content and response.content~=op.text or response.chapterUid and tostring(response.chapterUid)~=tostring(op.chapter.chapterUid)then return{unknown=true}end
 op.phase='confirmed';op.reviewId=rid;M.save(state,op)
 return{confirmed=true,reviewId=rid}
end
local function owner(a,c,r)return require('readinknative/social').valid(a,c,r)and r.kind=='thoughts'end
function M.send(a,c,r,op)
 if not owner(a,c,r)then return end
 local social=require('readinknative/social');local state=a.state
 return social.run(a,c,r,op.phase=='sending'and'核对发表结果'or'发表想法',function(client)
  local path=require('readinknative/cache').find(client.data.vid,op.book,op.chapter);assert(path,'CHAPTER_FILES_MISSING')
  return M.process(client,state,op,path)
 end,function(result)
  if not result.ok then a:message('未能完成发表，草稿已保留；再次进入可核对结果。');return end
  local v=result.value
  if v.confirmed then social.cancelMine(a);social.invalidateThoughts(c,op);r.loaded=false;r.groups={};r.page=1;r.wantNext=nil;r.nextRange=2;c.mineAt=nil;social.fetchGroups(a,false);a:message('想法已发表。')
  elseif v.unknown then a:message('发表结果尚未确认。草稿已保留，再点“写想法”可核对结果，暂不重复发表。')
  else a:message('发表未成功，草稿已保留，可检查网络后重试。')end
 end)
end
function M.compose(a)
 local social=require('readinknative/social');local c=social.context(a);local r=c.route
 if not owner(a,c,r)or not r.singleRange or not r.ranges[1]or type(r.quote)~='string'then return end
 local old=M.load(a.state)
 if old and old.phase=='sending'then
  if tostring(old.vid)~=tostring(c.vid)then a:message('待确认的想法属于另一账号。');return end
  return M.send(a,c,r,old)
 end
 local book,chapter=a.book,r.chapter;local range=r.ranges[1].range
 local op={vid=tostring(c.vid),book={bookId=c.bookId,version=book.version},chapter={chapterUid=tostring(chapter.chapterUid),title=chapter.title},range=range,quote=r.quote,text='',visibility=1,phase='draft'}
 if old and(old.phase=='draft'or old.phase=='rejected')and tostring(old.vid)==op.vid and tostring(old.book.bookId)==op.book.bookId and tostring(old.book.version)==tostring(op.book.version)and old.range==range and tostring(old.chapter.chapterUid)==op.chapter.chapterUid then op=old end
 local UI=require('ui/uimanager')
 local function build(draft)
  if draft then op.text=draft end
  local dialog
  local function capture()op.text=dialog:getInputText();M.save(a.state,op)end
  dialog=require('readinknative/officialinput'):new{app=a,input=op.text,official={kind='thought',quote=op.quote,
   visibility=function()return M.choices[op.visibility][1]end,
   pickVisibility=function()
    if not owner(a,c,r)then return end;capture()
    local picker;local choices={}
    for i,choice in ipairs(M.choices)do choices[#choices+1]={{text=choice[1]..' · '..choice[2]..(op.visibility==i and' ✓'or''),callback=function()
     if not owner(a,c,r)then UI:close(picker);return end
     op.visibility=i;M.save(a.state,op);UI:close(picker);require('readinknative/input').show(a,build,op.text)
    end}}end
    picker=require('ui/widget/buttondialog'):new{title='谁可以看到',buttons=choices};UI:show(picker)
   end,
   submit=function()
    if not owner(a,c,r)then UI:close(dialog);return end
    capture();local good=pcall(M.payload,op);if not good then a:message('请输入想法，最多 64 KB。');return end
    op.started=os.time();op.phase='draft';M.save(a.state,op);UI:close(dialog);M.send(a,c,r,op)
   end}}
  local originalClose=dialog.onCloseWidget
  dialog.onCloseWidget=function(widget,...)
   if owner(a,c,r)and(op.phase=='draft'or op.phase=='rejected')then capture()end
   if originalClose then return originalClose(widget,...)end
  end
  return dialog
 end
 return require('readinknative/input').show(a,build,op.text)
end
return M
