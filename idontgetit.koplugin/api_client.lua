local ffi = require("ffi")
local FFIUtil = require("ffi/util")
local JSON = require("json")
local UIManager = require("ui/uimanager")
local Limits = require("limits")

local ApiClient = {}

local ENDPOINT = "https://context-explain-api.jere-lab.workers.dev/v3/explain/book"
local POLL_SECONDS = 0.1
local MAX_RESPONSE_BODY = Limits.RESPONSE_BODY_BYTES
local MAX_BACKGROUND_RESULT = 24 * 1024

function ApiClient.parseRetryAfter(headers)
    local value = headers and (headers["retry-after"] or headers["Retry-After"])
    if type(value) ~= "string" or not value:match("^%d+%.?%d*$") then return nil end
    local seconds = tonumber(value)
    if not seconds then return nil end
    return math.max(1, math.min(3600, seconds))
end

local function read_available(fd, maximum)
    local chunks, size = {}, 0
    while true do
        local available = FFIUtil.getNonBlockingReadSize(fd)
        if not available or available <= 0 then break end
        local to_read = math.min(available, maximum - size)
        if to_read <= 0 then return table.concat(chunks), true end
        local buffer = ffi.new("char[?]", to_read)
        local bytes_read = tonumber(ffi.C.read(fd, buffer, to_read))
        if not bytes_read or bytes_read <= 0 then break end
        chunks[#chunks + 1] = ffi.string(buffer, bytes_read)
        size = size + bytes_read
        if available > bytes_read then return table.concat(chunks), true end
    end
    return table.concat(chunks), false
end

local function perform_request(endpoint, request_body)
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local response_chunks, response_size, exceeded = {}, 0, false
    local function bounded_sink(chunk)
        if not chunk then return 1 end
        if response_size + #chunk > MAX_RESPONSE_BODY then exceeded = true; return nil, "response body exceeds limit" end
        response_size = response_size + #chunk
        response_chunks[#response_chunks + 1] = chunk
        return 1
    end
    socketutil:set_timeout(10, 30)
    local success, status, headers = https.request {
        url = endpoint, method = "POST",
        headers = { ["Accept"] = "application/json", ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#request_body) },
        source = ltn12.source.string(request_body), sink = bounded_sink,
    }
    socketutil:reset_timeout()
    if exceeded then return { kind = "client_error", code = "invalid_background_result" } end
    if not success then
        if status == "timeout" then return { kind = "transport_error", code = "timeout" } end
        local detail = tostring(status):lower()
        if detail:find("network is unreachable", 1, true) or detail:find("network unreachable", 1, true) then
            return { kind = "transport_error", code = "network_unavailable" }
        end
        return { kind = "transport_error", code = "connection_failed" }
    end
    if type(status) ~= "number" then return { kind = "client_error", code = "invalid_background_result" } end
    local seconds = ApiClient.parseRetryAfter(headers)
    return { kind = "http_response", status = status, body = table.concat(response_chunks), retry_after = seconds }
end

function ApiClient.request(endpoint, request_body, on_complete)
    if type(endpoint) ~= "string" or endpoint == "" then
        if on_complete then on_complete({ kind = "client_error", code = "invalid_endpoint" }) end
        return function() end
    end
    local pid, read_fd = FFIUtil.runInSubProcess(function(_, write_fd)
        local ok, result = xpcall(function() return perform_request(endpoint, request_body) end, debug.traceback)
        FFIUtil.writeToFD(write_fd, JSON.encode(ok and { ok = true, result = result } or { ok = false }), true)
    end, true)
    if not pid then
        if on_complete then on_complete({ kind = "client_error", code = "background_failure" }) end
        return function() end
    end
    local active, finalized, standby_prevented = true, false, true
    local response_data, poll = "", nil
    UIManager:preventStandby()
    local function finalize(cancelled)
        if finalized then return false end
        finalized, active = true, false
        if poll then UIManager:unschedule(poll) end
        if cancelled then FFIUtil.terminateSubProcess(pid) end
        ffi.C.close(read_fd)
        if standby_prevented then UIManager:allowStandby(); standby_prevented = false end
        return true
    end
    local function complete(result, terminate_child)
        if finalize(terminate_child) and on_complete then on_complete(result) end
    end
    local function append_available()
        local chunk, exceeded = read_available(read_fd, MAX_BACKGROUND_RESULT - #response_data)
        response_data = response_data .. chunk
        return not exceeded and #response_data <= MAX_BACKGROUND_RESULT
    end
    poll = function()
        if not active then return end
        if not append_available() then complete({ kind = "client_error", code = "invalid_background_result" }, true); return end
        if FFIUtil.isSubProcessDone(pid) then
            local ok, envelope = pcall(JSON.decode, response_data)
            if not ok or type(envelope) ~= "table" or envelope.ok ~= true or type(envelope.result) ~= "table" then
                complete({ kind = "client_error", code = "invalid_background_result" })
            else
                complete(envelope.result)
            end
        else
            UIManager:scheduleIn(POLL_SECONDS, poll)
        end
    end
    UIManager:scheduleIn(POLL_SECONDS, poll)
    return function() finalize(true) end
end

function ApiClient.explain(request_body, on_complete)
    return ApiClient.request(ENDPOINT, request_body, on_complete)
end

return ApiClient
