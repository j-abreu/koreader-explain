local Limits = require("limits")
local Text = require("text")
local util = require("util")

local BookSearch = {}

local function clean(value)
    return value == nil and "" or util.cleanupSelectedText(tostring(value))
end

local function excerpt(result)
    local matched = clean(table.concat({ result.matched_word_prefix or "", result.matched_text or "", result.matched_word_suffix or "" }))
    if matched == "" then return "" end
    local value = clean(table.concat({ result.prev_text or "", matched, result.next_text or "" }, " "))
    return Text.truncate(value, Limits.PRODUCT_EXCERPT, false) or ""
end

local function content_boundary(plugin, snapshot)
    local document, toc = plugin.ui.document, plugin.ui.toc
    if not toc or not snapshot.selection_start then return nil end
    if type(toc.fillToc) == "function" then pcall(function() toc:fillToc() end) end
    for _, item in ipairs(toc.toc or {}) do
        if item.xpointer and document:compareXPointers(item.xpointer, snapshot.selection_start) == 1 then return item.xpointer end
    end
end

local function relation(document, result, snapshot, boundary)
    if not result.start or not result["end"] then return nil end
    if boundary and document:compareXPointers(result["end"], boundary) == 1 then return nil end
    if document:compareXPointers(result["end"], snapshot.selection_start) == 1 then return "before" end
    if snapshot.selection_end and document:compareXPointers(snapshot.selection_end, result.start) == 1 then return "after" end
    return nil
end

local function choose_before(candidates)
    if #candidates == 0 then return {} end
    local choices = { candidates[1] }
    if #candidates > 2 then choices[#choices + 1] = candidates[#candidates - 1] end
    if #candidates > 1 then choices[#choices + 1] = candidates[#candidates] end
    return choices
end

local function choose_whole(before, after)
    local choices = {}
    if #before > 0 then choices[#choices + 1] = before[1] end
    if #before > 1 then choices[#choices + 1] = before[#before] end
    if #after > 0 then choices[#choices + 1] = after[1] end
    return choices
end

function BookSearch.execute(plugin, snapshot, plan, authorizations)
    local document = plugin and plugin.ui and plugin.ui.document
    if not document or document.provider ~= "crengine" or type(document.findAllText) ~= "function"
        or type(document.compareXPointers) ~= "function" or not snapshot.selection_start then return nil, "unsupported" end
    local boundary, global_count, executions = content_boundary(plugin, snapshot), 0, {}
    for _, query in ipairs(plan.queries) do
        local execution = { id = query.id, text = query.text, requestedScope = query.requestedScope, policyScope = query.policyScope,
            policyReason = query.policyReason, executedScope = query.policyScope, authorization = (authorizations and authorizations[query.id]) or "not_required",
            status = "failed", candidateCount = 0, candidateLimitReached = false, matches = {} }
        if execution.authorization == "reader_downgrade" then execution.executedScope = "before_selection" end
        if execution.executedScope == "whole_book" and execution.authorization ~= "approved_whole_book" then
            execution.executedScope, execution.authorization = "before_selection", "reader_downgrade"
        end
        local ok, results = pcall(function()
            return document:findAllText(query.text, true, 20, Limits.CANDIDATE_HITS - 1, false)
        end)
        if ok and type(results) == "table" then
            local inspected = math.min(#results, Limits.CANDIDATE_HITS)
            execution.candidateCount, execution.candidateLimitReached = inspected, #results > Limits.CANDIDATE_HITS
            local before, after = {}, {}
            for index, result in ipairs(results) do
                if index > inspected then break end
                local kind = relation(document, result, snapshot, boundary)
                local text = kind and excerpt(result) or ""
                if text ~= "" then
                    local candidate = { relation = kind, text = text }
                    if kind == "before" then before[#before + 1] = candidate elseif kind == "after" then after[#after + 1] = candidate end
                end
            end
            local selected = execution.executedScope == "before_selection" and choose_before(before) or choose_whole(before, after)
            local seen = {}
            for _, match in ipairs(selected) do
                local key = match.text:lower()
                if not seen[key] and global_count < Limits.EXCERPTS_TOTAL and #execution.matches < Limits.EXCERPTS_PER_QUERY then
                    seen[key] = true; execution.matches[#execution.matches + 1] = match; global_count = global_count + 1
                end
            end
            execution.status = inspected == 0 and "no_matches" or "ok"
        end
        executions[#executions + 1] = execution
    end
    return executions
end

return BookSearch
