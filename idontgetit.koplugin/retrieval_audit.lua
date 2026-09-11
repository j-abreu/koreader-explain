local RetrievalAudit = {}

function RetrievalAudit.start(session_id)
    return { session_id = session_id, status = "started", decision = nil, searches = nil, completion = nil }
end

function RetrievalAudit.format(audit)
    if not audit then return "No retrieval session has run for this open book." end
    local sections = { "Session\nID: " .. tostring(audit.session_id) .. "\nStatus: " .. tostring(audit.status) }
    if audit.decision then
        local decision = audit.decision
        sections[#sections + 1] = "Initial decision\nRequest ID: " .. tostring(decision.request_id) .. "\nOutcome: " .. decision.type
        if decision.plan then
            sections[#sections + 1] = "Book mode\n" .. decision.plan.bookMode .. "\n" .. decision.plan.classificationBasis
            local queries = {}
            for _, query in ipairs(decision.plan.queries) do
                queries[#queries + 1] = string.format("%s\nRequested: %s\nPolicy: %s (%s)", query.text, query.requestedScope, query.policyScope, query.policyReason)
            end
            sections[#sections + 1] = "Requested searches\n" .. table.concat(queries, "\n\n")
        end
    end
    if audit.searches then
        local entries = {}
        for _, search in ipairs(audit.searches) do
            local excerpts = {}
            for _, match in ipairs(search.matches or {}) do excerpts[#excerpts + 1] = "[" .. match.relation .. "] " .. match.text end
            entries[#entries + 1] = string.format("%s\nExecuted: %s\nAuthorization: %s\nStatus: %s\nCandidates: %d%s\nExcerpts:\n%s", search.text, search.executedScope, search.authorization, search.status, search.candidateCount or 0, search.candidateLimitReached and " (cap reached)" or "", #excerpts > 0 and table.concat(excerpts, "\n\n") or "None")
        end
        sections[#sections + 1] = "Local execution\n" .. table.concat(entries, "\n\n")
    end
    if audit.completion then sections[#sections + 1] = "Completion\nRequest ID: " .. tostring(audit.completion.request_id or "not sent") .. "\nStatus: " .. tostring(audit.completion.status) end
    return table.concat(sections, "\n\n")
end

return RetrievalAudit
