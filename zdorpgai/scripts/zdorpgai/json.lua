-- Minimal pure-Lua JSON encoder/decoder for OpenMW
-- Handles: nil, bool, number, string, arrays, objects

local json = {}

-- An empty Lua table is ambiguous; tables made with json.array() always encode as JSON arrays
local array_mt = {}

function json.array(t)
    return setmetatable(t or {}, array_mt)
end

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local encode_value -- forward declaration

local escape_char_map = {
    ['\\'] = '\\\\',
    ['"']  = '\\"',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function encode_string(val)
    return '"' .. val:gsub('[\\"\b\f\n\r\t]', escape_char_map) .. '"'
end

local function is_array(t)
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function encode_table(val)
    if getmetatable(val) == array_mt or #val > 0 or (next(val) ~= nil and is_array(val)) then
        local parts = {}
        for i = 1, #val do
            parts[i] = encode_value(val[i])
        end
        return '[' .. table.concat(parts, ',') .. ']'
    elseif next(val) == nil then
        return '{}'
    else
        local parts = {}
        for k, v in pairs(val) do
            parts[#parts + 1] = encode_string(tostring(k)) .. ':' .. encode_value(v)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
end

encode_value = function(val)
    local t = type(val)
    if val == nil then
        return 'null'
    elseif t == 'boolean' then
        return val and 'true' or 'false'
    elseif t == 'number' then
        if val ~= val then return 'null' end
        if val == math.huge then return '1e999' end
        if val == -math.huge then return '-1e999' end
        return tostring(val)
    elseif t == 'string' then
        return encode_string(val)
    elseif t == 'table' then
        return encode_table(val)
    else
        return 'null'
    end
end

function json.encode(val)
    return encode_value(val)
end

-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local decode_value -- forward declaration

local escape_chars = {
    ['"']  = '"',
    ['\\'] = '\\',
    ['/']  = '/',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
}

local function skip_whitespace(str, pos)
    local byte
    while pos <= #str do
        byte = str:byte(pos)
        if byte == 32 or byte == 9 or byte == 10 or byte == 13 then
            pos = pos + 1
        else
            break
        end
    end
    return pos
end

local function decode_string(str, pos)
    pos = pos + 1
    local parts = {}
    while pos <= #str do
        local c = str:sub(pos, pos)
        if c == '"' then
            return table.concat(parts), pos + 1
        elseif c == '\\' then
            pos = pos + 1
            local esc = str:sub(pos, pos)
            if esc == 'u' then
                local hex = str:sub(pos + 1, pos + 4)
                local cp = tonumber(hex, 16)
                if cp then
                    if cp < 0x80 then
                        parts[#parts + 1] = string.char(cp)
                    elseif cp < 0x800 then
                        parts[#parts + 1] = string.char(
                            0xC0 + math.floor(cp / 64),
                            0x80 + (cp % 64)
                        )
                    else
                        parts[#parts + 1] = string.char(
                            0xE0 + math.floor(cp / 4096),
                            0x80 + math.floor((cp % 4096) / 64),
                            0x80 + (cp % 64)
                        )
                    end
                end
                pos = pos + 5
            else
                parts[#parts + 1] = escape_chars[esc] or esc
                pos = pos + 1
            end
        else
            parts[#parts + 1] = c
            pos = pos + 1
        end
    end
    return nil, pos
end

local function decode_number(str, pos)
    local start = pos
    if str:sub(pos, pos) == '-' then pos = pos + 1 end
    while pos <= #str and str:byte(pos) >= 48 and str:byte(pos) <= 57 do
        pos = pos + 1
    end
    if pos <= #str and str:sub(pos, pos) == '.' then
        pos = pos + 1
        while pos <= #str and str:byte(pos) >= 48 and str:byte(pos) <= 57 do
            pos = pos + 1
        end
    end
    if pos <= #str and (str:sub(pos, pos) == 'e' or str:sub(pos, pos) == 'E') then
        pos = pos + 1
        if pos <= #str and (str:sub(pos, pos) == '+' or str:sub(pos, pos) == '-') then
            pos = pos + 1
        end
        while pos <= #str and str:byte(pos) >= 48 and str:byte(pos) <= 57 do
            pos = pos + 1
        end
    end
    local num = tonumber(str:sub(start, pos - 1))
    return num, pos
end

local function decode_object(str, pos)
    pos = pos + 1
    pos = skip_whitespace(str, pos)
    local obj = {}
    if str:sub(pos, pos) == '}' then
        return obj, pos + 1
    end
    while true do
        pos = skip_whitespace(str, pos)
        if str:sub(pos, pos) ~= '"' then return nil, pos end
        local key
        key, pos = decode_string(str, pos)
        if not key then return nil, pos end
        pos = skip_whitespace(str, pos)
        if str:sub(pos, pos) ~= ':' then return nil, pos end
        pos = pos + 1
        local val
        val, pos = decode_value(str, pos)
        obj[key] = val
        pos = skip_whitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == '}' then
            return obj, pos + 1
        elseif c == ',' then
            pos = pos + 1
        else
            return nil, pos
        end
    end
end

local function decode_array(str, pos)
    pos = pos + 1
    pos = skip_whitespace(str, pos)
    local arr = {}
    if str:sub(pos, pos) == ']' then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = decode_value(str, pos)
        arr[#arr + 1] = val
        pos = skip_whitespace(str, pos)
        local c = str:sub(pos, pos)
        if c == ']' then
            return arr, pos + 1
        elseif c == ',' then
            pos = pos + 1
        else
            return nil, pos
        end
    end
end

decode_value = function(str, pos)
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then
        return decode_string(str, pos)
    elseif c == '{' then
        return decode_object(str, pos)
    elseif c == '[' then
        return decode_array(str, pos)
    elseif c == '-' or (c >= '0' and c <= '9') then
        return decode_number(str, pos)
    elseif str:sub(pos, pos + 3) == 'true' then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == 'false' then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == 'null' then
        return nil, pos + 4
    end
    return nil, pos
end

function json.decode(str)
    if type(str) ~= 'string' or #str == 0 then
        return nil
    end
    local ok, result = pcall(function()
        local val, pos = decode_value(str, 1)
        return val
    end)
    if ok then
        return result
    end
    return nil
end

return json
