local JSON = require("json")
local Limits = require("limits")
local SearchPlan = require("search_plan")
local Text = require("text")

local Contract = {}
local VERSION = 4

local function count(value)
    return type(value) == "string" and Text.count(value) or nil
end

local function bounded(value, maximum, allow_empty)
    local length = count(value)
    return length and length <= maximum and (allow_empty or length > 0)
end

local function exact_keys(value, expected)
    if type(value) ~= "table" then return false end
    local count_keys = 0
    for key in pairs(value) do if not expected[key] then return false end; count_keys = count_keys + 1 end
    local expected_count = 0
    for _ in pairs(expected) do expected_count = expected_count + 1 end
    return count_keys == expected_count
end

local function selection_kind(selected_text)
    local words = 0
    for _ in selected_text:gmatch("%S+") do words = words + 1 end
    return words <= 1 and "word" or (words <= 12 and "phrase" or "passage")
end

local function valid_snapshot(snapshot)
    local valid_strategy = snapshot.context_strategy == "sentence" or snapshot.context_strategy == "sentence_clipped" or snapshot.context_strategy == "word_window"
    return type(snapshot) == "table" and bounded(snapshot.selected_text, Limits.PRODUCT_SELECTED_TEXT)
        and bounded(snapshot.title, Limits.BOOK_TITLE, true) and bounded(snapshot.authors, Limits.BOOK_AUTHOR, true)
        and bounded(snapshot.language, Limits.BOOK_LANGUAGE, true) and bounded(snapshot.format, Limits.BOOK_FORMAT, true)
        and bounded(snapshot.chapter, Limits.CHAPTER_TITLE, true) and bounded(snapshot.immediate_before, Limits.CONTEXT_FIELD_SCALARS, true)
        and bounded(snapshot.immediate_after, Limits.CONTEXT_FIELD_SCALARS, true) and bounded(snapshot.adjacent_before, Limits.CONTEXT_FIELD_SCALARS, true)
        and bounded(snapshot.adjacent_after, Limits.CONTEXT_FIELD_SCALARS, true) and valid_strategy
end

function Contract.buildInitialRequest(snapshot)
    local book = { title = snapshot.title }
    if snapshot.authors ~= "" then book.author = snapshot.authors end
    if snapshot.language ~= "" then book.language = snapshot.language end
    if snapshot.format ~= "" then book.format = snapshot.format end
    local reading = { context = { strategy = snapshot.context_strategy,
        immediateText = { before = snapshot.immediate_before, after = snapshot.immediate_after },
        adjacentText = { before = snapshot.adjacent_before, after = snapshot.adjacent_after } } }
    if snapshot.chapter ~= "" then reading.chapter = { title = snapshot.chapter } end
    return { version = VERSION, selection = { text = snapshot.selected_text, kind = selection_kind(snapshot.selected_text) }, book = book, reading = reading, preferences = { level = "simple" } }
end

local function encode(value)
    local ok, encoded = pcall(JSON.encode, value)
    if not ok or type(encoded) ~= "string" then return nil, "invalid_local_request" end
    if #encoded > Limits.REQUEST_BODY_BYTES then return nil, "request_too_large" end
    return encoded
end

function Contract.encodeInitialRequest(snapshot)
    if not valid_snapshot(snapshot) then return nil, "invalid_local_request" end
    return encode(Contract.buildInitialRequest(snapshot))
end

local function valid_explanation(value)
    return type(value) == "table" and exact_keys(value, { explanation = true, relatedTerms = true })
        and bounded(value.explanation, Limits.EXPLANATION) and type(value.relatedTerms) == "table"
        and #value.relatedTerms <= Limits.RELATED_TERMS
        and (function()
            for _, term in ipairs(value.relatedTerms) do
                if not bounded(term, Limits.RELATED_TERM) then return false end
            end
            return true
        end)()
end

local function error_result(code, retryable, retry_after)
    return { kind = "error", code = code, retryable = retryable == true, retry_after = retry_after }
