--[[--
Book club: per book and only when enabled, sends your reading progress
(every X percent and/or at the end of each chapter), your highlights and a
summary of each reading session to a channel of your choice.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DiscordAPI = require("discord_api")
local UIManager = require("ui/uimanager")
local Outbox = require("discord_outbox")
local logger = require("logger")
local _ = require("discord_i18n")

local Club = {}

Club.DEFAULTS = {
    enabled = false,
    channel = nil,      -- { id, guild_id, title, subtitle }
    progress = true,    -- send progress every `step` percent
    step = 10,
    chapters = false,   -- send when a chapter is finished
    highlights = true,
    summary = false,     -- post a summary of the reading session when closing the book
    summary_ask = true,  -- ask before posting it
    last_pct = 0,
    last_chapter = nil,
    finished = false,
}

--- The settings of the open book (defaults filled in). Change it and call Club.save.
function Club.get(ui)
    local data = ui.doc_settings and ui.doc_settings:readSetting("discord_club") or {}
    for k, v in pairs(Club.DEFAULTS) do
        if data[k] == nil then data[k] = v end
    end
    return data
end

function Club.save(ui, data)
    if ui.doc_settings then ui.doc_settings:saveSetting("discord_club", data) end
end

local function title(ui)
    local props = ui.doc_props or {}
    return DiscordAPI.cleanEmoji(props.display_title or props.title or _("a book"), true)
end

--- Sends text to the club channel; keeps it in the outbox if there is no network.
function Club.send(plugin, club, text)
    if not club.channel then return end
    local ok, err, code = plugin.api:sendMessage(club.channel.id, text)
    if not ok and (code == nil or code == 429 or code >= 500) then
        Outbox.add(club.channel.id, text)
    elseif not ok then
        logger.warn("Discord: book club message failed", tostring(err))
    end
    return ok
end

local function percent(ui, pageno)
    local total = ui.document and ui.document:getPageCount()
    if not total or total <= 0 or not pageno then return nil end
    return math.floor(pageno * 100 / total)
end

local function chapterIndex(ui, pageno)
    local toc = ui.toc
    if not toc or not toc.getTocIndexByPage then return nil end
    local ok, index = pcall(toc.getTocIndexByPage, toc, pageno)
    return ok and index or nil
end

--- Called on every page turn.
function Club.onPage(plugin, pageno)
    local ui = plugin.ui
    local club = Club.get(ui)
    if not club.enabled or not club.channel then return end
    local changed = false
    local pct = percent(ui, pageno)
    if club.progress and pct then
        if pct >= 100 then
            if not club.finished then
                club.finished = true
                changed = true
                Club.send(plugin, club, string.format(_("I finished **%s**!"), title(ui)))
            end
        else
            club.finished = false
            local bucket = math.floor(pct / club.step) * club.step
            if bucket >= club.step and bucket > (club.last_pct or 0) then
                club.last_pct = bucket
                changed = true
                Club.send(plugin, club, string.format(_("Reading **%s**: %d%%"), title(ui), pct))
            end -- going back never repeats what was already said
        end
    end
    if club.chapters then
        local index = chapterIndex(ui, pageno)
        if index then
            if club.last_chapter and index > club.last_chapter then
                local entry = ui.toc.toc and ui.toc.toc[club.last_chapter]
                if entry and entry.title and entry.title ~= "" then
                    Club.send(plugin, club, string.format(_("Finished chapter «%s» of **%s**"),
                        DiscordAPI.cleanEmoji(entry.title, true), title(ui)))
                end
            end
            if index ~= club.last_chapter then
                club.last_chapter = index
                changed = true
            end
        end
    end
    if changed then Club.save(ui, club) end
end

--- Called when annotations change: sends new highlights.
function Club.onAnnotation(plugin, items)
    local ui = plugin.ui
    local club = Club.get(ui)
    if not club.enabled or not club.highlights or not club.channel then return end
    if not (items and items.nb_highlights_added and items[1]) then return end
    local item = items[1]
    local text = item.text and item.text:gsub("%s+", " ")
    if not text or text == "" then return end
    local quote = "> " .. DiscordAPI.cleanEmoji(text, true)
    local page = item.pageref or item.pageno
    local head = string.format("**%s**%s", title(ui), page and (" (p. " .. tostring(page) .. ")") or "")
    local msg = head .. "\n" .. quote
    if item.note and item.note ~= "" then msg = msg .. "\n" .. DiscordAPI.cleanEmoji(item.note, true) end
    Club.send(plugin, club, msg:sub(1, 1900))
end

-- Reading sessions: from opening a book to closing it. Time asleep is not counted.

Club.session = nil

local function currentPage(plugin)
    if plugin.current_page then return plugin.current_page end
    local ok, page = pcall(function() return plugin.ui:getCurrentPage() end)
    return ok and page or nil
end

--- Called when a book is opened.
function Club.startSession(plugin)
    local page = currentPage(plugin)
    Club.session = {
        start = os.time(),
        asleep = 0,
        pages = page and { [page] = true } or {},
        count = 0,
        start_pct = percent(plugin.ui, page),
    }
end

--- Called on every page turn: counts the pages seen for the first time.
function Club.trackPage(pageno)
    local s = Club.session
    if not s or not pageno or s.pages[pageno] then return end
    s.pages[pageno] = true
    s.count = s.count + 1
end

function Club.onSuspend()
    if Club.session then Club.session.slept_at = os.time() end
end

function Club.onResume()
    local s = Club.session
    if s and s.slept_at then
        s.asleep = s.asleep + math.max(0, os.time() - s.slept_at)
        s.slept_at = nil
    end
end

local function formatDuration(seconds)
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 60 then return string.format(_("%d min"), minutes) end
    return string.format(_("%d h %02d min"), math.floor(minutes / 60), minutes % 60)
end

--- The summary of the current session, or nil if there is not much to tell.
function Club.sessionSummary(plugin)
    local s = Club.session
    if not s then return nil end
    local now = s.slept_at or os.time()
    local seconds = now - s.start - s.asleep
    if s.count == 0 or seconds < 60 then return nil end
    local end_pct = percent(plugin.ui, currentPage(plugin))
    local parts = {
        formatDuration(seconds),
        s.count == 1 and _("1 page") or string.format(_("%d pages"), s.count),
    }
    if s.start_pct and end_pct then
        table.insert(parts, string.format("%d%% → %d%%", s.start_pct, end_pct))
    end
    return string.format(_("Reading session: **%s** — %s"), title(plugin.ui), table.concat(parts, " · "))
end

--- Called when the book is closed: posts the session summary if wanted.
function Club.endSession(plugin)
    local summary = Club.sessionSummary(plugin)
    Club.session = nil
    local club = Club.get(plugin.ui)
    if not summary or not club.enabled or not club.summary or not club.channel then return end
    if not club.summary_ask then
        Club.send(plugin, club, summary)
        return
    end
    local channel_title = club.channel.title or "?"
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Post this to %s?"), channel_title) .. "\n\n" .. summary:gsub("%*%*", ""),
        ok_text = _("Post"),
        cancel_text = _("Not now"),
        ok_callback = function() Club.send(plugin, club, summary) end,
    })
end

--- Sends the current progress right now.
function Club.sendNow(plugin)
    local ui = plugin.ui
    local club = Club.get(ui)
    if not club.channel then return false end
    local pct = percent(ui, plugin.current_page or ui:getCurrentPage())
    Club.send(plugin, club, string.format(_("Reading **%s**: %d%%"), title(ui), pct or 0))
    return true
end

return Club
