-- Explicit official cloud shelf changes. Persist uncertain outcomes and verify
-- a full snapshot; never turn a local hidden flag into a privacy confirmation.
local M={}
local function eligible(a)
 local rows={};for _,b in ipairs(require('readinknative/shelfmodel').selected(a))do if not b.localFile then rows[#rows+1]=b end end;return rows
end
function M.toPrivate(a)
 for _,b in ipairs(eligible(a))do if b.secret~=1 then return true end end;return false
end
local function alive(a,o)return not a.closed and not a.suspended and a.state==o.state and a.client.data.vid==o.vid end
local function matches(snapshot,op)
 local byId={};for _,b in ipairs(snapshot.books)do byId[b.bookId]=b end
 for _,id in ipairs(op.ids)do
  local b=byId[id];if not b then return false end
  if op.kind=='private'and b.secret~=op.value then return false end
 end;return true
end
function M.request(client,op)
 local J=require('rapidjson');local response
 if op.kind=='private'then
  client.write_path='/book/secret';client.write_state='unsent'
  response=client:api('/book/secret',nil,{bookIds=op.ids,albumIds=J.array(),private=op.value})
 else error('SHELF_ACTION_INVALID')end
 if type(response)=='table'and(response.succ==0 or response.succ==false)then client.write_state='rejected'end
 assert(type(response)=='table'and(response.succ==1 or response.succ==true),'SHELF_ACTION_REJECTED')
end
local function run(a,op,readOnly)
 local o={state=a.state,vid=a.client.data.vid};a.shelfOperation=o
 a:remote(readOnly and'核对书架状态'or op.kind=='private'and'更新私密阅读'or'更新书籍分组',function(c)
  local ok,err=true
  if not readOnly then ok,err=pcall(M.request,c,op)end
  local got,snapshot=pcall(require('readinknative/api').shelfSnapshot,c)
  return{wrote=ok,error=not ok and require('readinknative/errors').code(err)or nil,rejected=not ok and c.write_state=='rejected',snapshot=got and snapshot or nil}
 end,function(r)
  if a.shelfOperation==o then a.shelfOperation=nil end
  if not alive(a,o)then return end
  local confirmed=r.snapshot and matches(r.snapshot,op)
  if r.snapshot then require('readinknative/shelfmodel').apply(a,r.snapshot)end
  if confirmed or r.rejected or readOnly and r.snapshot then a.state.shelfMutation=nil end
  a.state:flush()
  if confirmed then
   a.shelfEditing=false;a.shelfSelection={};a:message(op.kind=='private'and(op.value==1 and'已开启私密阅读，阅读记录将不再公开。'or'已关闭私密阅读。')or'已更新书籍分组。')
  elseif r.rejected then a:message('本次书架操作未成功，已保留云端状态。')
  elseif readOnly and r.snapshot then a:message('已核对云端，尚未应用上次更改；如仍需要，请重新选择后操作。')
  else a:message('操作结果尚未确认，已保留待核对记录；再次操作时会先读取云端，不会自动重复提交。')end
  a:draw();a:loadCovers()
 end,false,{valid=function()return alive(a,o)end,failed=function()
  if a.shelfOperation==o then a.shelfOperation=nil end
  if alive(a,o)then a:message('操作结果尚未确认，待核对记录已保留。');a:draw()end
 end})
end
function M.commit(a,op)
 if a.closed or a.suspended or not a.client:ready()then a:message('请先登录微信读书。');return end
 if a.shelfOperation then return end
 if a.state.shelfMutation then run(a,a.state.shelfMutation,true);return end
 assert(op.kind=='private'and(op.value==0 or op.value==1)and type(op.ids)=='table'and #op.ids>0 and #op.ids<=20000,'SHELF_ACTION_INVALID')
 a.state.shelfMutation=op;a.state:flush();run(a,op,false)
end
function M.privacy(a)
 local rows=eligible(a);if #rows==0 then a:message('请选择微信书架中的书籍。');return end
 local value=M.toPrivate(a)and 1 or 0;local ids={};for _,b in ipairs(rows)do ids[#ids+1]=b.bookId end
 local state,vid,group=a.state,a.client.data.vid,a.shelfGroup
 require('ui/uimanager'):show(require('ui/widget/confirmbox'):new{title='私密阅读',text=value==1 and'开启后，所选书籍的阅读记录将不会对外公开。'or'是否对所选书籍关闭私密阅读？',ok_text=value==1 and'开启私密阅读'or'关闭私密阅读',ok_callback=function()
  if a.closed or a.state~=state or a.client.data.vid~=vid or a.shelfGroup~=group then return end
  local selected={};for _,b in ipairs(eligible(a))do selected[b.bookId]=true end
  for _,id in ipairs(ids)do if not selected[id]then return end end
  M.commit(a,{kind='private',ids=ids,value=value})
 end})
end
return M
