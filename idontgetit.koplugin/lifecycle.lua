local Lifecycle = {}
Lifecycle.__index = Lifecycle

function Lifecycle.new()
    return setmetatable({ next_id = 0, active = nil }, Lifecycle)
end

function Lifecycle:start(snapshot)
    if self.active then return nil end
    self.next_id = self.next_id + 1
    local invocation = { id = self.next_id, snapshot = snapshot, phase = "scheduled", retrieval_round_used = false, model_call_count = 0 }
    self.active = invocation
    return invocation
end

local ACTIVE_PHASES = {
    scheduled = true, running = true,
    captured = true, initial_scheduled = true, initial_request = true,
    awaiting_scope_confirmation = true, local_search = true,
    completion_scheduled = true, completion_request = true,
}

function Lifecycle:transition(invocation, phase)
    if self.active ~= invocation or not ACTIVE_PHASES[phase] then return false end
    invocation.phase = phase
    return true
end

function Lifecycle:beginModelCall(invocation, phase)
    if invocation.model_call_count >= 2 or not self:transition(invocation, phase) then return false end
    invocation.model_call_count = invocation.model_call_count + 1
    return true
end

function Lifecycle:beginRetrieval(invocation)
    if invocation.retrieval_round_used or not self:transition(invocation, "local_search") then return false end
    invocation.retrieval_round_used = true
    return true
end

function Lifecycle:isActive(invocation)
    return self.active == invocation and ACTIVE_PHASES[invocation.phase] == true
end

function Lifecycle:finish(invocation, phase)
    if not self:isActive(invocation) then return false end
    invocation.phase = phase
    self.active = nil
    return true
end

return Lifecycle
