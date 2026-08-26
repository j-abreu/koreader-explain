local ffi = require("ffi")
local FFIUtil = require("ffi/util")
local JSON = require("json")
local UIManager = require("ui/uimanager")

local ApiClient = {}

local ENDPOINT = "https://i-dont-get-it-api.jere-lab.workers.dev/explain"
local POLL_SECONDS = 0.1

local function read_available(fd)
    local chunks = {}
    while true do
        local available = FFIUtil.getNonBlockingReadSize(fd)
        if not available or available <= 0 then
            break
        end

        local buffer = ffi.new("char[?]", available)
        local bytes_read = tonumber(ffi.C.read(fd, buffer, available))
        if not bytes_read or bytes_read <= 0 then
            break
        end
        chunks[#chunks + 1] = ffi.string(buffer, bytes_read)
    end
    return table.concat(chunks)
end

local function perform_request(request_body)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")

    socketutil:set_timeout(10, 30)
    local response_chunks = {}
    local _, status = https.request {
        url = ENDPOINT,
        method = "POST",
        headers = {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink = socketutil.table_sink(response_chunks),
    }
    socketutil:reset_timeout()

    return {
        status = tostring(status),
        body = table.concat(response_chunks),
    }
end

function ApiClient.explain(request_body, callbacks)
    callbacks = callbacks or {}

    local pid, read_fd = FFIUtil.runInSubProcess(function(_, write_fd)
        local ok, result = xpcall(function()
            return perform_request(request_body)
        end, debug.traceback)
        local envelope
        if ok then
            envelope = { ok = true, response = result }
        else
            envelope = { ok = false, error = tostring(result) }
        end
        FFIUtil.writeToFD(write_fd, JSON.encode(envelope), true)
    end, true)

    if not pid then
        if callbacks.on_error then
            callbacks.on_error(tostring(read_fd or "Unable to start the network request."))
        end
        return function() end
    end

    local active = true
    local response_data = ""
    UIManager:preventStandby()

    local function finish()
        if not active then
            return
        end
        active = false
        response_data = response_data .. read_available(read_fd)
        ffi.C.close(read_fd)
        UIManager:allowStandby()

        local ok, envelope = pcall(JSON.decode, response_data)
        if not ok or type(envelope) ~= "table" then
            if callbacks.on_error then
                callbacks.on_error("The background request returned an unreadable result.")
            end
        elseif envelope.ok ~= true then
            if callbacks.on_error then
                callbacks.on_error(envelope.error or "The network request failed.")
            end
        elseif callbacks.on_complete then
            callbacks.on_complete(envelope.response.body, envelope.response.status)
        end
    end

    local poll
    poll = function()
        if not active then
            return
        end
        response_data = response_data .. read_available(read_fd)
        if FFIUtil.isSubProcessDone(pid) then
            finish()
        else
            UIManager:scheduleIn(POLL_SECONDS, poll)
        end
    end
    UIManager:scheduleIn(POLL_SECONDS, poll)

    return function()
        if not active then
            return
        end
        active = false
        UIManager:unschedule(poll)
        FFIUtil.terminateSubProcess(pid)
        ffi.C.close(read_fd)
        UIManager:allowStandby()
    end
end

return ApiClient
