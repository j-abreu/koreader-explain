local Lifecycle = {}
Lifecycle.__index = Lifecycle

function Lifecycle.new()
    return setmetatable({ next_id = 0, active = nil }, Lifecycle)
end

function Lifecycle:start(snapshot)
    if self.active then return nil end
    self.next_id = self.next_id + 1
    local invocation = { id = self.next_id, snapshot = snapshot, phase = "scheduled" }
    self.active = invocation
    return invocation
end

function Lifecycle:isActive(invocation)
    return self.active == invocation and invocation.phase ~= "cancelled" and invocation.phase ~= "completed"
end

function Lifecycle:finish(invocation, phase)
    if not self:isActive(invocation) then return false end
    invocation.phase = phase
    self.active = nil
    return true
end

return Lifecycle
