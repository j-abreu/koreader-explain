local JSON = require("json")
local Limits = require("limits")
local Text = require("text")

local Contract = {}

local CONTRACT_VERSION = 3

local function non_empty_string(value, maximum)
    local length = Text.count(value)
    return length and length > 0 and length <= maximum
end

local function bounded_string(value, maximum)
    local length = Text.count(value)
    return length and length <= maximum
end

local function word_count(value)
    local count = 0
    for _ in value:gmatch("%S+") do count = count + 1 end
    return count
end

local function valid_context_side(immediate, adjacent)
    return word_count(immediate) + word_count(adjacent) <= Limits.CONTEXT_WORDS_MAX
        and (Text.count(immediate) or math.huge) + (Text.count(adjacent) or math.huge) <= Limits.CONTEXT_SCALARS_PER_SIDE
end

local function exact_keys(value, expected)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if not expected[key] then return false end
        count = count + 1
    end
    local expected_count = 0
    for _ in pairs(expected) do expected_count = expected_count + 1 end
    return count == expected_count
end

local function selection_kind(selected_text)
    local words = 0
    for _ in selected_text:gmatch("%S+") do
        words = words + 1
        if words > 12 then return "passage" end
    end
    return words <= 1 and "word" or "phrase"
end

function Contract.buildRequest(snapshot)
    local book = { title = snapshot.title }
    if snapshot.authors ~= "" then book.author = snapshot.authors end
    if snapshot.language ~= "" then book.language = snapshot.language end
    if snapshot.format ~= "" then book.format = snapshot.format end
    local reading = {
        context = {
            strategy = snapshot.context_strategy,
            immediateText = { before = snapshot.immediate_before, after = snapshot.immediate_after },
            adjacentText = { before = snapshot.adjacent_before, after = snapshot.adjacent_after },
        },
    }
    if snapshot.chapter ~= "" then reading.chapter = { title = snapshot.chapter } end
    if snapshot.prior_mentions and #snapshot.prior_mentions > 0 then
        local prior_mentions = {}
        for _, mention in ipairs(snapshot.prior_mentions) do prior_mentions[#prior_mentions + 1] = { text = mention } end
        reading.priorMentions = prior_mentions
    end
    return {
        version = CONTRACT_VERSION,
        selection = { text = snapshot.selected_text, kind = selection_kind(snapshot.selected_text) },
        book = book, reading = reading, preferences = { level = "simple" },
    }
end

function Contract.encodeRequest(snapshot)
    if type(snapshot) ~= "table" or not bounded_string(snapshot.selected_text, Limits.PRODUCT_SELECTED_TEXT)
        or not bounded_string(snapshot.title, Limits.BOOK_TITLE) or not bounded_string(snapshot.immediate_before, Limits.CONTEXT_FIELD_SCALARS)
        or not bounded_string(snapshot.immediate_after, Limits.CONTEXT_FIELD_SCALARS) or not bounded_string(snapshot.adjacent_before, Limits.CONTEXT_FIELD_SCALARS)
        or not bounded_string(snapshot.adjacent_after, Limits.CONTEXT_FIELD_SCALARS) or not bounded_string(snapshot.authors, Limits.BOOK_AUTHOR)
        or not bounded_string(snapshot.language, Limits.BOOK_LANGUAGE) or not bounded_string(snapshot.format, Limits.BOOK_FORMAT)
        or not bounded_string(snapshot.chapter, Limits.CHAPTER_TITLE)
        or (snapshot.context_strategy ~= "sentence" and snapshot.context_strategy ~= "sentence_clipped" and snapshot.context_strategy ~= "word_window")
        or not valid_context_side(snapshot.immediate_before, snapshot.adjacent_before)
        or not valid_context_side(snapshot.immediate_after, snapshot.adjacent_after)
        then
        return nil, "invalid_local_request"
    end
    local ok, encoded = pcall(JSON.encode, Contract.buildRequest(snapshot))
    if not ok or type(encoded) ~= "string" then return nil, "invalid_local_request" end
    if #encoded > Limits.REQUEST_BODY_BYTES then return nil, "request_too_large" end
    return encoded
end

local function validate_explanation(explanation)
    if not exact_keys(explanation, { explanation = true, relatedTerms = true }) then return false end
    if not non_empty_string(explanation.explanation, 4000) or type(explanation.relatedTerms) ~= "table"
        or #explanation.relatedTerms ~= 0 then return false end
    for _, term in ipairs(explanation.relatedTerms) do
        if not non_empty_string(term, 200) then return false end
    end
    return true
end

local function error_result(code, retryable, retry_after)
    return { kind = "error", code = code, retryable = retryable == true, retry_after = retry_after }
end

local function valid_error(response)
    local error = response.error
    if type(response) ~= "table" or response.version ~= CONTRACT_VERSION
        or not (exact_keys(response, { version = true, requestId = true, error = true })
            or exact_keys(response, { version = true, error = true })) then return false end
    if response.requestId ~= nil and not non_empty_string(response.requestId, Limits.REQUEST_ID) then return false end
    return type(error) == "table" and exact_keys(error, { code = true, message = true, retryable = true })
        and (error.code == "invalid_request" or error.code == "service_unavailable" or error.code == "timeout" or error.code == "internal_error")
        and non_empty_string(error.message, Limits.ERROR_MESSAGE) and type(error.retryable) == "boolean"
end

local function api_error(response, retry_after)
    local code = response.error.code
    if code == "timeout" then return error_result("timeout", true) end
    if code == "service_unavailable" then return error_result("service_unavailable", true, retry_after) end
    if code == "invalid_request" then return error_result("request_rejected", false) end
    return error_result("service_unavailable", response.error.retryable, retry_after)
end

-- Converts a trusted transport result into a presentation-safe result. Server text is
-- validated only to identify its stable code; it is never passed to the UI.
function Contract.parseResult(result)
    if type(result) ~= "table" then return error_result("invalid_response", false) end
    if result.kind == "transport_error" then return error_result(result.code, true) end
    if result.kind == "client_error" then return error_result(result.code, false) end
    if result.kind ~= "http_response" or type(result.status) ~= "number" or type(result.body) ~= "string" then
        return error_result("invalid_response", false)
    end
    local ok, response = pcall(JSON.decode, result.body)
    if result.status == 429 then return error_result("rate_limited", true, result.retry_after) end
    if ok and type(response) == "table" and valid_error(response) then return api_error(response, result.retry_after) end
    if result.status >= 500 and result.status <= 599 then return error_result("service_unavailable", true) end
    if result.status >= 400 and result.status <= 499 then return error_result("request_rejected", false) end
    if result.status ~= 200 or not ok or type(response) ~= "table" then return error_result("invalid_response", false) end
    if response.version ~= CONTRACT_VERSION or not non_empty_string(response.requestId, 200)
        or not validate_explanation(response.explanation) then return error_result("invalid_response", false) end
    return { kind = "success", explanation = response.explanation }
end

return Contract
