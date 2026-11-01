-- Selection is always revalidated against the current account/book scope.
local S={}
function S.selected(items,ids,key)
    local selected={}
    for _,item in ipairs(items)do if ids and ids[tostring(item[key])]then selected[#selected+1]=item end end
    return selected
end
function S.toggleAll(items,ids,key)
    local all=#items>0 and #S.selected(items,ids,key)==#items
    local nextIds={}
    if not all then for _,item in ipairs(items)do nextIds[tostring(item[key])]=true end end
    return nextIds
end
function S.notes(app)
    return S.selected(require('readinknative/collections').records(app),app.noteSelection,'id')
end
function S.noteText(rows)
    local parts={}
    for _,row in ipairs(rows)do
        parts[#parts+1]=(row.chapterTitle or '')..'\n'..((row.quote and (row.quote..'\n')or'')..(row.text or ('书签 · 记录时第 '..tostring(row.position.page or '?')..' 页')))
    end
    return table.concat(parts,'\n\n')
end
function S.removeNotes(state,bookId,ids)
    local count=0
    for i=#state.annotations,1,-1 do
        local row=state.annotations[i]
        if row.bookId==tostring(bookId) and ids[row.id]then require('readinknative/annotations').remove(state,row.id);count=count+1 end
    end
    return count
end
function S.hideBooks(state,ids)
    state.hiddenBooks=state.hiddenBooks or {};local count=0
    for _,book in ipairs(state.books)do
        local id=tostring(book.bookId)
        if ids[id] and not state.hiddenBooks[id]then state.hiddenBooks[id]=true;count=count+1 end
    end
    return count
end
return S