end

local function parse_transport(result)
    if type(result) ~= "table" then return nil, error_result("invalid_response", false) end
    if result.kind == "transport_error" then return nil, error_result(result.code, true) end
    if result.kind == "client_error" then return nil, error_result(result.code, false) end
    if result.kind ~= "http_response" or type(result.status) ~= "number" or type(result.body) ~= "string" then return nil, error_result("invalid_response", false) end
    local ok, response = pcall(JSON.decode, result.body)
    if result.status == 429 then return nil, error_result("rate_limited", true, result.retry_after) end
    if ok and type(response) == "table" and response.version == VERSION and type(response.error) == "table"
        and exact_keys(response.error, { code = true, message = true, retryable = true }) then
        if response.error.code == "timeout" then return nil, error_result("timeout", true) end
        if response.error.code == "service_unavailable" then return nil, error_result("service_unavailable", response.error.retryable, result.retry_after) end
        if response.error.code == "invalid_request" then return nil, error_result("request_rejected", false) end
        return nil, error_result("service_unavailable", response.error.retryable, result.retry_after)
    end
    if result.status >= 500 then return nil, error_result("service_unavailable", true) end
    if result.status >= 400 then return nil, error_result("request_rejected", false) end
    if result.status ~= 200 or not ok or type(response) ~= "table" then return nil, error_result("invalid_response", false) end
    return response
end

function Contract.parseInitialResult(result)
    local response, failure = parse_transport(result)
    if not response then return failure end
    if response.version ~= VERSION or not bounded(response.requestId, Limits.REQUEST_ID) or not exact_keys(response, { version = true, requestId = true, outcome = true }) then return error_result("invalid_response", false) end
    local outcome = response.outcome
    if type(outcome) ~= "table" then return error_result("invalid_response", false) end
    if outcome.type == "answer" and exact_keys(outcome, { type = true, explanation = true }) and valid_explanation(outcome.explanation) then
        return { kind = "answer", request_id = response.requestId, explanation = outcome.explanation }
    end
    if outcome.type == "search" and exact_keys(outcome, { type = true, plan = true }) then
        local plan = SearchPlan.normalize(outcome.plan)
        if not plan then return error_result("invalid_response", false) end
        for index, query in ipairs(plan.queries) do
            local supplied = outcome.plan.queries[index]
            if not exact_keys(supplied, { id = true, text = true, requestedScope = true, policyScope = true, policyReason = true })
                or supplied.id ~= query.id or supplied.text ~= query.text or supplied.requestedScope ~= query.requestedScope
                or supplied.policyScope ~= query.policyScope or supplied.policyReason ~= query.policyReason then return error_result("invalid_response", false) end
        end
        return { kind = "search", request_id = response.requestId, plan = plan }
    end
    return error_result("invalid_response", false)
end

function Contract.buildCompletionRequest(snapshot, initial_request_id, plan, searches)
    return { version = VERSION, originalRequestId = initial_request_id, original = Contract.buildInitialRequest(snapshot), retrieval = {
        bookMode = plan.bookMode, classificationBasis = plan.classificationBasis, searches = searches,
    } }
end

function Contract.encodeCompletionRequest(snapshot, initial_request_id, plan, searches)
    if not valid_snapshot(snapshot) or not bounded(initial_request_id, Limits.REQUEST_ID) or type(plan) ~= "table" or type(searches) ~= "table" then return nil, "invalid_local_request" end
    return encode(Contract.buildCompletionRequest(snapshot, initial_request_id, plan, searches))
end

function Contract.parseCompletionResult(result)
    local response, failure = parse_transport(result)
    if not response then return failure end
    if response.version ~= VERSION or not bounded(response.requestId, Limits.REQUEST_ID)
        or not exact_keys(response, { version = true, requestId = true, explanation = true }) or not valid_explanation(response.explanation) then return error_result("invalid_response", false) end
    return { kind = "success", request_id = response.requestId, explanation = response.explanation }
end

return Contract
