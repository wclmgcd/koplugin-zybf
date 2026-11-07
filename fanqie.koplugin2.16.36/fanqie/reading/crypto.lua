--[[--
番茄 reading API：registerkey / batch_full 请求构建与正文解密。
移植自 book.koplugin/source/fanqie/reading/crypto.lua（原始来自 fanqie-re）。

@module fanqie.reading.crypto
--
-- 版权与许可：
--   Copyright (C) 月读 (AnkioTomas/moon) contributors
--   本文件移植自月读的 KOReader 插件（book.koplugin），原作以 GNU GPLv3 发布。
--   本仓库整体以 GPL-3.0-only 分发，全文见根目录 LICENSE，
--   上游来源清单见 THIRD_PARTY_NOTICES.txt。
--]]

local Aes = require("fanqie.reading.aes")
local Text = require("fanqie.reading.text")

local Crypto = {}

local HARDCODED_KEY = Aes.from_hex("ac25c67ddd8f38c1b37a2348828e222e")
local AID = 1967

-- 十进制数字串 ÷ 256。每一步的余数小于 256，因此 cur 最大只有 2559，
-- 不经过 double 的大整数近似，19 位 device_id 也能保留末位。
local function divmod256(digits)
    local q, rem = {}, 0
    for i = 1, #digits do
        local cur = rem * 10 + (digits:byte(i) - 48)
        local d = math.floor(cur / 256)
        rem = cur - d * 256
        if #q > 0 or d > 0 then q[#q + 1] = string.char(48 + d) end
    end
    return table.concat(q), rem
end

local function le64(n)
    if type(n) == "string" and n:match("^%d+$") then
        local digits = n:gsub("^0+", "")
        if digits == "" then digits = "0" end
        local out = {}
        for i = 1, 8 do
            if digits == "0" then
                out[i] = "\0"
            else
                local q, r = divmod256(digits)
                out[i] = string.char(r)
                digits = q == "" and "0" or q
            end
        end
        return table.concat(out)
    end
    n = tonumber(n) or 0
    local out = {}
    for i = 1, 8 do
        out[i] = string.char(n % 256)
        n = math.floor(n / 256)
    end
    return table.concat(out)
end

