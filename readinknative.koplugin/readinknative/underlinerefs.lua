-- First show verified hot/cached quotes. Missing source ranges/bodies and
-- direct uploaded-book marks are fetched in a separate, cancellable idle pass.
local M={}
function M.fetch(client,book,chapter,path,catalog,quick)
 local Related=require('readinknative/relatededitions');local R=require('readinknative/socialranges')
 local fast=quick and Related.isCB(book)
 local rows=fast and{}or Related.readRanges(client,book,chapter)
 local source
 if #rows>0 or Related.isCB(book)then local ignored;ignored,source=R.load(client,book,chapter,path,rows)end
 local ok,value,incomplete=pcall(Related.collect,client,book,chapter,path,rows,catalog,source,fast and{quick=true}or nil)
 if ok then rows=value
 elseif #rows==0 and not fast then error(value,0)
 else require('logger').warn('ReadInk related thoughts:',require('readinknative/errors').code(value))end
 return{rows=rows,source=source,partial=fast or Related.isCB(book)and(not ok or incomplete==true)or false}
end
local function identity(row)
 local s=row.foreign
 return table.concat({row.range,row.quote or'',s and s.bookId or'',s and s.version or'',s and s.chapterUid or'',s and s.range or''},'\0')
end
function M.merge(rows,previous)
 local old={};for _,r in ipairs(previous or{})do old[identity(r)]=r end
 for _,r in ipairs(rows)do
  local before=old[identity(r)]
  if before and before.position then r.position=before.position;r.resolved=before.resolved end
 end
 return rows
end
return M
