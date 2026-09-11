local ApiClient = require("api_client")
local ConfirmBox = require("ui/widget/confirmbox")
local Contract = require("contract")
local ContractV4 = require("contract_v4")
local Context = require("context")
local ExplanationViewer = require("explanation_viewer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Lifecycle = require("lifecycle")
local BookSearch = require("book_search")
local RetrievalAudit = require("retrieval_audit")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local V4_INITIAL_ENDPOINT = "https://context-explain-api.jere-lab.workers.dev/v4/explain/book"
local V4_COMPLETION_ENDPOINT = "https://context-explain-api.jere-lab.workers.dev/v4/explain/book/complete"

local KindleAIDictionary = InputContainer:extend {
    name = "idontgetit",
    is_doc_only = true,
}

function KindleAIDictionary:init()
    self.lifecycle = Lifecycle.new()
    self.active_invocation = nil
    self.ui.highlight:addToHighlightDialog("idontgetit_explain", function(highlight)
        return {
            text = _("Explain in context"),
            callback = function()
                self:showCapturedContext(highlight)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("idontgetit_inspect", function(highlight)
        return {
            text = _("Inspect context"),
            callback = function()
                self:inspectCapturedContext(highlight)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("idontgetit_search_probe", function(highlight)
        return {
            text = _("Probe local search"),
            callback = function()
                self:probeLocalSearch(highlight)
            end,
        }
    end)

    if self.ui.dictionary then
        self.ui.dictionary:addToDictButtons {
            id = "idontgetit_explain",
            menu_text = _("Explain in context"),
            text = _("Explain in context"),
            insert_first = true,
            callback = function(dict_popup)
                self:showCapturedContext(dict_popup.highlight, dict_popup.word)
            end,
        }
        self.ui.dictionary:addToDictButtons {
            id = "idontgetit_inspect",
            menu_text = _("Inspect context"),
            text = _("Inspect context"),
            callback = function(dict_popup)
                self:inspectCapturedContext(dict_popup.highlight, dict_popup.word)
            end,
        }
        self.ui.dictionary:addToDictButtons {
            id = "idontgetit_search_probe",
            menu_text = _("Probe local search"),
            text = _("Probe local search"),
            insert_first = true,
            callback = function(dict_popup)
                self:probeLocalSearch(dict_popup.highlight, dict_popup.word)
            end,
        }
    end
end

function KindleAIDictionary:addToMainMenu(menu_items)
    menu_items.idontgetit_retrieval = {
        text = _("Explain in context"),
        sub_item_table = {
            {
                text = _("Inspect last retrieval"),
                callback = function()
                    ExplanationViewer.showLocalSearchProbe(RetrievalAudit.format(self.last_retrieval_audit))
                end,
            },
        },
    }
end

function KindleAIDictionary:probeLocalSearch(highlight, fallback_text)
    local snapshot, capture_error = Context.capture(self, highlight, fallback_text)
    if not snapshot then
        UIManager:show(InfoMessage:new { text = _(capture_error) })
        return
    end
    local completed, probe = Trapper:dismissableRunInSubprocess(function()
        return Context.probeLocalSearch(self, snapshot)
    end, nil)
    if not completed then
        UIManager:show(InfoMessage:new { text = _("Local search probe was cancelled.") })
        return
    end
    ExplanationViewer.showLocalSearchProbe(Context.formatLocalSearchProbe(probe))
end

function KindleAIDictionary:showCapturedContext(highlight, fallback_text)
    local snapshot, capture_error = Context.capture(self, highlight, fallback_text)
    if not snapshot then
        UIManager:show(InfoMessage:new {
            text = _(capture_error),
        })
        return
    end

    NetworkMgr:runWhenOnline(function() self:requestV4Initial(snapshot) end)
end

function KindleAIDictionary:collectPriorMentions(snapshot, on_complete)
    if not Context.shouldCollectPriorMentions(self, snapshot) then
        on_complete()
        return
    end

    local completed, mentions = Trapper:dismissableRunInSubprocess(function()
        return Context.collectPriorMentions(self, snapshot)
    end, nil)

    if completed and type(mentions) == "table" then
        snapshot.prior_mentions = mentions
    end
    -- Let KOReader remove the prior-mention message before the request-loading
    -- message is added, otherwise both centered InfoMessages can overlap.
    UIManager:nextTick(on_complete)
end

function KindleAIDictionary:inspectCapturedContext(highlight, fallback_text)
    local snapshot, capture_error = Context.capture(self, highlight, fallback_text)
    if not snapshot then
        UIManager:show(InfoMessage:new {
            text = _(capture_error),
        })
        return
    end

    ExplanationViewer.showRequestInspection(ContractV4.encodeInitialRequest(snapshot))
end

function KindleAIDictionary:requestV4Initial(snapshot)
    local request_body, request_error = ContractV4.encodeInitialRequest(snapshot)
    if not request_body then self:showLocalRequestError(request_error); return end
    local invocation = self.lifecycle:start(snapshot)
    if not invocation then UIManager:show(InfoMessage:new { text = _("An explanation request is already running.") }); return end
    self.active_invocation = invocation
    self.last_retrieval_audit = RetrievalAudit.start(invocation.id)
    local loading = InfoMessage:new { text = _("Explaining… (tap to cancel)"), dismiss_callback = function()
        if not invocation.programmatic_close then self:cancelInvocation(invocation, false) end
    end }
    invocation.loading = loading
    UIManager:show(loading)
    invocation.scheduled_start = function()
        if not self:isActiveInvocation(invocation) then return end
        invocation.scheduled_start = nil
        if not self.lifecycle:beginModelCall(invocation, "initial_request") then self:cancelInvocation(invocation, true); return end
        local cancel_transport = ApiClient.request(V4_INITIAL_ENDPOINT, request_body, function(result)
            self:completeV4Initial(invocation, result)
        end)
        if self:isActiveInvocation(invocation) then invocation.cancel_transport = cancel_transport else cancel_transport() end
    end
    UIManager:nextTick(invocation.scheduled_start)
end

function KindleAIDictionary:completeV4Initial(invocation, transport_result)
    if not self:isActiveInvocation(invocation) then return end
    local result = ContractV4.parseInitialResult(transport_result)
    if result.kind == "answer" then
        self.last_retrieval_audit.status = "answered"
        self.last_retrieval_audit.decision = { type = "answer", request_id = result.request_id }
        self.lifecycle:finish(invocation, "answered")
        self.active_invocation = nil
        self:closeInvocationLoading(invocation)
        ExplanationViewer.show(result.explanation, function() self:requestV4Initial(invocation.snapshot) end)
        return
    end
    if result.kind ~= "search" or not self.lifecycle:transition(invocation, "awaiting_scope_confirmation") then
        self:cancelInvocation(invocation, true)
        self:showV4RequestError(invocation.snapshot, result)
        return
    end
    invocation.initial_request_id, invocation.plan = result.request_id, result.plan
    self.last_retrieval_audit.status = "searching"
    self.last_retrieval_audit.decision = { type = "search", request_id = result.request_id, plan = result.plan }
    self:closeInvocationLoading(invocation)
    self:authorizeV4Search(invocation)
end

function KindleAIDictionary:authorizeV4Search(invocation)
    local needs_whole_book = false
    for _, query in ipairs(invocation.plan.queries) do
        if query.policyScope == "whole_book" then needs_whole_book = true end
    end
    local function execute(whole_book)
        local authorizations = {}
        for _, query in ipairs(invocation.plan.queries) do
            authorizations[query.id] = query.policyScope == "whole_book"
                and (whole_book and "approved_whole_book" or "reader_downgrade") or "not_required"
        end
        self:runV4Search(invocation, authorizations)
    end
    if not needs_whole_book then execute(false); return end
    if self.whole_book_permission ~= nil then execute(self.whole_book_permission); return end
    UIManager:show(ConfirmBox:new {
        text = _("This explanation wants to search the whole book because it appears to be a textbook or reference book. Later sections may be included."),
        ok_text = _("Search whole book"), cancel_text = _("Search earlier text only"),
        ok_callback = function() self.whole_book_permission = true; execute(true) end,
        cancel_callback = function() self.whole_book_permission = false; execute(false) end,
    })
end

function KindleAIDictionary:runV4Search(invocation, authorizations)
    if not self.lifecycle:beginRetrieval(invocation) then self:cancelInvocation(invocation, true); return end
    local completed, searches = Trapper:dismissableRunInSubprocess(function()
        return BookSearch.execute(self, invocation.snapshot, invocation.plan, authorizations)
    end, nil)
    if not self:isActiveInvocation(invocation) then return end
    if not completed or type(searches) ~= "table" then self:cancelInvocation(invocation, true); return end
    invocation.searches = searches
    self.last_retrieval_audit.searches = searches
    self:requestV4Completion(invocation)
end

function KindleAIDictionary:requestV4Completion(invocation)
    local body, request_error = ContractV4.encodeCompletionRequest(invocation.snapshot, invocation.initial_request_id, invocation.plan, invocation.searches)
    if not body then self:cancelInvocation(invocation, true); self:showLocalRequestError(request_error); return end
    local loading = InfoMessage:new { text = _("Finishing explanation… (tap to cancel)"), dismiss_callback = function()
        if not invocation.programmatic_close then self:cancelInvocation(invocation, false) end
    end }
    invocation.loading = loading
    UIManager:show(loading)
    invocation.scheduled_start = function()
        if not self:isActiveInvocation(invocation) then return end
        invocation.scheduled_start = nil
        if not self.lifecycle:beginModelCall(invocation, "completion_request") then self:cancelInvocation(invocation, true); return end
        local cancel_transport = ApiClient.request(V4_COMPLETION_ENDPOINT, body, function(result)
            self:completeV4Completion(invocation, result)
        end)
        if self:isActiveInvocation(invocation) then invocation.cancel_transport = cancel_transport else cancel_transport() end
    end
    UIManager:nextTick(invocation.scheduled_start)
end

function KindleAIDictionary:completeV4Completion(invocation, transport_result)
    if not self:isActiveInvocation(invocation) then return end
    local result = ContractV4.parseCompletionResult(transport_result)
    if result.kind ~= "success" then
        self.last_retrieval_audit.status = "completion_failed"
        self.last_retrieval_audit.completion = { status = "failed" }
        self:cancelInvocation(invocation, true); self:showV4RequestError(invocation.snapshot, result); return
    end
    self.last_retrieval_audit.status = "completed"
    self.last_retrieval_audit.completion = { status = "completed", request_id = result.request_id }
    self.lifecycle:finish(invocation, "completed")
    self.active_invocation = nil
    self:closeInvocationLoading(invocation)
    ExplanationViewer.show(result.explanation, function() self:requestV4Initial(invocation.snapshot) end)
end

function KindleAIDictionary:showLocalRequestError(code)
    UIManager:show(InfoMessage:new {
        text = code == "request_too_large" and _("Request is too large to send.") or _("Request could not be created."),
    })
end

function KindleAIDictionary:requestExplanation(snapshot, request_body)
    if not request_body then
        request_body = select(1, Contract.encodeRequest(snapshot))
        if not request_body then
            self:showLocalRequestError("invalid_local_request")
            return
        end
    end
    local invocation = self.lifecycle:start(snapshot)
    if not invocation then
        UIManager:show(InfoMessage:new {
            text = _("An explanation request is already running."),
        })
        return
    end

    -- This assignment precedes nextTick so a second activation cannot queue work.
    self.active_invocation = invocation
    local loading = InfoMessage:new {
        text = _("Explaining… (tap to cancel)"),
        dismiss_callback = function()
            if not invocation.programmatic_close then
                self:cancelInvocation(invocation, false)
            end
        end,
    }
    invocation.loading = loading
    UIManager:show(loading)

    invocation.scheduled_start = function()
        if not self:isActiveInvocation(invocation) then return end
        invocation.scheduled_start = nil
        invocation.phase = "running"
        local cancel_transport = ApiClient.explain(request_body, function(result)
            self:completeInvocation(invocation, result)
        end)
        -- A startup failure may invoke its callback synchronously.
        if self:isActiveInvocation(invocation) then
            invocation.cancel_transport = cancel_transport
        else
            cancel_transport()
        end
    end
    UIManager:nextTick(invocation.scheduled_start)
end

function KindleAIDictionary:isActiveInvocation(invocation)
    return self.lifecycle:isActive(invocation)
end

function KindleAIDictionary:closeInvocationLoading(invocation)
    if not invocation.loading then return end
    invocation.programmatic_close = true
    invocation.loading.dismiss_callback = nil
    UIManager:close(invocation.loading)
    invocation.loading = nil
end

function KindleAIDictionary:cancelInvocation(invocation, close_loading)
    if not self:isActiveInvocation(invocation) then return end
    -- Invalidate before cancelling transport; any late callback now has no UI authority.
    self.lifecycle:finish(invocation, "cancelled")
    self.active_invocation = nil
    if invocation.scheduled_start then UIManager:unschedule(invocation.scheduled_start) end
    if invocation.cancel_transport then invocation.cancel_transport() end
    if close_loading then self:closeInvocationLoading(invocation) end
end

function KindleAIDictionary:completeInvocation(invocation, transport_result)
    if not self:isActiveInvocation(invocation) then return end
    self.lifecycle:finish(invocation, "completed")
    self.active_invocation = nil
    self:closeInvocationLoading(invocation)
    local result = Contract.parseResult(transport_result)
    if result.kind == "success" then
        ExplanationViewer.show(result.explanation, function()
            self:requestExplanation(invocation.snapshot)
        end)
    else
        self:showRequestError(invocation.snapshot, result)
    end
end

function KindleAIDictionary:requestErrorMessage(result)
    if result.code == "network_unavailable" or result.code == "connection_failed" then
        return _("Could not connect to the explanation service.")
    elseif result.code == "timeout" then
        return _("The explanation request timed out.")
    elseif result.code == "rate_limited" then
        if result.retry_after then
            return string.format(_("Too many requests. Try again in %g seconds."), result.retry_after)
        end
        return _("Too many requests. Please try again later.")
    elseif result.code == "service_unavailable" then
        return _("The explanation service is temporarily unavailable.")
    elseif result.code == "request_rejected" then
        return _("Request was rejected.")
    elseif result.code == "background_failure" then
        return _("Request could not be created.")
    end
    return _("Service returned an invalid response.")
end

function KindleAIDictionary:showRequestError(snapshot, result)
    local message = self:requestErrorMessage(result)
    if not result.retryable then
        UIManager:show(InfoMessage:new {
            text = message,
        })
        return
    end

    UIManager:show(ConfirmBox:new {
        text = message,
        ok_text = _("Retry"),
        ok_callback = function()
            self:requestExplanation(snapshot)
        end,
        cancel_text = _("Close"),
    })
end

function KindleAIDictionary:showV4RequestError(snapshot, result)
    local message = self:requestErrorMessage(result)
    if not result.retryable then UIManager:show(InfoMessage:new { text = message }); return end
    UIManager:show(ConfirmBox:new {
        text = message, ok_text = _("Retry"), cancel_text = _("Close"),
        ok_callback = function() self:requestV4Initial(snapshot) end,
    })
end

function KindleAIDictionary:onClose()
    self:cancelInvocation(self.active_invocation, true)
    self.last_retrieval_audit = nil
    self.whole_book_permission = nil
end

return KindleAIDictionary
