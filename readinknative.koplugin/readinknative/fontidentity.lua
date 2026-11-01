-- Stable identities for bundled fonts; no engine or filesystem work here.
local I={syst='ReadInk-SourceHanSerifCN-Medium'}
I.bundled={syst={file='ReadInk-SourceHanSerifCN-Medium.otf',face=I.syst}}
local legacy={
    ['syst']=I.syst,
    ['ReadInk-syst']=I.syst,
    ['ReaderBridge-syst']=I.syst,
    ['Source Han Serif CN']=I.syst,
    ['Source Han Serif CN Regular']=I.syst,
    ['Source Han Serif CN Medium']=I.syst,
}
-- Used only while migrating old settings. Later explicit local choices keep
-- their own names even when they resemble an official option.
function I.migrate(face)return legacy[face]or face end
return I
