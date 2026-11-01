local UI=require('ui/uimanager');local W=require('readinknative/wallpaper');local M={}
local function alive(app)return not app.closed and not app.suspended end
function M.preview(app)
 local path=W.pick(app.wallpaperOwner)
 if not path then app:message(W.mode()=='follow'and'当前跟随 KOReader，请在 KOReader 中预览。'or W.mode()=='native'and'原生壁纸正在准备，请稍后预览。'or'锁屏图片尚未准备好，请选择图片或备用图后再试。');return end
 UI:forceRePaint();UI:show(W.preview(path))
end
-- Presets keep their original bytes in the package. Selecting one imports
-- an independent device-local copy through the same validated image pipeline.
M.presetsList={{name='蜻蜓',file='dragonfly.png'},{name='破纸海豚',file='dolphin.png'},{name='撕纸洞',file='torn-paper.png'},{name='斗鱼',file='betta.png'}}
function M.usePreset(app,option,slot,preview)
 if not alive(app)then return end
 local source=app.path..'/resources/wallpapers/'..option.file
 if require('libs/libkoreader-lfs').attributes(source,'mode')~='file'then app:message('预置壁纸文件缺失，请重新安装完整安装包。');return end
 local background
 if preview then UI:forceRePaint();background=W.capture()end
 local function release()if background then background:free();background=nil end end
 app.wallpaperImport=app.wallpaperImport or require('readinknative/jobs').new()
 app.wallpaperImport:run(preview and'准备预览'or'处理锁屏图片',function()
  if not preview then return W.import(source,slot)end
  local w,h=W.size();local ready=W.renderPath(source,w,h)
  if require('libs/libkoreader-lfs').attributes(ready,'mode')~='file'then W.compose(source,ready,w,h)end
  return ready
 end,function(ok,result)
  if not alive(app)then release();return end
  if not ok then release();app:message('预置壁纸无法读取，原设置已保留。');return end
  if preview then
   local frame=background;background=nil;UI:show(W.preview(result,frame))
  else
   W.commit(result,slot);if slot=='image'then W.setMode('wallpaper')end
   app:draw();app:message(slot=='image'and'已使用预置壁纸：'..option.name or'已设为备用图：'..option.name)
  end
 end,nil,release)
end
function M.presets(app,slot)
 slot=slot or'image';local dialog;local buttons={}
 for _,option in ipairs(M.presetsList)do
  local row=option
  buttons[#buttons+1]={{text=row.name,callback=function()UI:close(dialog);M.usePreset(app,row,slot,false)end},
   {text='预览',callback=function()UI:close(dialog);M.usePreset(app,row,slot,true)end}}
 end
 buttons[#buttons+1]={{text='返回',callback=function()UI:close(dialog);if alive(app)then M.open(app)end end}}
 dialog=require('ui/widget/buttondialog'):new{title=slot=='image'and'选择预置壁纸'or'选择预置备用图',buttons=buttons};UI:show(dialog);return dialog
end
function M.fallback(app)
 local dialog
 dialog=require('ui/widget/buttondialog'):new{title='选择备用图',buttons={
  {{text='使用预置图片',callback=function()UI:close(dialog);M.presets(app,'fallback')end}},
  {{text='从本机选择图片',callback=function()UI:close(dialog);M.choose(app,'fallback')end}},
  {{text='返回',callback=function()UI:close(dialog);M.open(app)end}},
 }};UI:show(dialog);return dialog
end
function M.choose(app,slot)
 local chooser=require('ui/widget/pathchooser'):new{title='长按选择图片 · JPG / PNG',select_directory=false,select_file=true,
  path=require('apps/filemanager/filemanagerutil').getHomeFolder(),
  file_filter=function(path)return path:lower():match('%.jpe?g$')or path:lower():match('%.png$')end,
  onConfirm=function(path)
   if not alive(app)then return true end
   app.wallpaperImport=app.wallpaperImport or require('readinknative/jobs').new()
   app.wallpaperImport:run('处理锁屏图片',function()return W.import(path,slot)end,function(ok,result)
    if not alive(app)then return end
    if ok then W.commit(result,slot);app:message(slot=='image'and'壁纸已保存，可点击预览查看。'or'备用图已保存。');app:draw()
    else app:message('图片无法使用，请选择有效的 JPG / PNG（不超过 16 MB）。原设置已保留。')end
   end)
   return true
  end}
 UI:show(chooser);return chooser
end
function M.open(app)
 if not W.supported()then app:message('当前设备不支持 KOReader 自定义休眠图片。');return end
 local dialog;local buttons={}
 for _,v in ipairs{{'follow','跟随 KOReader'},{'cover','纯封面'},{'wallpaper','纯壁纸'},{'native','原生壁纸'}}do
  local mode,label=v[1],v[2];buttons[#buttons+1]={{text=(W.mode()==mode and'✓ 'or'')..label,callback=function()
   UI:close(dialog);if alive(app)then
    W.setMode(mode);app:draw();M.open(app)
    if mode=='native'then app:message('已启用原生壁纸：12 张随机轮换，每次锁屏自动切换。')end
   end
  end}}
 end
 buttons[#buttons+1]={{text='预置壁纸 · '..#M.presetsList..' 张',callback=function()UI:close(dialog);M.presets(app,'image')end}}
 buttons[#buttons+1]={{text='选择本机壁纸'..(W.slot('image')and' · 已设置'or''),callback=function()UI:close(dialog);M.choose(app,'image')end}}
 buttons[#buttons+1]={{text='选择备用图'..(W.slot('fallback')and' · 已设置'or''),callback=function()UI:close(dialog);M.fallback(app)end}}
 buttons[#buttons+1]={{text='预览锁屏效果',callback=function()UI:close(dialog);M.preview(app)end}}
 buttons[#buttons+1]={{text='返回',callback=function()UI:close(dialog)end}}
 dialog=require('ui/widget/buttondialog'):new{title='锁屏壁纸 · '..W.label(),buttons=buttons};UI:show(dialog);return dialog
end
return M
