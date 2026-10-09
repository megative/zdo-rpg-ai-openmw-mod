-- IPC helpers for ZDORPG OpenMW mod
-- Reads incoming messages from VFS file, sends outgoing via print()
-- Protocol: DoubleFilesChannel-compatible (file-based + log-based)

local json = require('scripts.zdorpgai.json')

local ipc = {}

--- Read incoming messages from zdorpgai_to_mod.txt via VFS.
-- File format:
--   Line 1: session:$SESSION_ID
--   Lines 2+: JSON messages {id, type, responseTo?, data?}
-- @param vfs                the openmw.vfs module
-- @param lastSeenClientMsgId  last processed client message id (0 initially)
-- @param currentSessionId   session ID from last poll (nil if none yet)
-- @return messages, newLastSeenClientMsgId, sessionId, sessionChanged
--         or nil if file unreadable / empty
function ipc.readIncoming(vfs, lastSeenClientMsgId, currentSessionId)
    local ok, handle = pcall(vfs.open, 'zdorpgai_to_mod.txt')
    if not ok or not handle then
        return nil
    end

    local content = handle:read('*a')
    handle:close()

    if not content or #content == 0 then
        return nil
    end

    -- Parse session header from first line
    local firstNewline = content:find('\n')
    local header = firstNewline and content:sub(1, firstNewline - 1) or content
    local sessionId = header:match('^session:(.+)$')
    if not sessionId then
        return nil
    end

    local sessionChanged = (currentSessionId ~= sessionId)
    if sessionChanged then
        lastSeenClientMsgId = 0
    end

    local messages = {}
    if firstNewline then
        local rest = content:sub(firstNewline + 1)
        for line in rest:gmatch('[^\n]+') do
            local okDecode, msg = pcall(json.decode, line)
            if okDecode and msg and type(msg) == 'table' and msg.id and msg.id > lastSeenClientMsgId then
                messages[#messages + 1] = msg
                if msg.id > lastSeenClientMsgId then
                    lastSeenClientMsgId = msg.id
                end
            end
        end
    end

    if #messages == 0 and not sessionChanged then
        return nil
    end

    return messages, lastSeenClientMsgId, sessionId, sessionChanged
end

-- OpenMW's logger cuts output into 4 KB pieces and drops a byte at each cut, so longer messages go
-- out as several [ZDORPG_PART] lines that the client puts back together
local MAX_LINE_BYTES = 3000

-- Moves a cut back so that the next part doesn't start in the middle of a UTF-8 character
local function charBoundary(s, stop)
    while stop > 1 do
        local nextByte = s:byte(stop + 1)
        if not nextByte or nextByte < 0x80 or nextByte >= 0xC0 then break end
        stop = stop - 1
    end
    return stop
end

local function printMessage(encoded, id)
    if #encoded <= MAX_LINE_BYTES then
        print('[ZDORPG_MSG]' .. encoded)
        return
    end

    local parts = {}
    local pos = 1
    while pos <= #encoded do
        local stop = math.min(pos + MAX_LINE_BYTES - 1, #encoded)
        if stop < #encoded then stop = charBoundary(encoded, stop) end
        parts[#parts + 1] = string.sub(encoded, pos, stop)
        pos = stop + 1
    end
    for i, part in ipairs(parts) do
        print(string.format('[ZDORPG_PART]%d/%d/%d:%s', id, i, #parts, part))
    end
end

--- Send a message to the client via print() with [ZDORPG_MSG] prefix.
-- @param msgType    message type string
-- @param data       payload table (or nil)
-- @param responseTo optional id of the message being responded to
-- @param counter    current outgoing message counter
-- @return new counter value
function ipc.sendMessage(msgType, data, responseTo, counter)
    counter = counter + 1
    local msg = {
        id = counter,
        type = msgType,
    }
    if responseTo then
        msg.responseTo = responseTo
    end
    if data then
        msg.data = data
    end
    local okEnc, encoded = pcall(json.encode, msg)
    if okEnc and encoded then
        printMessage(encoded, counter)
    end
    return counter
end

--- Send an ack of the last processed client message via print().
-- @param lastProcessedClientMsgId  the id to ack
function ipc.sendAck(lastProcessedClientMsgId)
    print('[ZDORPG_ACK]' .. tostring(lastProcessedClientMsgId))
end

return ipc
