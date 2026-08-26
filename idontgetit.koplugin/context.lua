local util = require("util")

local Context = {}

local SURROUNDING_WORDS = 50
local MAX_SELECTION_CHARACTERS = 1000
local MAX_SURROUNDING_CHARACTERS = 450

local function clean(value)
    if value == nil then
        return ""
    end

    return util.cleanupSelectedText(tostring(value))
end

local function truncate_characters(value, maximum, keep_end)
    local characters = util.splitToChars(value)
    if #characters <= maximum then
        return value
    end

    local result = {}
    local first = keep_end and (#characters - maximum + 1) or 1
    local last = keep_end and #characters or maximum
    for index = first, last do
        result[#result + 1] = characters[index]
    end
    return table.concat(result)
end

local function current_chapter(plugin, selected)
    local toc = plugin and plugin.ui and plugin.ui.toc
    if not toc then
        return ""
    end

    if selected and selected.pos0 and type(toc.getTocTitleByPage) == "function" then
        local ok, title = pcall(function()
            return toc:getTocTitleByPage(selected.pos0)
        end)
        if ok and title then
            return clean(title)
        end
    end

    if type(toc.getTocTitleOfCurrentPage) == "function" then
        local ok, title = pcall(function()
            return toc:getTocTitleOfCurrentPage()
        end)
        if ok and title then
            return clean(title)
        end
    end

    return ""
end

function Context.capture(plugin, highlight, fallback_text)
    local selected = highlight and highlight.selected_text
    local selected_text = clean((selected and selected.text) or fallback_text)

    if selected_text == "" then
        return nil, "No text is selected."
    end
    if #util.splitToChars(selected_text) > MAX_SELECTION_CHARACTERS then
        return nil, "The selection is too long to explain."
    end

    local before = ""
    local after = ""
    if type(highlight.getSelectedWordContext) == "function" then
        local ok, previous_context, next_context = pcall(function()
            return highlight:getSelectedWordContext(SURROUNDING_WORDS)
        end)
        if ok then
            before = truncate_characters(clean(previous_context), MAX_SURROUNDING_CHARACTERS, true)
            after = truncate_characters(clean(next_context), MAX_SURROUNDING_CHARACTERS, false)
        end
    end

    local props = {}
    local document = plugin and plugin.ui and plugin.ui.document
    if document and type(document.getProps) == "function" then
        local ok, document_props = pcall(function()
            return document:getProps()
        end)
        if ok and type(document_props) == "table" then
            props = document_props
        end
    end

    local authors = props.authors
    if type(authors) == "table" then
        authors = table.concat(authors, ", ")
    end

    return {
        selected_text = selected_text,
        before = before,
        after = after,
        title = truncate_characters(clean(props.title), 500, false),
        authors = clean(authors),
        language = truncate_characters(clean(props.language), 100, false),
        chapter = truncate_characters(current_chapter(plugin, selected), 500, false),
    }
end

function Context.formatForInspection(snapshot)
    local metadata = {}
    if snapshot.title ~= "" then
        metadata[#metadata + 1] = "Book: " .. snapshot.title
    end
    if snapshot.authors ~= "" then
        metadata[#metadata + 1] = "Author: " .. snapshot.authors
    end
    if snapshot.language ~= "" then
        metadata[#metadata + 1] = "Language: " .. snapshot.language
    end
    if snapshot.chapter ~= "" then
        metadata[#metadata + 1] = "Chapter: " .. snapshot.chapter
    end

    local surrounding = {}
    if snapshot.before ~= "" then
        surrounding[#surrounding + 1] = snapshot.before
    end
    surrounding[#surrounding + 1] = "[" .. snapshot.selected_text .. "]"
    if snapshot.after ~= "" then
        surrounding[#surrounding + 1] = snapshot.after
    end

    local sections = {
        "Selected text\n" .. snapshot.selected_text,
        "Surrounding context\n" .. table.concat(surrounding, " "),
    }
    if #metadata > 0 then
        sections[#sections + 1] = "Document metadata\n" .. table.concat(metadata, "\n")
    end

    return table.concat(sections, "\n\n")
end

return Context
