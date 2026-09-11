local RetrievalPolicy = {}

local MODES = { reference = true, narrative = true, uncertain = true }
local SCOPES = { before_selection = true, whole_book = true }

function RetrievalPolicy.clamp(book_mode, requested_scope)
    if not MODES[book_mode] or not SCOPES[requested_scope] then return nil end
    if book_mode == "narrative" and requested_scope == "whole_book" then
        return "before_selection", "narrative_guard"
    end
    if book_mode == "uncertain" and requested_scope == "whole_book" then
        return "before_selection", "uncertain_guard"
    end
    return requested_scope, "model_requested"
end

function RetrievalPolicy.canUseWholeBook(book_mode, policy_scope)
    return book_mode == "reference" and policy_scope == "whole_book"
end

function RetrievalPolicy.isExecutedScopeAllowed(policy_scope, executed_scope)
    return policy_scope == executed_scope or (policy_scope == "whole_book" and executed_scope == "before_selection")
end

return RetrievalPolicy
