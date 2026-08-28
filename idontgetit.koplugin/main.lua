local ApiClient = require("api_client")
local ConfirmBox = require("ui/widget/confirmbox")
local Contract = require("contract")
local Context = require("context")
local ExplanationViewer = require("explanation_viewer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KindleAIDictionary = InputContainer:extend {
    name = "idontgetit",
    is_doc_only = true,
}

function KindleAIDictionary:init()
    self.ui.highlight:addToHighlightDialog("idontgetit_explain", function(highlight)
        return {
            text = _("Explain in context"),
            callback = function()
                self:showCapturedContext(highlight)
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
    end
end

function KindleAIDictionary:showCapturedContext(highlight, fallback_text)
    local snapshot, capture_error = Context.capture(self, highlight, fallback_text)
    if not snapshot then
        UIManager:show(InfoMessage:new {
            text = _(capture_error),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        self:requestExplanation(snapshot)
    end)
end

function KindleAIDictionary:requestExplanation(snapshot)
    if self.cancel_request then
        UIManager:show(InfoMessage:new {
            text = _("An explanation request is already running."),
        })
        return
    end

    local loading = InfoMessage:new {
        text = _("Explaining…"),
    }
    UIManager:show(loading)

    UIManager:nextTick(function()
        self.cancel_request = ApiClient.explain(Contract.encodeRequest(snapshot), {
            on_complete = function(body, status)
                self.cancel_request = nil
                UIManager:close(loading)
                local explanation, response_error, retryable = Contract.parseResponse(body, status)
                if explanation then
                    ExplanationViewer.show(explanation, function()
                        self:requestExplanation(snapshot)
                    end)
                else
                    self:showRequestError(snapshot, response_error, retryable)
                end
            end,
            on_error = function(request_error)
                self.cancel_request = nil
                UIManager:close(loading)
                self:showRequestError(snapshot, request_error, true)
            end,
        })
    end)
end

function KindleAIDictionary:showRequestError(snapshot, message, retryable)
    if not retryable then
        UIManager:show(InfoMessage:new {
            text = _(message),
        })
        return
    end

    UIManager:show(ConfirmBox:new {
        text = _(message),
        ok_text = _("Retry"),
        ok_callback = function()
            self:requestExplanation(snapshot)
        end,
        cancel_text = _("Close"),
    })
end

function KindleAIDictionary:onClose()
    if self.cancel_request then
        self.cancel_request()
        self.cancel_request = nil
    end
end

return KindleAIDictionary
