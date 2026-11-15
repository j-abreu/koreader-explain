local JSON = require("json")
local Limits = require("limits")
local Text = require("text")

local Contract = {}
local VERSION = 1
local MAX_SELECTION = 700
local MAX_CONTEXT_SIDE = 600

local function truncate(value, maximum)
    return Text.truncate(value or "", maximum) or ""
end

function Contract.encodeRequest(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.selected_text) ~= "string" then
        return nil, "invalid_local_request"
    end
    local selected = truncate(snapshot.selected_text, MAX_SELECTION)
    if selected == "" then return nil, "invalid_local_request" end
    local request = {
        version = VERSION,
        selection = { text = selected },
        reading = { context = {
            before = truncate(snapshot.immediate_before, MAX_CONTEXT_SIDE),
            after = truncate(snapshot.immediate_after, MAX_CONTEXT_SIDE),
        } },
    }
    local ok, encoded = pcall(JSON.encode, request)
    if not ok or type(encoded) ~= "string" then return nil, "invalid_local_request" end
    if #encoded > Limits.REQUEST_BODY_BYTES then return nil, "request_too_large" end
    return encoded
end

function Contract.parseResult(result)
    if type(result) ~= "table" then return { kind = "error", code = "invalid_response", retryable = false } end
    if result.kind == "downloaded_image" and type(result.path) == "string" and result.path:match("%.jpg$") then
        return { kind = "success", path = result.path }
    end
    if result.kind == "transport_error" then return { kind = "error", code = result.code, retryable = true } end
    if result.kind == "client_error" then return { kind = "error", code = result.code, retryable = false } end
    if result.kind == "http_response" and result.status == 429 then return { kind = "error", code = "rate_limited", retryable = true, retry_after = result.retry_after } end
    if result.kind == "http_response" and type(result.status) == "number" and result.status >= 500 then return { kind = "error", code = "service_unavailable", retryable = true } end
    if result.kind == "http_response" and type(result.status) == "number" and result.status >= 400 then return { kind = "error", code = "request_rejected", retryable = false } end
    return { kind = "error", code = "invalid_response", retryable = false }
end

return Contract
