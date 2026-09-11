local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local ExplanationViewer = {}

function ExplanationViewer.show(explanation, regenerate_callback)
    local sections = {
        explanation.explanation,
    }

    if #explanation.relatedTerms > 0 then
        sections[#sections + 1] = _("Related terms") .. "\n" .. table.concat(explanation.relatedTerms, ", ")
    end

    local viewer
    viewer = TextViewer:new {
        title = _("Explanation"),
        text = table.concat(sections, "\n\n"),
        show_menu = false,
        buttons_table = {
            {
                {
                    text = _("Regenerate"),
                    callback = function()
                        UIManager:close(viewer)
                        regenerate_callback()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        viewer:onClose()
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

function ExplanationViewer.showRequestInspection(request_json)
    local viewer
    viewer = TextViewer:new {
        title = _("Request preview"),
        text = request_json,
        show_menu = false,
        buttons_table = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        viewer:onClose()
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

return ExplanationViewer
