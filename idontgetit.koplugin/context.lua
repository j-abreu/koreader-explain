local util = require("util")

local Context = {}

local SURROUNDING_WORDS = 50
local MAX_SELECTION_CHARACTERS = 1000
local MAX_SURROUNDING_CHARACTERS = 450
local MAX_PRIOR_MENTIONS = 5
local MAX_PRIOR_MENTION_CHARACTERS = 280
local PRIOR_MENTION_CONTEXT_WORDS = 20

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

local function selected_term_count(selected_text)
    local count = 0
    for _ in selected_text:gmatch("%S+") do
        count = count + 1
        if count > 2 then
            return count
        end
    end
    return count
end

local function make_prior_mention(previous, matched, following)
    previous = clean(previous)
    matched = clean(matched)
    following = clean(following)

    if matched == "" then
        return ""
    end

    local matched_length = #util.splitToChars(matched)
    if matched_length >= MAX_PRIOR_MENTION_CHARACTERS then
        return truncate_characters(matched, MAX_PRIOR_MENTION_CHARACTERS, false)
    end

    local remaining = MAX_PRIOR_MENTION_CHARACTERS - matched_length
    local before_length = math.min(#util.splitToChars(previous), math.floor(remaining / 2))
    local after_length = math.min(#util.splitToChars(following), remaining - before_length)
    before_length = math.min(#util.splitToChars(previous), remaining - after_length)

    local before = truncate_characters(previous, before_length, true)
    local after = truncate_characters(following, after_length, false)
    return clean(table.concat({ before, matched, after }, " "))
end

function Context.shouldCollectPriorMentions(plugin, snapshot)
    local document = plugin and plugin.ui and plugin.ui.document
    return document
        -- CREngine backs EPUB and similar reflowable ebooks. Its XPointer API is
        -- required to ensure every excerpt is strictly earlier than the selection.
        and document.provider == "crengine"
        and type(document.findAllText) == "function"
        and type(document.compareXPointers) == "function"
        and snapshot.selection_start
        and selected_term_count(snapshot.selected_text) <= 2
end

function Context.collectPriorMentions(plugin, snapshot)
    if not Context.shouldCollectPriorMentions(plugin, snapshot) then
        return {}
    end

    local document = plugin.ui.document
    local ok, results = pcall(function()
        -- The current selection can be one of the first hits, so request one extra.
        return document:findAllText(snapshot.selected_text, true, PRIOR_MENTION_CONTEXT_WORDS, MAX_PRIOR_MENTIONS + 1, false)
    end)
    if not ok or type(results) ~= "table" then
        return {}
    end

    local mentions = {}
    for _, result in ipairs(results) do
        local is_before = result["end"] and document:compareXPointers(result["end"], snapshot.selection_start) == 1
        if is_before then
            local matched = table.concat({
                result.matched_word_prefix or "",
                result.matched_text or "",
                result.matched_word_suffix or "",
            })
            local excerpt = make_prior_mention(result.prev_text, matched, result.next_text)
            if excerpt ~= "" then
                mentions[#mentions + 1] = excerpt
                if #mentions == MAX_PRIOR_MENTIONS then
                    break
                end
            end
        end
    end

    return mentions
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
        selection_start = selected and selected.pos0 or nil,
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
    if snapshot.prior_mentions and #snapshot.prior_mentions > 0 then
        sections[#sections + 1] = "Earlier mentions\n" .. table.concat(snapshot.prior_mentions, "\n\n")
    end

    return table.concat(sections, "\n\n")
end

return Context
