local Limits = require("limits")
local RetrievalPolicy = require("retrieval_policy")
local Text = require("text")
local util = require("util")

local SearchPlan = {}

local function clean(value)
    if type(value) ~= "string" then return nil end
    local normalized = util.cleanupSelectedText(value)
    if normalized == "" or normalized:find("[%z\1-\31\127]") then return nil end
    if (Text.count(normalized) or math.huge) > Limits.QUERY_SCALARS then return nil end
    local words = 0
    for _ in normalized:gmatch("%S+") do words = words + 1 end
    if words > Limits.QUERY_WORDS then return nil end
    return normalized
end

function SearchPlan.normalize(raw)
    if type(raw) ~= "table" or type(raw.bookMode) ~= "string" or type(raw.classificationBasis) ~= "string"
        or type(raw.queries) ~= "table" or #raw.queries < 1 or #raw.queries > Limits.RETRIEVAL_QUERIES
        or (Text.count(raw.classificationBasis) or math.huge) == 0 or (Text.count(raw.classificationBasis) or math.huge) > Limits.CLASSIFICATION_BASIS then return nil end
    local total, seen, queries = 0, {}, {}
    for index, item in ipairs(raw.queries) do
        if type(item) ~= "table" or type(item.text) ~= "string" or type(item.requestedScope) ~= "string" then return nil end
        local text = clean(item.text)
        local policy_scope, policy_reason = RetrievalPolicy.clamp(raw.bookMode, item.requestedScope)
        if not text or not policy_scope then return nil end
        local key = text:lower()
        if seen[key] then return nil end
        seen[key] = true
        total = total + (Text.count(text) or math.huge)
        if total > Limits.TOTAL_QUERY_SCALARS then return nil end
        queries[#queries + 1] = { id = "q" .. index, text = text, requestedScope = item.requestedScope, policyScope = policy_scope, policyReason = policy_reason }
    end
    return { bookMode = raw.bookMode, classificationBasis = raw.classificationBasis, queries = queries }
end

return SearchPlan
