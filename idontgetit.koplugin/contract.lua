local JSON = require("json")

local Contract = {}

local CONTRACT_VERSION = 2

local function non_empty_string(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
end

local function exact_keys(value, expected)
    if type(value) ~= "table" then
        return false
    end

    local count = 0
    for key in pairs(value) do
        if not expected[key] then
            return false
        end
        count = count + 1
    end

    local expected_count = 0
    for _ in pairs(expected) do
        expected_count = expected_count + 1
    end
    return count == expected_count
end

local function selection_kind(selected_text)
    local words = 0
    for _ in selected_text:gmatch("%S+") do
        words = words + 1
        if words > 12 then
            return "passage"
        end
    end

    if words <= 1 then
        return "word"
    end
    return "phrase"
end

function Contract.buildRequest(snapshot)
    local book = {
        title = snapshot.title,
    }
    if snapshot.authors ~= "" then
        book.author = snapshot.authors
    end
    if snapshot.language ~= "" then
        book.language = snapshot.language
    end

    local reading = {
        surroundingText = {
            before = snapshot.before,
            after = snapshot.after,
        },
    }
    if snapshot.chapter ~= "" then
        reading.chapter = { title = snapshot.chapter }
    end
    if snapshot.prior_mentions and #snapshot.prior_mentions > 0 then
        local prior_mentions = {}
        for _, mention in ipairs(snapshot.prior_mentions) do
            prior_mentions[#prior_mentions + 1] = { text = mention }
        end
        reading.priorMentions = prior_mentions
    end

    return {
        version = CONTRACT_VERSION,
        selection = {
            text = snapshot.selected_text,
            kind = selection_kind(snapshot.selected_text),
        },
        book = book,
        reading = reading,
        preferences = {
            level = "simple",
        },
    }
end

function Contract.encodeRequest(snapshot)
    return JSON.encode(Contract.buildRequest(snapshot))
end

local function validate_explanation(explanation)
    if not exact_keys(explanation, {
        explanation = true,
        relatedTerms = true,
    }) then
        return false
    end

    if not non_empty_string(explanation.explanation, 4000)
        or type(explanation.relatedTerms) ~= "table"
        or #explanation.relatedTerms > 5 then
        return false
    end

    for _, term in ipairs(explanation.relatedTerms) do
        if not non_empty_string(term, 200) then
            return false
        end
    end
    return true
end

function Contract.parseResponse(body, status)
    local ok, response = pcall(JSON.decode, body)
    if not ok or type(response) ~= "table" then
        return nil, "The explanation service returned an unreadable response."
    end

    if tonumber(status) ~= 200 then
        local server_error = response.error
        if type(server_error) == "table" and non_empty_string(server_error.message, 500) then
            return nil, server_error.message, server_error.retryable == true
        end
        return nil, "The explanation service returned an error.", true
    end

    if response.version ~= CONTRACT_VERSION
        or not non_empty_string(response.requestId, 200)
        or not validate_explanation(response.explanation) then
        return nil, "The explanation service returned an invalid response."
    end

    return response.explanation
end

return Contract
