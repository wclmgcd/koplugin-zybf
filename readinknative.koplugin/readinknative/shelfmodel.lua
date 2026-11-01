-- Official shelf wire metadata and a derived grouped view; canonical books stay
-- flat for reading, notes, downloads and cache identity.
local M={};local Order=require('readinknative/shelforder')
local function id(v)
 if type(v)~='string'and type(v)~='number'then return end
 local s=tostring(v);if s==''or #s>128 or s:find('[%c]')then return end;return s
end
local function groupId(v)
 local n=tonumber(v);if n and n==n and n%1==0 and n>0 and n<2147483648 then return tostring(n)end
end
local function time(v)
 local n=tonumber(v);if not n or n~=n or n<0 or n>1e15 then return 0 end
 if n>1e12 then n=n/1000 end;return n
end
function M.parse(raw)
 assert(type(raw)=='table'and type(raw.books)=='table','SHELF_SCHEMA_CHANGED')
 local books,groups,byId,owners,seen={},{},{},{},{}
 assert(raw.archive==nil or type(raw.archive)=='table','SHELF_SCHEMA_CHANGED')
 for i,g in ipairs(raw.archive or{})do
  assert(i<=1000 and type(g)=='table','SHELF_SCHEMA_CHANGED')
  local key=groupId(g.archiveId);assert(key and type(g.name)=='string'and #g.name<=1024,'SHELF_SCHEMA_CHANGED')
  assert(not byId[key],'SHELF_SCHEMA_CHANGED')
  local row={archiveId=key,name=g.name,rank=i,isTop=tonumber(g.isTop)==1};groups[#groups+1]=row;byId[key]=row
  assert(g.bookIds==nil or type(g.bookIds)=='table','SHELF_SCHEMA_CHANGED')
  for _,value in ipairs(g.bookIds or{})do local bookId=id(value);assert(bookId and not owners[bookId],'SHELF_SCHEMA_CHANGED');owners[bookId]=key end
 end
 for i,row in ipairs(raw.books)do
  assert(i<=20000 and type(row)=='table','SHELF_SCHEMA_CHANGED')
  local b=row.book or row;local key=id(b.bookId)
  if key and type(b.title)=='string'and not seen[key]then
   local secret=row.secret;if secret==nil then secret=b.secret end
   local archive=owners[key]or groupId(row.archiveId or b.archiveId)
   if archive and not byId[archive]then local g={archiveId=archive,name='分组',rank=#groups+1};groups[#groups+1]=g;byId[archive]=g end
   local book={bookId=key,title=b.title,author=b.author or'',version=b.version,format=b.format or'epub',type=b.type,cover=b.cover,
    paid=b.paid,payType=b.payType,maxFreeChapter=b.maxFreeChapter,isChapterPaid=b.isChapterPaid,
    secret=(secret==true or secret==1 or secret=='1')and 1 or(secret==false or secret==0 or secret=='0')and 0 or nil,
    archiveId=archive,readUpdateTime=time(row.readUpdateTime or b.readUpdateTime),shelfRank=i,isTop=tonumber(row.isTop or b.isTop)==1}
   seen[key]=true;books[#books+1]=book
  end
 end
 local progress={}
 for _,r in ipairs(type(raw.bookProgress)=='table'and raw.bookProgress or{})do if type(r)=='table'and r.bookId then progress[tostring(r.bookId)]=require('readinknative/readingstart').normalize(r)end end
 for _,b in ipairs(books)do b.cloudProgress=progress[b.bookId]end
 return{books=books,groups=groups}
end
function M.apply(a,snapshot,fence)
 assert(type(snapshot)=='table'and type(snapshot.books)=='table'and type(snapshot.groups)=='table','SHELF_SCHEMA_CHANGED')
 local all={};for _,b in ipairs(a.state.books or{})do if b.localFile then all[#all+1]=b end end
 for _,b in ipairs(snapshot.books)do all[#all+1]=b end
 Order.merge(a.state,snapshot.books,fence)
 a.state.books=all;a.state.shelfGroups=snapshot.groups;a.state.shelfMetadataSchema=1
 a.shelfChecked={state=a.state,vid=a.client.data.vid,at=os.time()}
end
function M.books(a)
 local books=a.state:filtered(a.query)
 if not a.shelfGroup then return books end
 local out={};for _,b in ipairs(books)do if tostring(b.archiveId or'')==a.shelfGroup then out[#out+1]=b end end;return out
end
function M.recent(state,b)return Order.recent(state,b)end
function M.items(a)
 local books=M.books(a);if a.shelfGroup or a.query~=''then return books end
 local groups,byId,items={},{},{}
 for _,g in ipairs(a.state.shelfGroups or{})do
  local key=groupId(g.archiveId)
  if key then local row={isGroup=true,archiveId=key,title=g.name,bookId='group:'..key,books={},rank=g.rank or 0,isTop=g.isTop,readUpdateTime=0};groups[#groups+1]=row;byId[key]=row end
 end
 for i,b in ipairs(books)do
  local g=byId[tostring(b.archiveId or'')]
  if g then
   g.books[#g.books+1]=b;g.rank=math.min(g.rank>0 and g.rank or math.huge,b.shelfRank or i)
  else items[#items+1]=b end
 end
 for _,g in ipairs(groups)do if #g.books>0 then
  if a.state.sort=='recent'then table.sort(g.books,function(x,y)return Order.less(a.state,x,y)end);g.readUpdateTime=Order.groupTime(a.state,g.books)
  else for _,b in ipairs(g.books)do g.readUpdateTime=math.max(g.readUpdateTime,M.recent(a.state,b))end end
  items[#items+1]=g
 end end
 local rank={};for i,b in ipairs(books)do rank[b.bookId]=b.shelfRank or i end
 table.sort(items,function(x,y)
  if (x.isTop==true)~=(y.isTop==true)then return x.isTop==true end
  if a.state.sort=='recent'then
   return Order.less(a.state,x,y)
  elseif a.state.sort=='title'and x.title~=y.title then return tostring(x.title)<tostring(y.title)end
  local rx=x.isGroup and x.rank or rank[x.bookId]or math.huge;local ry=y.isGroup and y.rank or rank[y.bookId]or math.huge
  if rx~=ry then return rx<ry end;return x.bookId<y.bookId
 end)
 return items
end
function M.selected(a)return require('readinknative/selection').selected(M.books(a),a.shelfSelection,'bookId')end
function M.groupSelected(a,g)
 for _,b in ipairs(g.books)do if not(a.shelfSelection or{})[b.bookId]then return false end end
 return #g.books>0
end
function M.toggleGroup(a,g)
 local value=not M.groupSelected(a,g);a.shelfSelection=a.shelfSelection or{}
 for _,b in ipairs(g.books)do a.shelfSelection[b.bookId]=value or nil end;a:draw()
end
function M.page(a,page,items)
 local options={editing=a.shelfEditing==true,counts=not a.shelfEditing and a.query==''}
 return require('readinknative/shelfpaging').page(a.view.layout,#(items or M.items(a)),page or a.shelfPage,options)
end
function M.pageForIndex(a,index,items)
 return require('readinknative/shelfpaging').forIndex(a.view.layout,#(items or M.items(a)),index,
  {editing=a.shelfEditing==true,counts=not a.shelfEditing and a.query==''})
end
function M.enter(a,g)
 a.shelfGroup=g.archiveId;a.shelfRootPage=a.shelfPage;a.shelfPage=1;a.shelfSelection={};a.shelfEditing=false;a:draw();a:loadCovers()
end
function M.back(a)
 if not a.shelfGroup then return false end
 local group=a.shelfGroup;a.shelfGroup=nil;a.shelfPage=a.shelfRootPage or 1
 if a.state.sort=='recent'then
  local items=M.items(a)
  for i,item in ipairs(items)do if item.isGroup and item.archiveId==group then a.shelfPage=M.pageForIndex(a,i,items);break end end
 end
 a.shelfRootPage=nil;a.shelfSelection={};a.shelfEditing=false;a:draw();a:loadCovers();return true
end
function M.title(a)
 for _,g in ipairs(a.state.shelfGroups or{})do if tostring(g.archiveId)==a.shelfGroup then return g.name end end
 if a.shelfGroup then a.shelfGroup=nil end;return'书架'
end
function M.counts(a)
 local public,secret,unknown=0,0,0
 for _,b in ipairs(M.books(a))do if not b.localFile then if b.secret==1 then secret=secret+1 elseif b.secret==0 then public=public+1 else unknown=unknown+1 end end end
 return public,secret,unknown
end
function M.visibleBooks(a)
 local items=M.items(a);local page=M.page(a,nil,items);local nextPage=M.page(a,page.page+1,items);local result={}
 local last=nextPage.cells[#nextPage.cells]
 for i=page.first,last and last.index or 0 do local b=items[i]
  if b.isGroup then for n=1,math.min(4,#b.books)do result[#result+1]=b.books[n]end else result[#result+1]=b end
 end;return result
end
-- Display the cache immediately; refresh silently with a separate cancellable
-- worker so changing sort never cancels a chapter/download or opens a modal.
function M.cancel(a)
 if a.shelfMetadataTask then require('ui/uimanager'):unschedule(a.shelfMetadataTask);a.shelfMetadataTask=nil end
 if a.shelfJobs then a.shelfJobs:cancel()end
 a.shelfRefresh=nil
end
function M.invalidate(a)a.shelfChecked=nil end
function M.ensure(a,force)
 if a.closed or a.suspended or a.mode~='shelf'or not a.client or type(a.client.ready)~='function'or not a.client:ready()or a.shelfMetadataTask or a.shelfRefresh then return end
 local now=os.time();local last=a.shelfChecked
 if not force and last and last.state==a.state and last.vid==a.client.data.vid and now>=last.at and now-last.at<60 then return end
 local failed=a.shelfRefreshFailed
 if not force and failed and failed.state==a.state and failed.vid==a.client.data.vid and now>=failed.at and now-failed.at<30 then return end
 local state,vid=a.state,a.client.data.vid;local UI=require('ui/uimanager');local retries=0
 local function valid()return not a.closed and not a.suspended and a.mode=='shelf'and a.state==state and a.client.data.vid==vid end
 a.shelfMetadataTask=function()
  local task=a.shelfMetadataTask;a.shelfMetadataTask=nil
  if not valid()then return end
  local net=require('ui/network/manager');if not net:isWifiOn()or not net:isConnected()then return end
  if a.shelfEditing or(a.jobs and a.jobs.widget)or a.syncBusy or(a.offlineRuntime and a.offlineRuntime.busy)then
   retries=retries+1;if retries<=6 then a.shelfMetadataTask=task;UI:scheduleIn(5,task)end;return
  end
  local owner={};a.shelfRefresh=owner;local data=a.client.data;local fence=Order.fence(state)
  a.shelfJobs=a.shelfJobs or require('readinknative/jobs').new()
  a.shelfJobs:run('',function()
   local child=require('readinknative/client'):new(data)
   return require('readinknative/api').shelfSnapshot(child),child.data
  end,function(ok,snapshot,session)
   if a.shelfRefresh~=owner then return end;a.shelfRefresh=nil
   if not valid()then return end
   if not ok then a.shelfRefreshFailed={state=state,vid=vid,at=os.time()};return end
   if session and a.client.data==data then a.client.data=session;a.client.session.data=session;a.client:commit()end
   M.apply(a,snapshot,fence);a.shelfRefreshFailed=nil;state:flush();a:draw();a:loadCovers()
  end,false)
 end
 UI:scheduleIn(1,a.shelfMetadataTask)
end
return M
