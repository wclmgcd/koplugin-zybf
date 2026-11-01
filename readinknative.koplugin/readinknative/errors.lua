local E={CACHE_DIRECTORY_FAILED='无法创建缓存目录，请检查存储状态和诊断日志。',EPUB_WRITE_FAILED='章节缓存写入失败，请查看存储诊断日志。',EPUB_COMMIT_FAILED='章节缓存提交失败，原缓存已保留。请查看诊断日志。',THOUGHT_DRAFT_WRITE_FAILED='无法保存想法草稿，请检查存储空间。',THOUGHT_OUTCOME_UNKNOWN='发表结果尚未确认，请先核对云端，暂不重复发表。',THOUGHT_TEXT_INVALID='请输入有效的想法内容。',THOUGHT_VISIBILITY_INVALID='请选择想法可见范围。',ANNOTATION_SYNC_OUTCOME_UNKNOWN='上次划线上传结果未确认，正在回读核对，暂不重复上传。',ANNOTATION_SYNC_NOT_CONFIRMED='服务端未确认划线同步，原记录已保留。',ANNOTATION_SYNC_RANGE_UNMATCHED='这条划线的原文位置未能精确匹配，已保留本机记录，未上传。',ANNOTATION_SYNC_AMBIGUOUS='同一范围存在多条云端划线，已保留原记录，未自动修改。',ANNOTATION_SYNC_METADATA_INVALID='划线所属图书版本未能确认，已保留本机记录。',ANNOTATION_SYNC_RANGE_INVALID='划线原文范围无效，未上传。',ARTICLE_ACCESS_WRITE_FAILED='微信文章访问状态未能保存，请检查可用存储空间。',ARTICLE_VERIFICATION_PENDING='本篇处于阅墨的临时暂停期间，没有再次请求原文。已缓存文章仍可阅读，稍后可手动重试。',ARTICLE_RESPONSE_TOO_LARGE='微信原网页的附加资源过大，未能完整取得正文。',ARTICLE_SCHEMA_CHANGED='微信文章返回格式发生变化，已保留原缓存。',ARTICLE_CURSOR_STALLED='文章分页位置没有推进，请刷新列表重试。',ARTICLE_LIST_LIMIT='已加载文章达到本机列表上限。',ARTICLE_URL_REJECTED='这篇文章的原文地址暂不支持。',ARTICLE_TOO_LARGE='这篇文章超过本机处理上限。',ARTICLE_FETCH_FAILED='原文读取失败，请联网后重试。',ARTICLE_HTML_INVALID='原文格式不完整，请重新加载。',ARTICLE_VERIFICATION_REQUIRED='微信原文要求安全验证，暂不能在本机读取。请先在微信或官方客户端查看。',ARTICLE_BODY_UNAVAILABLE='原文未返回可读正文，可能已删除或限制访问。',ARTICLE_INTERNAL_UNSUPPORTED='此文章使用微信读书内部正文格式，尚未适配。',ARTICLE_PAID_REQUIRED='这篇文章有付费限制，请先在官方客户端核对阅读权益。',ARTICLE_CACHE_WRITE_FAILED='文章缓存保存失败，请检查可用空间。',IMAGE_FETCH_FAILED='部分正文图片未能下载，请联网后点下载重试。',IMAGES_INCOMPLETE='本章图片尚未加载完整，请联网后重新打开本章。',IMAGE_STATUS_WRITE_FAILED='无法保存图片下载状态，请检查可用存储空间。',EPUB_REPAIR_UNSUPPORTED='当前章节缓存无法直接更新图片，请重新获取章节。',CACHE_ACCESS_WRITE_FAILED='无法保存离线权益记录，缓存目录写入失败。请查看诊断日志。',CACHE_ACCESS_INVALID='离线权益记录无效，请联网重新核对本书权限。',READING_PAID_MEMBER_REQUIRED='本书属于付费会员可读范围；当前账号未确认此权益。体验卡不等同于付费会员，仍可在目录选择可读章节。',ACCOUNT_SCHEMA_CHANGED='账户余额返回格式变化，已保留上次数据。',MEMBER_SCHEMA_CHANGED='会员信息返回格式变化，已保留上次数据。',STORE_CURSOR_STALLED='书城分页位置没有推进，请刷新后重试。',STORE_SCHEMA_CHANGED='书城返回格式发生变化，原缓存已保留。',STORE_QUERY_INVALID='请输入有效的书城搜索词。',STORE_CATEGORY_INVALID='当前分类无效，请返回重新选择。',ENDPOINT_UNAVAILABLE='当前网络未能访问登录服务。请在 Kindle 的网络下手动重试；这次响应无法证明登录参数有误。',BOOK_SCHEMA_CHANGED='图书信息返回格式发生变化。',TXT_CONTENT_INVALID='TXT 章节返回格式不完整，原缓存已保留。',BOOK_FORMAT_UNSUPPORTED='当前线上图书格式暂不支持。',CHAPTER_REJECTED='服务端未返回可读章节。',LOGIN_REQUIRED='请先登录微信读书。',INVALID_JSON='服务端返回了非预期内容。若发生在扫码步骤，请检查网络后手动重试。',
    QR_FAILED='未能获取二维码，请检查网络后重试。',QR_EXPIRED='二维码已过期，请重新登录。',QR_CANCELLED='已取消微信授权。',
    NETWORK_FAILED='网络请求失败，请检查网络后手动重试。',VERIFICATION_REQUIRED='微信读书要求安全验证，请先在官方客户端处理。',
    PREVIEW_UNAVAILABLE='本章没有可用试读内容。此版本不会自动购买或切换为完整章节下载。',
    CATALOG_EMPTY='未取得可阅读目录。',SHELF_SCHEMA_CHANGED='书架返回格式发生变化，未覆盖本地书架。',
    CATALOG_SCHEMA_CHANGED='目录返回格式发生变化。',CHAPTER_FILES_MISSING='章节包缺少正文，暂时无法阅读。'}
