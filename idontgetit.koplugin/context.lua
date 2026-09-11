local util = require("util")
local Limits = require("limits")
local Text = require("text")

local Context = {}

local SURROUNDING_WORDS = Limits.CONTEXT_WORDS_TARGET
local MAX_SELECTION_CHARACTERS = Limits.PRODUCT_SELECTED_TEXT
local MAX_SURROUNDING_CHARACTERS = Limits.CONTEXT_SCALARS_PER_SIDE
local MAX_PRIOR_MENTIONS = Limits.PRIOR_MENTIONS
local MAX_PRIOR_MENTION_CHARACTERS = Limits.PRODUCT_PRIOR_MENTION
local PRIOR_MENTION_CONTEXT_WORDS = 20

local function clean(value)
    if value == nil then
        return ""
    end

    return util.cleanupSelectedText(tostring(value))
end

local function truncate_characters(value, maximum, keep_end)
    return Text.truncate(value, maximum, keep_end) or ""
end

local function words(value)
    local result = {}
    for word in value:gmatch("%S+") do result[#result + 1] = word end
    return result
end

function Context.wordCount(value)
    return #words(value or "")
end

-- Keep complete normalized words nearest the selection and then enforce scalars.
function Context.trimNearest(value, maximum_words, maximum_scalars, keep_end)
    local result, source = {}, words(value or "")
    local first = keep_end and math.max(1, #source - maximum_words + 1) or 1
    local last = keep_end and #source or math.min(#source, maximum_words)
    for index = first, last do result[#result + 1] = source[index] end
    while #result > 0 and (Text.count(table.concat(result, " ")) or math.huge) > maximum_scalars do
        if keep_end then table.remove(result, 1) else table.remove(result) end
    end
    return table.concat(result, " ")
end

local function fallback_context(highlight)
    local before, after = "", ""
    if highlight and type(highlight.getSelectedWordContext) == "function" then
        local ok, previous_context, next_context = pcall(function()
            return highlight:getSelectedWordContext(SURROUNDING_WORDS)
        end)
        if ok then
            before = Context.trimNearest(clean(previous_context), Limits.CONTEXT_WORDS_TARGET, MAX_SURROUNDING_CHARACTERS, true)
            after = Context.trimNearest(clean(next_context), Limits.CONTEXT_WORDS_TARGET, MAX_SURROUNDING_CHARACTERS, false)
        end
    end
    return { strategy = "word_window", immediate_before = before, immediate_after = after, adjacent_before = "", adjacent_after = "" }
end

local function sentence_context(document, selected)
    if not (document and document.provider == "crengine" and selected and selected.pos0 and selected.pos1
        and type(document.extendXPointersToSentenceSegment) == "function" and type(document.getTextFromXPointers) == "function"
        and type(document.getPrevVisibleWordStart) == "function" and type(document.getNextVisibleWordEnd) == "function"
        and type(document.compareXPointers) == "function") then return nil end
    local extracted = false
    local function restore()
        if not extracted then return true end
        return pcall(function() document:getTextFromXPointers(selected.pos0, selected.pos1, true) end)
    end
    local ok, result = xpcall(function()
        local sentence = document:extendXPointersToSentenceSegment(selected.pos0, selected.pos1)
        if type(sentence) ~= "table" or type(sentence.text) ~= "string" or not sentence.pos0 or not sentence.pos1
            or document:compareXPointers(sentence.pos0, selected.pos0) ~= 1 and document:compareXPointers(sentence.pos0, selected.pos0) ~= 0
            or document:compareXPointers(selected.pos1, sentence.pos1) ~= 1 and document:compareXPointers(selected.pos1, sentence.pos1) ~= 0 then error("invalid sentence positions") end
        local function extract(first, last)
            extracted = true
            return clean(document:getTextFromXPointers(first, last))
        end
        local immediate_before = extract(sentence.pos0, selected.pos0)
        local immediate_after = extract(selected.pos1, sentence.pos1)
        local clipped = Context.wordCount(immediate_before) > Limits.CONTEXT_WORDS_MAX or Context.wordCount(immediate_after) > Limits.CONTEXT_WORDS_MAX
            or (Text.count(immediate_before) or math.huge) > MAX_SURROUNDING_CHARACTERS or (Text.count(immediate_after) or math.huge) > MAX_SURROUNDING_CHARACTERS
        immediate_before = Context.trimNearest(immediate_before, Limits.CONTEXT_WORDS_MAX, MAX_SURROUNDING_CHARACTERS, true)
        immediate_after = Context.trimNearest(immediate_after, Limits.CONTEXT_WORDS_MAX, MAX_SURROUNDING_CHARACTERS, false)
        local adjacent_before, adjacent_after = "", ""
        if not clipped then
            local previous = sentence.pos0
            local remaining_before = Limits.CONTEXT_WORDS_TARGET - Context.wordCount(immediate_before)
            while remaining_before > 0 do
                local next_previous = document:getPrevVisibleWordStart(previous)
                if not next_previous then break end
                previous = next_previous
                remaining_before = remaining_before - 1
            end
            if previous ~= sentence.pos0 then
                adjacent_before = Context.trimNearest(extract(previous, sentence.pos0), Limits.CONTEXT_WORDS_MAX - Context.wordCount(immediate_before), MAX_SURROUNDING_CHARACTERS - (Text.count(immediate_before) or 0), true)
            end
            local following = sentence.pos1
            local remaining_after = Limits.CONTEXT_WORDS_TARGET - Context.wordCount(immediate_after)
            while remaining_after > 0 do
                local next_following = document:getNextVisibleWordEnd(following)
                if not next_following then break end
                following = next_following
                remaining_after = remaining_after - 1
            end
            if following ~= sentence.pos1 then
                adjacent_after = Context.trimNearest(extract(sentence.pos1, following), Limits.CONTEXT_WORDS_MAX - Context.wordCount(immediate_after), MAX_SURROUNDING_CHARACTERS - (Text.count(immediate_after) or 0), false)
            end
        end
        return { strategy = clipped and "sentence_clipped" or "sentence", immediate_before = immediate_before, immediate_after = immediate_after, adjacent_before = adjacent_before, adjacent_after = adjacent_after }
    end, debug.traceback)
    local restored = restore()
    if not ok or not restored then return nil end
    return result
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
        if count > 3 then
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

    local matched_length = Text.count(matched) or 0
    if matched_length >= MAX_PRIOR_MENTION_CHARACTERS then
        return truncate_characters(matched, MAX_PRIOR_MENTION_CHARACTERS, false)
    end

    local remaining = MAX_PRIOR_MENTION_CHARACTERS - matched_length
    local before_length = math.min(Text.count(previous) or 0, math.floor(remaining / 2))
    local after_length = math.min(Text.count(following) or 0, remaining - before_length)
    before_length = math.min(Text.count(previous) or 0, remaining - after_length)

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
        and selected_term_count(snapshot.selected_text) <= 3
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

-- A temporary, read-only device capability probe. It deliberately uses the
-- same inherited subprocess route as production retrieval will use: opening a
-- CREngine document from a standalone LuaJIT process is not safe on Kindle.
function Context.probeLocalSearch(plugin, snapshot)
    local document = plugin and plugin.ui and plugin.ui.document
    if not document or document.provider ~= "crengine" then
        return { supported = false, reason = "This document is not backed by CREngine." }
    end
    if type(document.findAllText) ~= "function" or type(document.compareXPointers) ~= "function" then
        return { supported = false, reason = "This document does not expose the required CREngine search and position APIs." }
    end
    if not snapshot.selection_start then
        return { supported = false, reason = "KOReader did not provide the selected text position." }
    end
    if selected_term_count(snapshot.selected_text) > Limits.QUERY_WORDS or (Text.count(snapshot.selected_text) or math.huge) > Limits.QUERY_SCALARS then
        return { supported = false, reason = "The selected phrase exceeds the local-search query limits." }
    end
    local ok, results = pcall(function()
        return document:findAllText(snapshot.selected_text, true, PRIOR_MENTION_CONTEXT_WORDS, 50, false)
    end)
    if not ok or type(results) ~= "table" then
        return { supported = false, reason = "The document search call failed." }
    end
    local samples, before_count, after_or_overlap_count = {}, 0, 0
    for index, result in ipairs(results) do
        local before = result["end"] and document:compareXPointers(result["end"], snapshot.selection_start) == 1
        if before then before_count = before_count + 1 else after_or_overlap_count = after_or_overlap_count + 1 end
        if #samples < 3 then
            local matched = clean(table.concat({ result.matched_word_prefix or "", result.matched_text or "", result.matched_word_suffix or "" }))
            local excerpt = make_prior_mention(result.prev_text, matched, result.next_text)
            samples[#samples + 1] = {
                relation = before and "strictly before" or "at/after or overlapping",
                excerpt = truncate_characters(excerpt, Limits.PRODUCT_PRIOR_MENTION, false),
                has_start = result.start ~= nil,
                has_end = result["end"] ~= nil,
            }
        end
    end
    return {
        supported = true,
        query = snapshot.selected_text,
        result_count = #results,
        cap_reached = #results == 50,
        before_count = before_count,
        after_or_overlap_count = after_or_overlap_count,
        samples = samples,
    }
end

function Context.capture(plugin, highlight, fallback_text)
    local selected = highlight and highlight.selected_text
    local selected_text = clean((selected and selected.text) or fallback_text)

    if selected_text == "" then
        return nil, "No text is selected."
    end
    if (Text.count(selected_text) or math.huge) > MAX_SELECTION_CHARACTERS then
        return nil, "The selection is too long to explain."
    end

    local context = sentence_context(plugin and plugin.ui and plugin.ui.document, selected) or fallback_context(highlight)

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
        context_strategy = context.strategy,
        immediate_before = context.immediate_before,
        immediate_after = context.immediate_after,
        adjacent_before = context.adjacent_before,
        adjacent_after = context.adjacent_after,
        title = truncate_characters(clean(props.title), Limits.BOOK_TITLE, false),
        authors = truncate_characters(clean(authors), Limits.BOOK_AUTHOR, false),
        language = truncate_characters(clean(props.language), Limits.BOOK_LANGUAGE, false),
        format = Context.documentFormat(document),
        chapter = truncate_characters(current_chapter(plugin, selected), Limits.CHAPTER_TITLE, false),
        selection_start = selected and selected.pos0 or nil,
        selection_end = selected and selected.pos1 or nil,
    }
end

function Context.formatLocalSearchProbe(probe)
    if not probe or not probe.supported then
        return "Local search probe\n\nUnsupported\n" .. ((probe and probe.reason) or "No result was returned.")
    end
    local sections = {
        "Local search probe",
        "Query\n" .. probe.query,
        string.format("Results\n%d returned; 50-hit cap reached: %s\nStrictly before selection: %d\nAt/after or overlapping: %d", probe.result_count, probe.cap_reached and "yes" or "no", probe.before_count, probe.after_or_overlap_count),
    }
    for index, sample in ipairs(probe.samples) do
        sections[#sections + 1] = string.format("Sample %d — %s\nPosition fields: start=%s, end=%s\n%s", index, sample.relation, sample.has_start and "yes" or "no", sample.has_end and "yes" or "no", sample.excerpt)
    end
    return table.concat(sections, "\n\n")
end

function Context.documentFormat(document)
    local file = document and document.file
    if type(file) ~= "string" then return "" end
    local extension = file:match("%.([A-Za-z0-9]+)$")
    if not extension then return "" end
    extension = extension:lower()
    if #extension > Limits.BOOK_FORMAT or not extension:match("^[a-z0-9]+$") then return "" end
    return extension
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
    if snapshot.immediate_before ~= "" then
        surrounding[#surrounding + 1] = snapshot.immediate_before
    end
    surrounding[#surrounding + 1] = "[" .. snapshot.selected_text .. "]"
    if snapshot.immediate_after ~= "" then
        surrounding[#surrounding + 1] = snapshot.immediate_after
    end

    local sections = {
        "Selected text\n" .. snapshot.selected_text,
        "Immediate context (" .. snapshot.context_strategy .. ")\n" .. table.concat(surrounding, " "),
        "Adjacent context\nBefore: " .. snapshot.adjacent_before .. "\nAfter: " .. snapshot.adjacent_after,
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
