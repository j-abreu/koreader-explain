local JSON = require("json")
local Limits = require("limits")
local Text = require("text")

local Contract = {}
local VERSION = 1
local MAX_SELECTION = 700
local MAX_CONTEXT_SIDE = 600

local function exact_keys(value, expected)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do if not expected[key] then return false end end
    for key in pairs(expected) do if value[key] == nil then return false end end
    return true
end

local function non_empty_string(value, maximum)
    return type(value) == "string" and value ~= "" and #value <= maximum
end

local function parse_api_error(result)
    if type(result.body) ~= "string" then return nil end
    local ok, response = pcall(JSON.decode, result.body)
    if not ok or type(response) ~= "table" or response.version ~= VERSION
        or not exact_keys(response, { version = true, requestId = true, error = true }) then return nil end
    local error = response.error
    if type(error) ~= "table" or not exact_keys(error, { code = true, message = true, retryable = true })
        or not (error.code == "invalid_request" or error.code == "service_unavailable" or error.code == "timeout" or error.code == "internal_error")
        or not non_empty_string(error.message, Limits.ERROR_MESSAGE) or type(error.retryable) ~= "boolean"
        or not non_empty_string(response.requestId, Limits.REQUEST_ID) then return nil end
    return {
        kind = "error", code = error.code, message = error.message, request_id = response.requestId,
        retryable = error.retryable, retry_after = result.retry_after,
    }
end

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
    if result.kind == "http_response" then
        local api_error = parse_api_error(result)
        if api_error then return api_error end
    end
    if result.kind == "http_response" and result.status == 429 then return { kind = "error", code = "rate_limited", retryable = true, retry_after = result.retry_after, request_id = result.request_id } end
    if result.kind == "http_response" and type(result.status) == "number" and result.status >= 500 then return { kind = "error", code = "service_unavailable", retryable = true } end
    if result.kind == "http_response" and type(result.status) == "number" and result.status >= 400 then return { kind = "error", code = "request_rejected", retryable = false } end
    return { kind = "error", code = "invalid_response", retryable = false }
end

return Contract