E.SOCIAL_SOURCE_UNSUPPORTED='本章的原文位置暂不支持，未生成可能错位的划线。'
E.SOCIAL_SOURCE_VERSION_CHANGED='图书版本已变化，请重新打开图书后读取划线。'
E.SOCIAL_READING_CACHE_CHANGED='章节缓存已变化，请重新打开本章读取划线。'
E.FONT_FILE_MISSING='所选字体文件未找到，请重新安装对应字体或选择其他字体。'
E.FONT_LOAD_FAILED='所选字体未能加载，字体设置未保存。请检查字体文件或重启 KOReader 后重试。'
E.FONT_IDENTITY_CONFLICT='字体名称与实际文件不一致，请重启 KOReader 或重新安装对应字体后重试。'
E.FONT_IDENTITY_UNVERIFIED='无法确认所选字体的实际文件，请重启 KOReader 后重试。'
E.FONT_ITEM_REJECTED='字体条目已变化，请重新打开字体列表。'
E.FONT_ENGINE_UNSUPPORTED='此字体目前无法由排版引擎加载，请选择其他字体。'
E.COMMENT_TEXT_INVALID='请输入评论，最多 1000 字。'
E.COMMENT_OUTCOME_UNKNOWN='评论结果尚未确认，请先核对原评论。'
function E.code(err)
    local text=tostring(err or '')
    local http=text:match('HTTP_%d+');local api=text:match('API_%-?%d+')
    if http or api then return table.concat({http or '',api or ''},' '):gsub('^%s+',''):gsub('%s+$','')end
    local best
    for code,msg in pairs(E)do if type(msg)=='string'and text:find(code,1,true)and(not best or #code>#best)then best=code end end
    if best then return best end
    for _,code in ipairs({'INVALID_CHAPTER_KEY','INVALID_ACCOUNT','ARCHIVE_READ_FAILED','ARCHIVE_OPEN_FAILED','ARCHIVE_KEY_FAILED',
        'ARCHIVE_TOO_LARGE','ARCHIVE_TRUNCATED','ARCHIVE_PATH_REJECTED','ARCHIVE_TYPE_REJECTED','ARCHIVE_LINK_REJECTED','ARCHIVE_DUPLICATE',
        'EPUB_WRITE_FAILED','EPUB_COMMIT_FAILED','DOCUMENT_OPEN_FAILED','DOCUMENT_LOAD_FAILED','CHAPTER_BOOK_MISMATCH'})do
        if text:find(code,1,true)then return code end
    end
    return 'UNCLASSIFIED'
end
function E.message(err)
    local text=tostring(err or '')
    local pdfHost=text:match('PDF_REDIRECT_HOST_REJECTED:([A-Za-z0-9%.%-]+)')
    if pdfHost then return 'PDF下载地址暂不支持（'..pdfHost..'），请反馈这条提示。'end
    local best
    for code,msg in pairs(E)do if type(msg)=='string'and text:find(code,1,true)and(not best or #code>#best)then best=code end end
    if best then return E[best]end
    local code=E.code(err)
    if text:find('HTTP_402',1,true)then return '服务端拒绝提供此章节（'..code..'）。\n请在官方客户端核对本书可读范围，或返回目录选择可读章节。'end
    if text:find('HTTP_',1,true)or text:find('API_',1,true)then return '服务端未接受请求（'..code..'）。'end
    return '本次操作未完成（'..code..'）。请稍后手动重试。'
end
E.RELATED_SOURCE_INVALID='关联版本信息已失效，请重新打开章节。'
E.RELATED_SOURCE_VERSION_CHANGED='关联版本已更新，请重新打开章节以核对原文位置。'
E.PDF_NATIVE_REQUIRED='PDF需要使用原生PDF阅读器。'
E.PDF_DOWNLOAD_FAILED='PDF下载未完成，请联网后重试。'
E.PDF_INVALID='返回的文件不是可读取的PDF，原缓存已保留。'
E.PDF_TOO_LARGE='PDF文件超过本机256MB下载上限。'
E.PDF_WRITE_FAILED='PDF保存失败，请检查可用存储空间。'
E.PDF_PERMISSION_REQUIRED='当前账号尚未确认整本PDF的阅读权限。'
E.PDF_ENGINE_UNAVAILABLE='当前KOReader未提供PDF阅读引擎。'

E.PDF_NETWORK_FAILED='PDF下载连接失败，请检查网络后重试。'
E.PDF_AUTH_REQUIRED='PDF下载认证未通过，请重新登录后重试。'
E.PDF_FORBIDDEN='PDF下载被服务端拒绝（403），请在官方客户端确认此书仍可打开。'
E.PDF_NOT_FOUND='PDF原文件未找到（404），请在官方客户端核对上传状态。'
E.PDF_REDIRECT_REJECTED='PDF跳转地址无效，下载未完成。'
E.PDF_REDIRECT_HOST_REJECTED='PDF跳转到了暂不支持的下载地址。'
E.PDF_REDIRECT_LIMIT='PDF下载跳转次数过多，原缓存已保留，请稍后重试。'
E.UNDERLINE_SEED_WRITE_FAILED='书友划线缓存未保存，本章可继续阅读，将自动重试。'
E.PDF_TEXT_UNAVAILABLE='这本 PDF 暂未取得官方文字版，可继续阅读原版 PDF。'
E.PDF_TEXT_TRANSING='官方文字版正在转换，请稍后再试。'
E.PDF_TEXT_UNVERIFIED='官方文字版的目录或原文位置尚未核对，原版 PDF 已保留。'
return E
