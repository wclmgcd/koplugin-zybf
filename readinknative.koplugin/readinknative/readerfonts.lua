-- Official choices bind to an owned font file and a unique engine family.
-- Local fonts stay available separately under their real family names.
local M={}
local identity=require('readinknative/fontidentity')
local bundled=identity.bundled
local root=assert(debug.getinfo(1,'S').source:match('^@(.*/)[^/]+$'))..'../resources/fonts/'
local catalog
function M.catalog()
 if not catalog then
  local f=assert(io.open(root..'official-catalog.json','rb'));local data=f:read(256*1024);f:close()
  catalog=require('rapidjson').decode(data).items
 end
 return catalog
end
function M.get(id)
 for _,item in ipairs(M.catalog())do if item.font==id then return item end end
end
function M.expected(item)
 local own=bundled[item.font]
 return own and own.face or 'ReadInk-'..item.font
end
function M.path(item)
 local own=bundled[item.font]
 return own and root..own.file or require('readinknative/fontfetch').path(item)
end
local function normalizedPath(path)
 if type(path)~='string'or path==''then return end
 path=path:gsub('\\','/')
 if path:sub(1,1)~='/'and not path:match('^%a:/')then
  local lfs=require('libs/libkoreader-lfs')
  if lfs.currentdir then local ok,cwd=pcall(lfs.currentdir);if ok and cwd then path=cwd..'/'..path end end
 end
 local parts={}
 for part in path:gmatch('[^/]+')do
  if part=='..'and #parts>0 and parts[#parts]~='..'then table.remove(parts)
  elseif part~='.'then parts[#parts+1]=part end
 end
 return(path:sub(1,1)=='/'and'/'or'')..table.concat(parts,'/')
end
local function sameFile(a,b)
 if normalizedPath(a)==normalizedPath(b)then return true end
 local lfs=require('libs/libkoreader-lfs');local x,y=lfs.attributes(a),lfs.attributes(b)
 return x and y and x.ino and x.ino~=0 and x.dev~=nil and x.ino==y.ino and x.dev==y.dev or false
end
local function registered(engine,face)
 local found=false
 for _,name in ipairs(engine.getFontFaces())do if name==face then found=true;break end end
 if not found then return end
 if type(engine.getFontFaceFilenameAndFaceIndex)~='function'then return nil,'FONT_IDENTITY_UNVERIFIED'end
 local ok,path=pcall(engine.getFontFaceFilenameAndFaceIndex,face)
 if not ok or type(path)~='string'or path==''then return nil,'FONT_IDENTITY_UNVERIFIED'end
 return path
end
function M.installed(document,item)
 local ok,face=pcall(function()
  local path=M.path(item)
  if require('libs/libkoreader-lfs').attributes(path,'mode')~='file'then return end
  local expected=M.expected(item);local actual=registered(document.doc:engineInit(),expected)
  if actual and sameFile(actual,path)then return expected end
 end)
 return ok and face or nil
end
function M.load(document,item)
 local selected=M.get(item and item.font)
 if not selected then return nil,'FONT_ITEM_REJECTED'end
 if selected.creSupported==false then return nil,'FONT_ENGINE_UNSUPPORTED'end
 local ok,face,err=pcall(function()
  local path=M.path(selected)
  if require('libs/libkoreader-lfs').attributes(path,'mode')~='file'then return nil,'FONT_FILE_MISSING'end
  local expected=M.expected(selected);local engine=document.doc:engineInit()
  local actual,problem=registered(engine,expected)
  if problem then return nil,problem end
  if actual then
   if sameFile(actual,path)then return expected end
   return nil,'FONT_IDENTITY_CONFLICT'
  end
  engine.registerFont(path)
  actual,problem=registered(engine,expected)
  if problem then return nil,problem end
  if not actual then return nil,'FONT_LOAD_FAILED'end
  if not sameFile(actual,path)then return nil,'FONT_IDENTITY_CONFLICT'end
  return expected
 end)
 if not ok then return nil,'FONT_LOAD_FAILED'end
 return face,err
end
function M.bundled(document,id)
 if not bundled[id]then return nil,'FONT_ITEM_REJECTED'end
 return M.load(document,{font=id})
end
function M.ensure(document,face)
 if not face then return end
 for _,item in ipairs(M.catalog())do
  if face==M.expected(item)then return M.load(document,item)end
 end
 local ok,actual,err=pcall(function()return registered(document.doc:engineInit(),face)end)
 if not ok then return nil,'FONT_LOAD_FAILED'end
 if err then return nil,err end
 if not actual or require('libs/libkoreader-lfs').attributes(actual,'mode')~='file'then return nil,'FONT_FILE_MISSING'end
 return face
end
function M.describe(face)
 for i,item in ipairs(M.catalog())do if face==M.expected(item)then return item.fontName,i end end
 return face,100
end
function M.faces(document)
 local out,seen={},{}
 for _,face in ipairs(document:faces())do if not seen[face]then out[#out+1]=face;seen[face]=true end end
 table.sort(out,function(a,b)local _,x=M.describe(a);local _,y=M.describe(b);return x<y or x==y and a<b end)
 return out
end
function M.caption(item)return item.fontName..(item.creSupported==false and'（暂不支持）'or'')end
function M.name(face)return face and(M.describe(face))or'系统字体'end
function M.preview(document,face)
 if not face then return end
 local ok,path=pcall(function()return document.doc:engineInit().getFontFaceFilenameAndFaceIndex(face)end)
 if ok and type(path)=='string'and path~=''then
  local list=require('fontlist'):getFontList();local found=false;for _,file in ipairs(list)do if file==path then found=true;break end end
  if not found then list[#list+1]=path end;return path
 end
end
function M.items(document)
 local out,used={},{}
 for _,item in ipairs(M.catalog())do
  local q={};for k,v in pairs(item)do q[k]=v end
  q.face=M.installed(document,item);q.bundled=bundled[item.font]~=nil
  if q.face then used[q.face]=true end
  out[#out+1]=q
 end
 for _,face in ipairs(M.faces(document))do if not used[face]then out[#out+1]={fontName=face,face=face}end end
 return out
end
function M.categories()
 local counts={['全部']=#M.catalog()+1,['仓耳']=0,['方正']=0,['其他']=0}
 for _,q in ipairs(M.catalog())do counts[q.fontType]=(counts[q.fontType]or 0)+1 end
 local out={};for _,name in ipairs{'全部','仓耳','方正','其他'}do out[#out+1]={name=name,count=counts[name]}end
 return out
end
local recommended={'cejk','TsangerHuaXinTi','syst','TsangerJinKai03-W05','KingHwa_OldSong','syht','TsangerXuanSan01JF-W04','ChillHuoSong_F_Regular','fzss','cexs','hyksk','fzys','ceyh','HuiwenZhengkai-Regular','fzlth','TsangerYunHei-W05','ChillKai','fzlty','TsangerMingKai-W04','xwwk'}
function M.filtered(document,category)
 local all=M.items(document);local out={};category=category or'全部'
 if category=='本机'then for _,q in ipairs(all)do if not q.font then out[#out+1]=q end end;return out end
 if category=='全部'then
  out[1]={fontName='系统字体',system=true};local used,map={},{}
  for _,q in ipairs(all)do if q.font then map[q.font]=q end end
  for _,id in ipairs(recommended)do if map[id]then out[#out+1]=map[id];used[id]=true end end
  for _,q in ipairs(all)do if q.font and not used[q.font]then out[#out+1]=q end end
 else
  for _,q in ipairs(all)do if q.font and q.fontType==category then out[#out+1]=q end end
  table.sort(out,function(a,b)return(a.largeScreenSingleTypeIndex or a.singleTypeIndex or a.index)<(b.largeScreenSingleTypeIndex or b.singleTypeIndex or b.index)end)
 end
 return out
end
function M.grid(document,current)
 local items=M.items(document);local wanted={'cejk','TsangerHuaXinTi','syst','TsangerJinKai03-W05','KingHwa_OldSong','syht','TsangerXuanSan01JF-W04'}
 local map={};for _,q in ipairs(items)do if q.font then map[q.font]=q end end
 local out={};for _,id in ipairs(wanted)do if map[id]then out[#out+1]=map[id]end end
 if current then
  local shown=false;for _,q in ipairs(out)do if q.face==current then shown=true end end
  if not shown then for _,q in ipairs(items)do if q.face==current then out[#out]=q;break end end end
 end
 return out
end
return M
