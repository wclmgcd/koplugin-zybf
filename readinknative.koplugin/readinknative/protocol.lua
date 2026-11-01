-- Protocol policy for the WeRead E-Ink compatibility adapter.
-- Source baseline: official download 2.1.2 (versionCode 10245900).
local P = {
    source_version='2.1.2', source_version_code=10245900,
    origins={weread='https://i.weread.qq.com',wechat_qr='https://open.weixin.qq.com',wechat_poll='https://long.open.weixin.qq.com'},
}
function P.checkRequest(url, authenticated)
    local host = type(url)=='string' and url:match('^https://([^/]+)')
    assert(host=='i.weread.qq.com' or host=='open.weixin.qq.com' or host=='long.open.weixin.qq.com','HOST_REJECTED')
    assert(not authenticated or host=='i.weread.qq.com','AUTH_HOST_REJECTED')
    return host
end
function P.archiveUrl(bookId,chapterUid,url)
    bookId=tostring(bookId);chapterUid=tostring(chapterUid)
    assert(bookId:match('^[A-Za-z0-9]+$')and chapterUid:match('^%d+$'),'IMAGE_ARCHIVE_URL_REJECTED')
    local expected='https://res.weread.qq.com/wrco/tar_CB_'..bookId..'_'..chapterUid
    assert(url==expected,'IMAGE_ARCHIVE_URL_REJECTED');return expected
end
return P
