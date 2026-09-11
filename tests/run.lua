local root = (... and ... ~= "" and ...) or "."
package.path = root .. "/idontgetit.koplugin/?.lua;" .. package.path

local fixtures = {
    success = { version = 3, requestId = "request-1", explanation = { explanation = "A valid explanation.", relatedTerms = {} } },
    service_error = { version = 3, requestId = "request-2", error = { code = "service_unavailable", message = "Untrusted text", retryable = true } },
    timeout_error = { version = 3, requestId = "request-3", error = { code = "timeout", message = "Untrusted text", retryable = true } },
    invalid_schema = { version = 3, requestId = "request-4", explanation = { explanation = "", relatedTerms = {} } },
    v4_answer = { version = 4, requestId = "request-v4", outcome = { type = "answer", explanation = { explanation = "A valid v4 answer.", relatedTerms = {} } } },
    v4_search = { version = 4, requestId = "request-v4", outcome = { type = "search", plan = { bookMode = "narrative", classificationBasis = "Sequential fiction.", queries = { { id = "q1", text = "Mira key", requestedScope = "whole_book", policyScope = "before_selection", policyReason = "narrative_guard" } } } } },
}
package.preload.json = function()
    return {
        encode = function() return "{}" end,
        decode = function(value)
            if fixtures[value] then return fixtures[value] end
            error("invalid JSON")
        end,
    }
end

package.preload.util = function()
    return {
        splitToChars = function(value)
            local characters = {}
            for character in value:gmatch("[%z\1-\127\194-\244][\128-\191]*") do characters[#characters + 1] = character end
            return characters
        end,
        cleanupSelectedText = function(value) return value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") end,
    }
end

local Contract = require("contract")
local Context = require("context")
local Lifecycle = require("lifecycle")
local RetrievalPolicy = require("retrieval_policy")
local SearchPlan = require("search_plan")
local ContractV4 = require("contract_v4")
local cleanup = { close = 0, terminate = 0, prevent = 0, allow = 0, unschedule = 0 }
local ffi_stub = { C = { close = function() cleanup.close = cleanup.close + 1 end } }
local ffi_util_stub = {
    runInSubProcess = function() return 1, 2 end,
    terminateSubProcess = function() cleanup.terminate = cleanup.terminate + 1 end,
}
local ui_stub = {
    preventStandby = function() cleanup.prevent = cleanup.prevent + 1 end,
    allowStandby = function() cleanup.allow = cleanup.allow + 1 end,
    scheduleIn = function(_, _, action) cleanup.poll = action end,
    unschedule = function() cleanup.unschedule = cleanup.unschedule + 1 end,
}
package.preload["ffi"] = function() return ffi_stub end
package.preload["ffi/util"] = function() return ffi_util_stub end
package.preload["ui/uimanager"] = function() return ui_stub end
local ApiClient = require("api_client")

local function assert_equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function result(kind, status, body, retry_after)
    return Contract.parseResult { kind = kind, status = status, body = body, retry_after = retry_after }
end

assert_equal(result("http_response", 200, "success").kind, "success", "valid HTTP response")
assert_equal(result("http_response", 200, "service_error").code, "service_unavailable", "API error code")
assert_equal(result("http_response", 503, "timeout_error").code, "timeout", "API timeout code")
assert_equal(result("http_response", 200, "malformed").code, "invalid_response", "malformed JSON")
assert_equal(result("http_response", 200, "invalid_schema").code, "invalid_response", "invalid schema")
assert_equal(Contract.parseResult { kind = "transport_error", code = "connection_failed" }.retryable, true, "network failure retryability")
assert_equal(Contract.parseResult { kind = "transport_error", code = "timeout" }.code, "timeout", "transport timeout")
local limited = result("http_response", 429, "malformed", 60)
assert_equal(limited.code, "rate_limited", "rate limit")
assert_equal(limited.retry_after, 60, "retry-after")
assert_equal(result("http_response", 503, "malformed").retryable, true, "5xx retryability")
assert_equal(result("http_response", 400, "malformed").retryable, false, "4xx retryability")
assert_equal(ApiClient.parseRetryAfter { ["retry-after"] = "0.5" }, 1, "small retry-after clamp")
assert_equal(ApiClient.parseRetryAfter { ["Retry-After"] = "7200" }, 3600, "large retry-after clamp")
assert_equal(ApiClient.parseRetryAfter { ["retry-after"] = "Wed, 21 Oct" }, nil, "retry-after date is ignored")
assert_equal(Context.wordCount("one\ttwo  three"), 3, "portable word count")
assert_equal(Context.trimNearest("one two three four", 2, 100, true), "three four", "before keeps nearest words")
assert_equal(Context.trimNearest("one two three four", 2, 100, false), "one two", "after keeps nearest words")
assert_equal(Context.trimNearest("😀 😀 😀", 3, 3, true), "😀 😀", "scalar cap keeps nearest words")
assert_equal(select(1, RetrievalPolicy.clamp("narrative", "whole_book")), "before_selection", "narrative scope is clamped")
assert_equal(select(2, RetrievalPolicy.clamp("uncertain", "whole_book")), "uncertain_guard", "uncertain scope records guard")
local normalized_plan = SearchPlan.normalize({ bookMode = "narrative", classificationBasis = "Sequential fiction.", queries = { { text = " Mira key ", requestedScope = "whole_book" } } })
assert_equal(normalized_plan.queries[1].policyScope, "before_selection", "plan scope is clamped")
assert_equal(SearchPlan.normalize({ bookMode = "reference", classificationBasis = "Reference.", queries = { { text = "same", requestedScope = "before_selection" }, { text = " SAME ", requestedScope = "before_selection" } } }), nil, "duplicate plan queries are rejected")
assert_equal(ContractV4.parseInitialResult { kind = "http_response", status = 200, body = "v4_answer" }.kind, "answer", "v4 answer response")
assert_equal(ContractV4.parseInitialResult { kind = "http_response", status = 200, body = "v4_search" }.plan.queries[1].policyScope, "before_selection", "v4 search plan response")
local cancel = ApiClient.explain("request", function() error("cancelled requests must not complete") end)
cancel()
cancel()
assert_equal(cleanup.prevent, 1, "standby prevention")
assert_equal(cleanup.terminate, 1, "subprocess termination is idempotent")
assert_equal(cleanup.close, 1, "descriptor close is idempotent")
assert_equal(cleanup.allow, 1, "standby restoration is idempotent")
assert_equal(cleanup.unschedule, 1, "poll removal is idempotent")

local lifecycle = Lifecycle.new()
local first = lifecycle:start { selected_text = "first" }
assert(first, "first invocation starts")
assert_equal(lifecycle:start { selected_text = "duplicate" }, nil, "duplicate is blocked")
assert_equal(lifecycle:finish(first, "cancelled"), true, "cancellation finishes active invocation")
assert_equal(lifecycle:finish(first, "completed"), false, "stale callback is ignored")
local second = lifecycle:start { selected_text = "second" }
assert_equal(second.id, first.id + 1, "invocation IDs increase")
assert_equal(lifecycle:beginModelCall(second, "initial_request"), true, "initial model call begins")
assert_equal(lifecycle:beginRetrieval(second), true, "one retrieval round begins")
assert_equal(lifecycle:beginModelCall(second, "completion_request"), true, "completion model call begins")
assert_equal(lifecycle:beginModelCall(second, "completion_request"), false, "third model call is blocked")
assert_equal(lifecycle:beginRetrieval(second), false, "second retrieval round is blocked")
assert_equal(lifecycle:finish(second, "completed"), true, "completion clears active invocation")

print("koreader-explain tests passed")