--- n 字节随机数：优先 /dev/urandom，读不到或不足 n 字节时退回 math.random。
---@param n integer
---@return string
function Crypto.urandom(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local d = f:read(n)
        f:close()
        if d and #d == n then return d end
    end
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

local function uuid_iv()
    return (Aes.to_hex(Crypto.urandom(16)):sub(1, 16))
end

---@param device_id string|number
---@param user_id string|number|nil
---@param iv_text string|nil 16 ASCII chars
---@return string base64 content
function Crypto.build_register_content(device_id, user_id, iv_text)
    local payload = le64(device_id) .. le64(user_id or 0)
    iv_text = iv_text or uuid_iv()
    assert(#iv_text == 16)
    local iv = iv_text
    local ct = Aes.cbc_encrypt(payload, HARDCODED_KEY, iv, true)
    return Text.base64Encode(iv .. ct)
end

---@param encrypted_key_b64 string
---@return string v1_key uppercase hex
function Crypto.decrypt_server_key(encrypted_key_b64)
    local raw = Text.base64Decode(encrypted_key_b64)
    if #raw < 17 then error("encrypted key too short") end
    local pt = Aes.cbc_decrypt(raw:sub(17), HARDCODED_KEY, raw:sub(1, 16), true)
    return Aes.to_hex(pt):upper()
end

---@param encrypted_content_b64 string
---@param v1_key_hex string
---@return string binary
function Crypto.decrypt_content(encrypted_content_b64, v1_key_hex)
    local raw = Text.base64Decode(encrypted_content_b64)
    if #raw < 17 then error("encrypted content too short") end
    local key = Aes.from_hex(v1_key_hex:lower())
    return Aes.cbc_decrypt(raw:sub(17), key, raw:sub(1, 16), true)
end

local libz_cache

--- libz 句柄；加载失败返回 false。
---@return table|false
local function loadLibz()
    if libz_cache ~= nil then return libz_cache end
    local ffi = require("ffi")
    -- 逐条 cdef：同名函数可能已被其他模块声明，重复声明报错不能连带丢掉其余声明。
    -- 参数用 void * 才能兼容他人以 z_stream * 声明的同名函数。
    for _, decl in ipairs({
        [[typedef struct {
            const unsigned char *next_in;
            unsigned int avail_in;
            unsigned long total_in;
            unsigned char *next_out;
            unsigned int avail_out;
            unsigned long total_out;
            const char *msg;
            void *state;
            void *(*zalloc)(void *, unsigned int, unsigned int);
            void (*zfree)(void *, void *);
            void *opaque;
            int data_type;
            unsigned long adler;
            unsigned long reserved;
        } moon_z_stream;]],
        "int inflateInit2_(void *, int, const char *, int);",
        "int inflate(void *, int);",
        "int inflateEnd(void *);",
    }) do
        pcall(ffi.cdef, decl)
    end
    local ok, lib = pcall(ffi.load, "z")
    libz_cache = ok and lib or false
    return libz_cache
end

--- 尽量解压 gzip/zlib；失败则原样返回。
--- 第二个返回值标明「数据是否真的解压成功」（不需要解压时为 true），
--- 调用方据此把「该解压却解不出来」当成坏数据，而不是继续用压缩后的二进制。
---@param data string
---@param compress_status number|nil
---@return string, boolean
function Crypto.maybe_decompress(data, compress_status)
    if not data or data == "" then return data, true end
    local is_gzip = data:byte(1) == 0x1f and data:byte(2) == 0x8b
    local is_zlib = data:byte(1) == 0x78
    local need = (tonumber(compress_status) or 0) > 0 or is_gzip or is_zlib
    if not need then return data, true end

    local ffi = require("ffi")
    local libz = loadLibz()
    if not libz then
        local ok2, zlib = pcall(require, "ffi/zlib")
        if ok2 and zlib and is_zlib then
            local buflen = math.max(#data * 8, 64)
            for _ = 1, 6 do
                local ok3, out = pcall(zlib.zlib_uncompress, data, buflen)
                if ok3 and out then return out, true end
                buflen = buflen * 2
            end
        end
        return data, false
    end

    local function inflate(blob, window_bits)
        local strm = ffi.new("moon_z_stream")
        local zs = ffi.cast("void *", strm)
        local rc = libz.inflateInit2_(zs, window_bits, "1.2.11", ffi.sizeof(strm))
        if rc ~= 0 then
            return nil
        end
        local out_cap = math.max(#blob * 8, 4096)
        local chunks = {}
        local input = ffi.new("unsigned char[?]", #blob)
        ffi.copy(input, blob, #blob)
        strm.next_in = input
        strm.avail_in = #blob
        while true do
            local buf = ffi.new("unsigned char[?]", out_cap)
            strm.next_out = buf
            strm.avail_out = out_cap
            local ret = libz.inflate(zs, 0)
            local produced = out_cap - strm.avail_out
            if produced > 0 then
                chunks[#chunks + 1] = ffi.string(buf, produced)
            end
            if ret == 1 then
                libz.inflateEnd(zs)
                return table.concat(chunks)
            end
            if ret ~= 0 then
                libz.inflateEnd(zs)
                return nil
            end
            -- 输入耗尽但没到 Z_STREAM_END = 压缩流被截断。以前这里返回已解出的
            -- 半截内容，会产生「能打开但缺后半章」的坏缓存；现在一律算失败。
            if strm.avail_in == 0 and strm.avail_out ~= 0 then
                libz.inflateEnd(zs)
                return nil
            end
        end
    end

    local out
    if is_gzip then
        out = inflate(data, 15 + 16) or inflate(data, 15 + 32)
    elseif is_zlib then
        out = inflate(data, 15)
    else
        out = inflate(data, -15) -- raw deflate
    end
    if out then return out, true end
    return data, false
end

--- 正文是否像正常的章节文本。
--- 正常正文是 XHTML（或漫画章节的 JSON），除 \t \n \r 外不含控制字符；
--- 错误密钥 / 防抓取替换的二进制会有一成以上的控制字符。实测 372 个正常
--- 缓存章节文件全为 0，故阈值放到 8 也能稳妥区分。
---@param text string
---@return boolean
function Crypto.looks_like_chapter_text(text)
    if type(text) ~= "string" or #text < 32 then return false end
    local control = 0
    for i = 1, #text do
        local b = text:byte(i)
        if b < 9 or (b > 13 and b < 32) then
            control = control + 1
            if control > 8 then return false end
        end
    end
    return true
end

---@param item table
---@param v1_key string
---@return string
function Crypto.decode_chapter_item(item, v1_key)
    local content_str = item.content or item.origin_content or ""
    if content_str == "" or content_str == "Invalid" then
        return ""
    end
    local crypt_status = tonumber(item.crypt_status) or 0
    local compress_status = tonumber(item.compress_status) or 0
    local raw
    if crypt_status == 0 and v1_key and v1_key ~= "" then
        raw = Crypto.decrypt_content(content_str, v1_key)
    else
        raw = content_str
    end
    local text, decompressed = Crypto.maybe_decompress(raw, compress_status)
    if compress_status > 0 and not decompressed then
        error("章节正文解压失败（回包可能被截断或被服务端替换）")
    end
    if not Crypto.looks_like_chapter_text(text) then
        error("章节正文解密失败（回包无法用本机密钥解开）")
    end
    return text
end

---@param device table
---@param ts_ms number|nil
---@return table
function Crypto.build_common_query(device, ts_ms)
    if type(ts_ms) ~= "number" then
        ts_ms = os.time() * 1000
    end
    return {
        iid = tostring(device.install_id),
        device_id = tostring(device.device_id),
        ac = "wifi",
        channel = device.channel or "43536163a",
        aid = tostring(AID),
        app_name = "novelapp",
        version_code = tostring(device.version_code or "73733"),
        version_name = tostring(device.version_name or "7.3.7.33"),
        device_platform = "android",
        os = "android",
        ssmix = "a",
        device_type = device.device_type or "P30",
        device_brand = device.device_brand or "Huawei",
        language = device.language or "zh",
        os_api = tostring(device.os_api or "30"),
        os_version = tostring(device.os_version or "12"),
        manifest_version_code = tostring(device.version_code or "73733"),
        resolution = device.resolution or "1280*720",
        dpi = tostring(device.dpi or "240"),
        update_version_code = tostring(device.version_code or "73733"),
        _rticket = tostring(ts_ms),
        host_abi = device.host_abi or "armeabi-v7a",
        cdid = device.cdid or "",
        openudid = device.openudid or "",
    }
end

---@param device table
---@param book_id string
---@param item_ids string[]
---@param ts_ms number|nil
---@return table
function Crypto.build_batch_full_query(device, book_id, item_ids, ts_ms)
    local q = Crypto.build_common_query(device, ts_ms)
    q.item_ids = table.concat(item_ids, ",")
    q.key_register_ts = "0"
    q.book_id = tostring(book_id)
    q.req_type = "1"
    return q
end

--- ByteDance query：item_ids 逗号、* / + 不 percent-encode。
---@param params table
---@return string
function Crypto.encode_query(params)
    local order = {
        "iid", "device_id", "ac", "channel", "aid", "app_name", "version_code",
        "version_name", "device_platform", "os", "ssmix", "device_type", "device_brand",
        "language", "os_api", "os_version", "manifest_version_code", "resolution",
        "dpi", "update_version_code", "_rticket", "host_abi", "cdid", "openudid",
        "item_ids", "key_register_ts", "book_id", "req_type",
    }
    local seen = {}
    local parts = {}
    local function add(k, v)
        if v == nil or seen[k] then return end
        seen[k] = true
        local vs = tostring(v)
        local ek = Text.urlEncode(tostring(k))
        local ev
        if k == "item_ids" then
            ev = (Text.urlEncode(vs):gsub("%%2C", ","))
        else
            ev = Text.urlEncode(vs)
            ev = ev:gsub("%%2A", "*"):gsub("%%2B", "+")
        end
        parts[#parts + 1] = ek .. "=" .. ev
    end
    for _, k in ipairs(order) do
        if params[k] ~= nil then add(k, params[k]) end
    end
    for k, v in pairs(params) do
        add(k, v)
    end
    return table.concat(parts, "&")
end

---@param device table
---@param ts_ms number|nil
---@return table
function Crypto.build_unsigned_headers(device, ts_ms)
    ts_ms = ts_ms or (os.time() * 1000)
    local vc = device.version_code or "73733"
    local rom = tostring(device.rom_version or "S643.217451.03386707"):match("^[^%+]+") or ""
    local ua = string.format(
        "com.dragon.read.oversea.gp/%s (Linux; U; Android %s; zh_CN; %s; Build/%s;tt-ok/3.12.13.4-tiktok)",
        vc, device.os_version or "12", device.device_type or "P30", rom)
    local rnd = ""
    do
        local f = io.open("/dev/urandom", "rb")
        if f then
            local d = f:read(4)
            f:close()
            if d then rnd = Aes.to_hex(d) end
        end
        if rnd == "" then rnd = string.format("%08x", math.random(0, 0xffffffff)) end
    end
    return {
        ["User-Agent"] = ua,
        ["Accept"] = "application/json; charset=utf-8,application/x-protobuf",
        ["Accept-Encoding"] = "identity",
        ["sdk-version"] = "2",
        ["passport-sdk-version"] = "50564",
        ["lc"] = "101",
        ["x-tt-store-region"] = "cn-zj",
        ["x-tt-store-region-src"] = "did",
        ["x-vc-bdturing-sdk-version"] = "3.7.2.cn",
        ["x-xs-from-web"] = "0",
        ["X-Ss-Req-Ticket"] = tostring(ts_ms),
        ["x-reading-request"] = tostring(ts_ms) .. "-" .. rnd,
        ["Cookie"] = "store-region=cn-zj; store-region-src=did; install_id="
            .. tostring(device.install_id),
    }
end

Crypto.HARDCODED_KEY_HEX = "ac25c67ddd8f38c1b37a2348828e222e"
Crypto.HOST = "api5-normal-sinfonlinec.fqnovel.com"
Crypto.BATCH_FULL_PATH = "/reading/reader/batch_full/v"
Crypto.REGISTERKEY_PATH = "/reading/crypt/registerkey"

return Crypto
