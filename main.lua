-- main.lua - Clipboard, a SnowDesktop clipboard-history card.
--
-- History sources:
--   * a resident native helper (bin/clipwatch.exe) watches text, file names
--     and a small image thumbnail through Win32 and streams native.event
--     frames. A Lua timer cannot read the clipboard: host tasks require a
--     trusted pointer gesture, so the helper is the supported background path.
--   * the + button still reads the clipboard manually and works without the
--     native permission (and for texts too large for a helper frame).
--
-- Image and file entries are read-only and session-bound: the host returns
-- instance-bound handles/references on a click; the helper's RGB mosaic and
-- display names are not host handles. Neither kind can be persisted or written
-- back (clipboard.write accepts text only).

local clipboard = module.require("modules/clipboard.lua")
local historyStorage = module.require("modules/storage.lua")
local thumbnail = module.require("modules/preview.lua")

local ACCENT = 0x6D8DFF
local ROW_RADIUS = 10
local TOAST_MS = 2800
local CONFIRM_MS = 3000
local MAX_TEXT = clipboard.MAX_TEXT
local MAX_STORED_TEXT = clipboard.MAX_STORED_TEXT
local WATCH_HELPER = "clipwatch"
local TOOLTIPS = widget.hasFeature("interaction.tooltip")
local SEMANTIC_METADATA = widget.hasFeature("interaction.accessibility.metadata")
local HEADER_BG_HOVER = 0.10
local HEADER_BG_ACTIVE = 0.16

-- Keep the type hues quiet; the content, not the icon, carries the emphasis.
local TYPE_COLORS = {
    text = 0x8F9BAA,
    link = 0x64A7FF,
    code = 0xB89CFF,
    image = 0x53C9A2,
    files = 0xE8B467,
}

local settings = {
    presets = {
        {
            id = "frosted",
            label = l10n.tr("lua_widget.clipboard.preset_frosted"),
            default = true,
            values = {
                bg = 0x0E0E12, border = 0xFFFFFF, alpha = 0.24,
                borderAlpha = 0.10, gradientEndA = 0.24,
            },
        },
        {
            id = "solid",
            label = l10n.tr("lua_widget.clipboard.preset_solid"),
            values = {
                bg = 0x1C1C1E, border = 0xFFFFFF, alpha = 0.97,
                borderAlpha = 0.08, gradientEndA = 0.40,
            },
        },
        {
            id = "clear",
            label = l10n.tr("lua_widget.clipboard.preset_clear"),
            values = {
                bg = 0x000000, border = 0x000000, alpha = 0,
                borderAlpha = 0, gradientEndA = 0,
            },
        },
    },
    fields = {
        {
            key = "autoWatch",
            label = l10n.tr("lua_widget.clipboard.settings_watch"),
            description = l10n.tr("lua_widget.clipboard.settings_watch_desc"),
            type = "bool",
            default = true,
        },
        {
            key = "maxCount",
            label = l10n.tr("lua_widget.clipboard.settings_max"),
            description = l10n.tr("lua_widget.clipboard.settings_max_desc"),
            type = "select",
            default = "20",
            options = { "10", "20", "30", "50" },
        },
        {
            key = "captureImages",
            label = l10n.tr("lua_widget.clipboard.settings_images"),
            description = l10n.tr("lua_widget.clipboard.settings_images_desc"),
            type = "bool",
            default = true,
        },
        {
            key = "captureFiles",
            label = l10n.tr("lua_widget.clipboard.settings_files"),
            description = l10n.tr("lua_widget.clipboard.settings_files_desc"),
            type = "bool",
            default = true,
        },
    },
}

local FILTERS = { "all", "text", "image", "files" }
local FILTER_KEYS = {
    all = "lua_widget.clipboard.menu_all",
    text = "lua_widget.clipboard.menu_text",
    image = "lua_widget.clipboard.menu_image",
    files = "lua_widget.clipboard.menu_files",
}
local FILTER_TOOLTIPS = {
    all = "lua_widget.clipboard.menu_filter_all",
    text = "lua_widget.clipboard.menu_filter_text",
    image = "lua_widget.clipboard.menu_filter_image",
    files = "lua_widget.clipboard.menu_filter_files",
}

local function isOn(key, fallback)
    local value = storage.get(key)
    if value == nil then return fallback ~= false end
    if type(value) ~= "string" then return value ~= false end
    value = value:lower()
    return value ~= "false" and value ~= "0"
end

local function config()
    local filter = storage.get("filter")
    if not FILTER_KEYS[tostring(filter or "")] then filter = "all" end
    local maxCount = tonumber(storage.get("maxCount")) or 20
    return {
        maxCount = math.max(10, math.min(50, maxCount)),
        autoWatch = isOn("autoWatch", true),
        captureImages = isOn("captureImages", true),
        captureFiles = isOn("captureFiles", true),
        filter = filter,
    }
end

local function isZh()
    return (l10n.language() or ""):sub(1, 2) == "zh"
end

-- contentTheme is the resolved foreground, not a guess based on wallpaper or
-- background RGB: 1 = dark ink, 0 = light ink. All card fills derive from it.
local function palette()
    local snapshot = widget.theme() or {}
    local light = snapshot.contentTheme == 1
    local accent = snapshot.accentColor or ACCENT
    -- Keep the filter readable on system accent colors with a light foreground.
    local brightness = (math.floor(accent / 65536) % 256) * 0.299
        + (math.floor(accent / 256) % 256) * 0.587 + (accent % 256) * 0.114
    return {
        ink = light and 0x25252B or 0xF5F6F8,
        surface = light and 0xFFFFFF or 0x0A0A0D,
        accent = accent,
        accentInk = brightness > 165 and 0x1C1C1E or 0xFFFFFF,
        light = light,
    }
end

-- Text helpers -------------------------------------------------------------

local function textWidth(text, size, bold)
    return draw.measureText(text, size, 0, bold or false).width
end

local function ellipsize(text, size, maxWidth, bold)
    if maxWidth <= 1 then return "" end
    text = text or ""
    if textWidth(text, size, bold) <= maxWidth then return text end
    local ell = "\226\128\166"
    local count = clipboard.charCount(text)
    local low, high = 0, count
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        local probe = clipboard.truncate(text, mid) .. ell
        if textWidth(probe, size, bold) <= maxWidth then
            low = mid
        else
            high = mid - 1
        end
    end
    if low == 0 then return ell end
    return clipboard.truncate(text, low) .. ell
end

-- History and storage ------------------------------------------------------

local storageError

-- Bulk deletes cost one storage write through a transaction; the host's burst
-- budget is 32 writes, so clearing 50 entries or cleaning duplicates one
-- remove() at a time could throw mid-way. Fall back per key on old hosts.
local function removeKeys(keys)
    if #keys == 0 then return true end
    if widget.hasFeature("storage.transaction") then
        return pcall(historyStorage.removeDropped, storage.transaction, keys)
    end
    for index = 1, #keys do
        local ok = pcall(storage.remove, keys[index])
        if not ok then return false end
    end
    return true
end

local function removeDropped(keys, dropped)
    for index = 1, #dropped do keys[#keys + 1] = "entry." .. dropped[index] end
    return removeKeys(keys)
end

local function loadHistory(model)
    local entries = {}
    local stale = {}
    local keys = storage.keys() or {}
    for index = 1, #keys do
        local key = keys[index]
        if key:sub(1, 6) == "entry." then
            local entry = clipboard.decode(storage.get(key))
            if entry then
                entry.id = key:sub(7)
                entries[#entries + 1] = entry
            else
                stale[#stale + 1] = key
            end
        end
    end
    local kept, removed = clipboard.dedupeText(entries)
    for index = 1, #removed do
        stale[#stale + 1] = "entry." .. removed[index]
    end
    removeKeys(stale)
    model.history = kept
    local pruned, dropped = clipboard.upsert(kept, nil, model.cfg.maxCount)
    model.history = pruned
    removeDropped({}, dropped)
end

local function persistEntry(entry)
    if entry.kind == "text" and entry.id then
        storage.set("entry." .. entry.id, clipboard.encode(entry))
    end
end

local function nextId(model, now)
    model.seq = (model.seq or 0) + 1
    return string.format("%d-%d", now, model.seq)
end

local function hasPending(model, kind)
    for _, job in pairs(model.tasks) do
        if job.kind == kind then return true end
    end
    return false
end

-- Every clipboard change gets its own entry. An explicit manual refresh may
-- enrich its watched row with a host handle/reference; it never replaces other
-- images or files merely because they belong to the same category.
local function addSessionEntry(model, entry)
    local sorted, dropped
    if entry.refreshId then
        sorted = clipboard.enrichSession(model.history, entry.refreshId, entry)
        if not sorted then
            entry.refreshId = nil
            sorted, dropped = clipboard.upsert(model.history, entry, model.cfg.maxCount)
        else
            dropped = {}
        end
    else
        sorted, dropped = clipboard.upsert(model.history, entry, model.cfg.maxCount)
    end
    if not removeDropped({}, dropped) then
        storageError(model, "storage remove failed")
        return false
    end
    model.history = sorted
    widget.invalidate()
    return true
end

local function hasIdentity(model, text)
    return clipboard.sameIdentity(model.history, text)
end

local function addTextEntry(model, text)
    local now = time.now()
    local sorted, dropped = clipboard.upsert(model.history, {
        id = nextId(model, now), ts = now, pinned = false, kind = "text", text = text,
    }, model.cfg.maxCount)
    local item = nil
    for index = 1, #sorted do
        if sorted[index].kind == "text" and sorted[index].text == text then
            item = sorted[index]
            break
        end
    end
    -- A pin-only history can reject a new unpinned entry at the cap.
    if not item then return end
    if #item.text <= MAX_STORED_TEXT then
        -- Commit the new text and pruning together: a full quota must not leave
        -- the old entry deleted while the new one exists only in memory.
        local ok, err = pcall(historyStorage.write, storage.transaction,
            item, dropped, clipboard.encode)
        if not ok then
            storageError(model, err)
            item.sessionOnly = true
            model.history = clipboard.upsert(model.history, item, model.cfg.maxCount)
            widget.invalidate()
            return
        end
    elseif model.sessionNoticeAt ~= now then
        model.sessionNoticeAt = now
        toast(model, l10n.tr("lua_widget.clipboard.toast_session_text"))
    end
    model.history = sorted
    if #item.text > MAX_STORED_TEXT and #dropped > 0
        and not removeDropped({}, dropped) then
        storageError(model, "storage remove failed")
    end
    widget.invalidate()
end

local function toast(model, text)
    model.toast = { text = text, at = time.monotonic() }
    schedule.after("toast", TOAST_MS)
    widget.invalidate()
end

storageError = function(model, err)
    local message = tostring(err or "")
    if message:find("quota", 1, true) or message:find("storage", 1, true) then
        toast(model, l10n.tr("lua_widget.clipboard.toast_storage_full"))
    else
        toast(model, l10n.tr("lua_widget.clipboard.toast_save_failed"))
    end
    widget.log("warn", "clipboard: " .. message)
end

-- Native clipboard watcher -------------------------------------------------

local function startWatch(model)
    if model.watchId or not model.cfg.autoWatch then return end
    if model.preview or not widget.hasFeature("task.native.watch") then return end
    local taskId, err = task.start("native.watch", {
        helper = WATCH_HELPER,
        operation = "watch",
        payload = "{}",
        timeoutMs = 6000,
    })
    if taskId then
        model.watchId = taskId
        model.watchError = nil
    else
        model.watchError = tostring(err)
    end
end

local function stopWatch(model)
    if not model.watchId then return end
    task.cancel(model.watchId)
    model.watchId = nil
end

-- Clipboard tasks ----------------------------------------------------------

local function finishCapture(model, batch)
    if model.captureGeneration ~= batch.generation or model.captureBatch ~= batch then
        return
    end
    model.captureActive = false
    model.captureBatch = nil
    widget.invalidate()
end

local function readClipboard(model, format, batch)
    if not batch or model.captureGeneration ~= batch.generation then return end
    local taskId, err = task.start("clipboard.read", { format = format })
    if not taskId then
        widget.log("warn", "clipboard read " .. format .. ": " .. tostring(err))
        toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
        finishCapture(model, batch)
        return
    end
    model.tasks[taskId] = {
        kind = "read", format = format, generation = batch.generation,
        refreshId = not preferred and model.watchEntryId or nil,
    }
    widget.invalidate()
end

-- A scheduled callback is NOT a trusted gesture. Read the type just observed
-- by the watcher in one host task; without the helper, explicit type actions
-- remain available in the refresh button's context menu.
local function refreshClipboard(model, preferred)
    if model.captureActive or hasPending(model, "read") then return end
    local format = preferred or model.watchKind or "text"
    if format == "files" then format = "file-reference" end
    if format == "image" and not model.cfg.captureImages then format = "text" end
    if format == "file-reference" and not model.cfg.captureFiles then format = "text" end
    if format ~= "text" and format ~= "image" and format ~= "file-reference" then
        toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
        return
    end
    model.captureGeneration = (model.captureGeneration or 0) + 1
    local batch = { generation = model.captureGeneration, captured = 0 }
    model.captureActive = true
    model.captureBatch = batch
    readClipboard(model, format, batch)
end

local function copyEntry(model, id)
    local entry = nil
    for index = 1, #model.history do
        if model.history[index].id == id then
            entry = model.history[index]
            break
        end
    end
    if not entry then return end
    if hasPending(model, "write") then return end
    if entry.kind ~= "text" then
        toast(model, l10n.tr("lua_widget.clipboard.toast_text_only"))
        return
    end
    if (entry.text or "") == "" then
        toast(model, l10n.tr("lua_widget.clipboard.toast_write_failed"))
        return
    end
    local taskId = task.start("clipboard.write", {
        format = "text",
        text = entry.text or "",
    })
    if not taskId then
        toast(model, l10n.tr("lua_widget.clipboard.toast_write_failed"))
        return
    end
    model.tasks[taskId] = { kind = "write" }
    widget.invalidate()
end

local function deleteEntry(model, id)
    local entry = nil
    for index = 1, #model.history do
        if model.history[index].id == id then
            entry = model.history[index]
            break
        end
    end
    if not entry then return end
    local ok, err = true, nil
    if entry.kind == "text" then
        ok, err = pcall(storage.remove, "entry." .. id)
    end
    if not ok then
        toast(model, l10n.tr("lua_widget.clipboard.toast_delete_failed"))
        widget.log("warn", "clipboard delete: " .. tostring(err))
        return
    end
    model.history = clipboard.removeId(model.history, id)
    widget.invalidate()
end

local function pinEntry(model, id)
    local entry = nil
    for index = 1, #model.history do
        if model.history[index].id == id then
            entry = model.history[index]
            break
        end
    end
    if not entry then return end
    if entry.kind == "text" and #entry.text <= MAX_STORED_TEXT then
        local updated = clipboard.togglePin({ entry }, id, time.now())[1]
        local ok, err = pcall(persistEntry, updated)
        if not ok then
            storageError(model, err)
            return
        end
    end
    model.history = clipboard.togglePin(model.history, id, time.now())
    widget.invalidate()
end

local function clearHistory(model)
    local keys = {}
    for index = 1, #model.history do
        local entry = model.history[index]
        if not entry.pinned and entry.kind == "text" and entry.id then
            keys[#keys + 1] = "entry." .. entry.id
        end
    end
    local remaining, changed = clipboard.clear(model.history, true)
    if not changed then return false end
    if not removeKeys(keys) then
        storageError(model, "storage remove failed")
        return false
    end
    model.history = remaining
    if #clipboard.filtered(model.history, model.cfg.filter) == 0 then
        storage.set("filter", "all")
        model.cfg = config()
    end
    local pruned, dropped = clipboard.upsert(model.history, nil, model.cfg.maxCount)
    model.history = pruned
    removeDropped({}, dropped)
    widget.invalidate()
    return true
end

-- Geometry -----------------------------------------------------------------

local function buildFrame(model)
    local width = layout.contentWidth()
    local height = layout.contentHeight()
    if width < 120 or height < 120 then return nil end

    local cfg = model.cfg
    local compact = width < 300 or height < 300
    local padX = math.max(12, math.min(20, width * 0.05))
    local padY = compact and 12 or 18
    local headerHeight = compact and 28 or 32
    local filterHeight = compact and 28 or 32
    local bodyTop = padY + headerHeight + 10 + filterHeight + 14
    local bodyBottom = height - padY
    local rowHeight = compact and 62 or 76
    local rows = clipboard.filtered(model.history, cfg.filter)
    local columns = width >= 420 and 2 or 1
    local gap = columns > 1 and 12 or 0
    local cellWidth = ((width - padX * 2) - gap * (columns - 1)) / columns

    return {
        width = width, height = height,
        left = padX, right = width - padX, top = padY,
        headerHeight = headerHeight, filterHeight = filterHeight,
        filterTop = padY + headerHeight + 10,
        bodyTop = bodyTop, bodyBottom = bodyBottom,
        bodyHeight = math.max(1, bodyBottom - bodyTop),
        rowHeight = rowHeight,
        columns = columns, gap = gap, cellWidth = cellWidth,
        rows = rows,
        count = #rows,
        total = #model.history,
        cfg = cfg,
        compact = compact,
        c = palette(),
        titleFont = compact and 15 or 18,
        metaFont = compact and 10 or 11,
        rowTitleFont = compact and 11 or 13,
        rowMetaFont = compact and 10 or 11,
        capture = compact and 27 or 29,
    }
end

-- Glyphs -------------------------------------------------------------------

local function drawRefresh(cx, cy, size, color, alpha)
    local half = size / 2
    -- Two open arcs with compact arrowheads: refresh, not "add" or "paste".
    draw.arc(cx, cy, half * 0.76, 35, 160, 1.65, color, alpha)
    draw.arc(cx, cy, half * 0.76, 215, 160, 1.65, color, alpha)
    draw.line(cx + half * 0.66, cy - half * 0.78,
        cx + half * 0.96, cy - half * 0.18, 1.65, color, alpha)
    draw.line(cx + half * 0.96, cy - half * 0.18,
        cx + half * 0.29, cy - half * 0.24, 1.65, color, alpha)
    draw.line(cx - half * 0.66, cy + half * 0.78,
        cx - half * 0.96, cy + half * 0.18, 1.65, color, alpha)
    draw.line(cx - half * 0.96, cy + half * 0.18,
        cx - half * 0.29, cy + half * 0.24, 1.65, color, alpha)
end

local function drawFunnel(cx, cy, size, color, alpha)
    local half = size / 2
    draw.line(cx - half, cy - half * 0.7, cx + half, cy - half * 0.7, 1.5,
        color, alpha)
    draw.line(cx - half * 0.6, cy + 0.5, cx + half * 0.6, cy + 0.5, 1.5,
        color, alpha)
    draw.line(cx - half * 0.24, cy + half * 0.7, cx + half * 0.24,
        cy + half * 0.7, 1.5, color, alpha)
end

local function drawCopy(cx, cy, size, color, alpha)
    local half = size / 2
    draw.strokeRect(cx - half * 0.76, cy - half * 0.18, half * 1.2,
        half * 1.16, color, 2, 1.5, alpha)
    draw.strokeRect(cx - half * 0.25, cy - half * 0.96, half * 1.2,
        half * 1.16, color, 2, 1.5, alpha)
end

local drawRowGlyph

local function drawFilter(kind, cx, cy, size, color, alpha)
    if kind == "all" then
        drawFunnel(cx, cy, size, color, alpha)
    else
        drawRowGlyph(kind, cx, cy, size, color, alpha)
    end
end

local function drawTrash(cx, cy, size, color, alpha)
    local half = size / 2
    -- Lid, handle, open rim and two ribs read clearly at compact sizes.
    draw.line(cx - half * 0.82, cy - half * 0.56,
        cx + half * 0.82, cy - half * 0.56, 1.45, color, alpha)
    draw.line(cx - half * 0.22, cy - half * 0.84,
        cx + half * 0.22, cy - half * 0.84, 1.45, color, alpha)
    draw.line(cx - half * 0.22, cy - half * 0.84,
        cx - half * 0.22, cy - half * 0.56, 1.45, color, alpha)
    draw.line(cx + half * 0.22, cy - half * 0.84,
        cx + half * 0.22, cy - half * 0.56, 1.45, color, alpha)
    draw.strokeRect(cx - half * 0.60, cy - half * 0.30,
        half * 1.20, half * 1.08, color, 1.6, 1.35, alpha)
    draw.line(cx - half * 0.19, cy - half * 0.04,
        cx - half * 0.19, cy + half * 0.51, 1.15, color, alpha)
    draw.line(cx + half * 0.19, cy - half * 0.04,
        cx + half * 0.19, cy + half * 0.51, 1.15, color, alpha)
end

local function drawPin(cx, cy, size, color, alpha)
    draw.line(cx + size * 0.18, cy - size * 0.20,
        cx - size * 0.25, cy + size * 0.48, 1.4, color, alpha)
    draw.strokeRect(cx - size * 0.42, cy - size * 0.40, size * 0.72,
        size * 0.44, color, size * 0.13, 1.4, alpha)
    draw.line(cx - size * 0.48, cy - size * 0.50,
        cx + size * 0.38, cy - size * 0.50, 1.4, color, alpha)
end

local function drawClipboardGlyph(cx, cy, size, color, alpha)
    local half = size / 2
    draw.strokeRect(cx - half * 0.7, cy - half * 0.8, half * 1.4,
        half * 1.7, color, math.max(2, half * 0.18), 1.5, alpha)
    draw.rect(cx - half * 0.3, cy - half * 1.0, half * 0.6, half * 0.3,
        color, half * 0.12, alpha)
    draw.line(cx - half * 0.34, cy - half * 0.3, cx + half * 0.34,
        cy - half * 0.3, 1.2, color, alpha * 0.75)
    draw.line(cx - half * 0.34, cy + half * 0.02, cx + half * 0.34,
        cy + half * 0.02, 1.2, color, alpha * 0.75)
end

drawRowGlyph = function(kind, cx, cy, size, color, alpha)
    local half = size / 2
    if kind == "link" then
        draw.line(cx - half * 0.5, cy + half * 0.5, cx + half * 0.5,
            cy - half * 0.5, 1.6, color, alpha)
        draw.strokeRect(cx - half * 0.92, cy + half * 0.08, half * 0.6,
            half * 0.6, color, half * 0.3, 1.3, alpha)
        draw.strokeRect(cx + half * 0.32, cy - half * 0.68, half * 0.6,
            half * 0.6, color, half * 0.3, 1.3, alpha)
    elseif kind == "code" then
        draw.line(cx - half * 0.18, cy - half * 0.58, cx - half * 0.72, cy,
            1.6, color, alpha)
        draw.line(cx - half * 0.72, cy, cx - half * 0.18, cy + half * 0.58,
            1.6, color, alpha)
        draw.line(cx + half * 0.18, cy - half * 0.58, cx + half * 0.72, cy,
            1.6, color, alpha)
        draw.line(cx + half * 0.72, cy, cx + half * 0.18, cy + half * 0.58,
            1.6, color, alpha)
    elseif kind == "image" then
        draw.strokeRect(cx - half * 0.78, cy - half * 0.62, half * 1.56,
            half * 1.24, color, 2, 1.4, alpha)
        draw.rect(cx + half * 0.28, cy - half * 0.34, half * 0.24,
            half * 0.24, color, half * 0.12, alpha)
        draw.line(cx - half * 0.72, cy + half * 0.52, cx - half * 0.1,
            cy - half * 0.04, 1.4, color, alpha)
        draw.line(cx - half * 0.1, cy - half * 0.04, cx + half * 0.72,
            cy + half * 0.52, 1.4, color, alpha)
    elseif kind == "files" then
        draw.strokeRect(cx - half * 0.82, cy - half * 0.55, half * 1.64,
            half * 1.2, color, 2, 1.4, alpha)
        draw.line(cx - half * 0.34, cy - half * 0.55, cx - half * 0.18,
            cy - half * 0.3, 1.4, color, alpha)
    else
        draw.line(cx - half * 0.58, cy - half * 0.52, cx + half * 0.58,
            cy - half * 0.52, 1.5, color, alpha)
        draw.line(cx - half * 0.58, cy - half * 0.04, cx + half * 0.58,
            cy - half * 0.04, 1.5, color, alpha)
        draw.line(cx - half * 0.58, cy + half * 0.44, cx + half * 0.12,
            cy + half * 0.44, 1.5, color, alpha)
    end
end

-- Header -------------------------------------------------------------------

local function drawChevron(cx, cy, size, color, alpha)
    draw.line(cx - size * 0.45, cy - size * 0.18, cx, cy + size * 0.25,
        1.3, color, alpha)
    draw.line(cx, cy + size * 0.25, cx + size * 0.45, cy - size * 0.18,
        1.3, color, alpha)
end

local function drawHeader(f, model)
    local ink = f.c.ink
    local cy = f.top + f.headerHeight / 2
    local buttonSize = f.capture
    local gap = f.compact and 6 or 8
    local captureX = f.right - buttonSize
    local clearX = captureX - gap - buttonSize
    local filterX = clearX - gap - buttonSize
    local titleRoom = filterX - 12 - f.left
    local title = ellipsize(l10n.tr("lua_widget.clipboard.name"),
        f.titleFont, titleRoom, true)
    draw.text(f.left, cy - f.titleFont / 2, title, f.titleFont, ink,
        titleRoom, true, true, 0, 0.97)

    local filterKey = "filter"
    local hovered = interaction.isHovered(filterKey)
    draw.rect(filterX, cy - buttonSize / 2, buttonSize, buttonSize,
        f.cfg.filter ~= "all" and f.c.accent or ink, 7,
        f.cfg.filter ~= "all" and HEADER_BG_ACTIVE
            or (hovered and HEADER_BG_HOVER or 0))
    drawFunnel(filterX + buttonSize / 2, cy, 14,
        f.cfg.filter ~= "all" and f.c.accent or ink, 0.65)
    local filterRegion = {
        key = filterKey,
        shape = { type = "roundedRect", x = filterX, y = cy - buttonSize / 2,
            width = buttonSize, height = buttonSize, radius = 7 },
        cursor = "hand",
        events = {
            click = { id = "filter.cycle" },
            contextMenu = { id = "filter.menu" },
        },
        accessibility = { role = "button",
            label = l10n.tr("lua_widget.clipboard.menu_filter") },
    }
    if TOOLTIPS then
        filterRegion.tooltip = l10n.tr(FILTER_TOOLTIPS[f.cfg.filter])
    end
    interaction.region(filterRegion)

    local clearKey = "clear"
    local armed = model.confirmAt > 0 and time.monotonic() < model.confirmAt
    hovered = interaction.isHovered(clearKey)
    draw.rect(clearX, cy - buttonSize / 2, buttonSize, buttonSize,
        armed and f.c.accent or ink, 7,
        armed and HEADER_BG_ACTIVE or (hovered and HEADER_BG_HOVER or 0))
    drawTrash(clearX + buttonSize / 2, cy, 14,
        armed and f.c.accent or ink, armed and 0.95 or 0.56)
    local clearRegion = {
        key = clearKey,
        shape = { type = "roundedRect", x = clearX, y = cy - buttonSize / 2,
            width = buttonSize, height = buttonSize, radius = 7 },
        cursor = "hand",
        events = { click = { id = "clear.click" } },
        accessibility = { role = "button",
            label = l10n.tr("lua_widget.clipboard.menu_clear") },
    }
    if TOOLTIPS then
        clearRegion.tooltip = l10n.tr(armed and
            "lua_widget.clipboard.toast_confirm" or
            "lua_widget.clipboard.menu_clear_hint")
    end
    interaction.region(clearRegion)

    local captureKey = "capture"
    hovered = interaction.isHovered(captureKey)
    local pressed = interaction.isPressed(captureKey)
    draw.rect(captureX, cy - buttonSize / 2, buttonSize, buttonSize,
        ink, 7, pressed and HEADER_BG_ACTIVE
            or (hovered and HEADER_BG_HOVER or 0))
    drawRefresh(captureX + buttonSize / 2, cy, 17, f.c.accent, 0.92)
    local captureRegion = {
        key = captureKey,
        shape = { type = "roundedRect", x = captureX, y = cy - buttonSize / 2,
            width = buttonSize, height = buttonSize, radius = 7 },
        cursor = "hand",
        events = {
            click = { id = "capture.refresh" },
            contextMenu = { id = "capture.menu" },
        },
        accessibility = { role = "button",
            label = l10n.tr("lua_widget.clipboard.menu_capture") },
    }
    if TOOLTIPS then
        captureRegion.tooltip = l10n.tr("lua_widget.clipboard.menu_capture_hint")
    end
    interaction.region(captureRegion)
end

-- Category filters ----------------------------------------------------------

local function drawFilters(f, _model)
    local ink = f.c.ink
    local y = f.filterTop
    local height = f.filterHeight
    local cy = y + height / 2
    local wide = f.width >= 340
    local gap = wide and 6 or 0
    local available = f.right - f.left
    local countText = tostring(f.total)
    local countW = wide and (textWidth(countText, f.metaFont, false) + 18) or 0
    local groupWidth = wide and (available - countW - 8) or available
    draw.rect(f.left, y, groupWidth, height, ink, 9, 0.055)
    if wide then
        draw.text(f.right - countW / 2 - textWidth(countText, f.metaFont) / 2,
            cy - f.metaFont / 2, countText, f.metaFont, ink, 0,
            false, true, 0, 0.46)
    end

    local tabWidth = groupWidth / #FILTERS
    for index, key in ipairs(FILTERS) do
        local x = f.left + (index - 1) * tabWidth
        local selected = f.cfg.filter == key
        local regionKey = "filter." .. key
        local hovered = interaction.isHovered(regionKey)
        local label = wide and l10n.tr(FILTER_KEYS[key]) or ""
        local font = f.metaFont + (wide and 0 or 1)
        local glyphSize = wide and 12 or 14
        local contentW = glyphSize + (wide and (5 + textWidth(label, font)) or 0)
        local gx = x + (tabWidth - contentW) / 2 + glyphSize / 2
        if selected then
            draw.rect(x + 2, y + 2, tabWidth - 4, height - 4,
                f.c.surface, 7, wide and 0.16 or 0.20)
            draw.strokeRect(x + 2, y + 2, tabWidth - 4, height - 4,
                f.c.accent, 7, 1, wide and 0.45 or 0.62)
        elseif hovered then
            draw.rect(x + 2, y + 2, tabWidth - 4, height - 4, ink, 7, 0.055)
        end
        drawFilter(key, gx, cy, glyphSize,
            selected and f.c.accent or ink, selected and 0.98 or 0.46)
        if wide then
            draw.text(gx + glyphSize / 2 + 5, cy - font / 2, label, font,
                selected and f.c.accent or ink, tabWidth - contentW / 2,
                selected, true, 0, selected and 0.98 or 0.52)
        end
        local region = {
            key = regionKey,
            shape = { type = "roundedRect", x = x, y = y,
                width = tabWidth, height = height, radius = 8 },
            cursor = "hand",
            events = {
                click = { id = "filter.set:" .. key },
                contextMenu = { id = "filter.menu" },
            },
            accessibility = { role = "button",
                label = l10n.tr(FILTER_KEYS[key]) },
        }
        if TOOLTIPS then region.tooltip = l10n.tr(FILTER_TOOLTIPS[key]) end
        interaction.region(region)
    end
end

-- Rows ---------------------------------------------------------------------

local function rowTitle(entry, zh)
    if entry.kind == "image" then
        if entry.image then
            return (zh and "图片 · " or "Image · ")
                .. tostring(entry.width or 0) .. " × " .. tostring(entry.height or 0)
        end
        if entry.imageData then return zh and "图片缩略图" or "Image thumbnail" end
        return (zh and "图片 · " or "Image · ")
            .. tostring(entry.width or 0) .. " × " .. tostring(entry.height or 0)
    elseif entry.kind == "files" then
        return clipboard.fileTitle(entry.names, zh)
    end
    return clipboard.preview(entry.text, 320)
end

local function rowMeta(entry, zh, now, nowParts)
    local timeText = clipboard.relativeTime(entry.ts, now, zh,
        time.parts(entry.ts), nowParts)
    local sizeText
    if entry.kind == "text" and entry.sessionOnly then
        sizeText = l10n.tr("lua_widget.clipboard.meta_unsaved")
    elseif entry.kind == "text" then
        sizeText = l10n.tr("lua_widget.clipboard.meta_chars",
            clipboard.charCount(entry.text))
    elseif entry.kind == "image" then
        sizeText = entry.image and l10n.tr("lua_widget.clipboard.meta_image",
            entry.width or 0, entry.height or 0)
            or l10n.tr("lua_widget.clipboard.meta_thumbnail")
    else
        local count = entry.names and #entry.names or 0
        sizeText = count > 1 and l10n.tr("lua_widget.clipboard.meta_files", count)
            or l10n.tr("lua_widget.clipboard.meta_read_only")
    end
    return timeText .. " · " .. sizeText
end

local function drawRowAction(f, key, x, y, size, glyph, color, alpha,
        label, tooltip, value)
    local hovered = interaction.isHovered(key)
    local pressed = interaction.isPressed(key)
    draw.rect(x, y, size, size, color, 6,
        pressed and 0.20 or (hovered and 0.12 or 0))
    if glyph == "copy" then
        drawCopy(x + size / 2, y + size / 2, 13, color, alpha)
    else
        drawTrash(x + size / 2, y + size / 2, 13, color, alpha)
    end
    local region = {
        key = key,
        shape = { type = "roundedRect", x = x, y = y,
            width = size, height = size, radius = 6 },
        cursor = "hand",
        events = { click = { id = glyph == "copy" and "entry.copy"
            or "entry.delete", value = value } },
        accessibility = { role = "button", label = label },
    }
    if TOOLTIPS then region.tooltip = tooltip end
    interaction.region(region)
end

local function drawRow(f, entry, x, width, y, now, zh, nowParts)
    local ink = f.c.ink
    local height = f.rowHeight - 8
    local key = "row." .. tostring(entry.id)
    local hovered = interaction.isHovered(key)
    local pressed = interaction.isPressed(key)
    draw.rect(x, y, width, height, f.c.surface, ROW_RADIUS,
        pressed and 0.22 or (hovered and 0.18 or 0.14))
    draw.strokeRect(x, y, width, height, entry.pinned and f.c.accent or ink,
        ROW_RADIUS, entry.pinned and 1.2 or 1,
        entry.pinned and 0.55 or (hovered and 0.22 or 0.16))

    local glyphKind = entry.kind
    if glyphKind == "text" then glyphKind = clipboard.kindOf(entry.text) end
    local tint = TYPE_COLORS[glyphKind] or TYPE_COLORS.text
    local tile = f.compact and 30 or 34
    local tileX = x + (f.compact and 9 or 12)
    local tileY = y + (height - tile) / 2
    if entry.kind == "image" and entry.image then
        local ok = pcall(draw.image, entry.image, tileX, tileY, tile, tile, 0.98)
        if not ok then
            draw.rect(tileX, tileY, tile, tile, tint, 8, 0.10)
            drawRowGlyph("image", tileX + tile / 2, tileY + tile / 2,
                tile * 0.48, tint, 0.85)
        end
    elseif entry.kind == "image" and entry.pixels then
        draw.rect(tileX, tileY, tile, tile, tint, 6, 0.16)
        draw.pushClip(tileX + 2, tileY + 2, tile - 4, tile - 4)
        local cellWidth = (tile - 4) / entry.pixels.width
        local cellHeight = (tile - 4) / entry.pixels.height
        for row = 1, #entry.pixels.rows do
            local runs = entry.pixels.rows[row]
            for index = 1, #runs do
                local run = runs[index]
                draw.rect(tileX + 2 + run.x * cellWidth,
                    tileY + 2 + (row - 1) * cellHeight,
                    run.width * cellWidth + 0.05, cellHeight + 0.05,
                    run.color, 0, 0.98)
            end
        end
        draw.popClip()
    else
        draw.rect(tileX, tileY, tile, tile, tint, 8, f.c.light and 0.075 or 0.09)
        drawRowGlyph(glyphKind, tileX + tile / 2, tileY + tile / 2,
            tile * 0.48, tint, 0.88)
    end

    local actionSize = f.compact and 20 or 22
    local actionGap = 3
    local actionsX = x + width - 9 - actionSize * 2 - actionGap
    local textX = tileX + tile + (f.compact and 8 or 10)
    local titleMax = math.max(0, actionsX - 8 - textX)
    local titleY = y + (height - f.rowTitleFont - f.rowMetaFont - 6) / 2
    local title = ellipsize(rowTitle(entry, zh), f.rowTitleFont, titleMax, false)
    local code = entry.kind == "text" and glyphKind == "code"
    local codeLines = code and (f.compact and 2 or 3) or 1
    if code then
        draw.pushClip(textX, titleY - 1, titleMax,
            f.rowTitleFont * codeLines + 2)
        draw.text(textX, titleY, entry.text, f.rowTitleFont, ink, titleMax,
            false, false, f.rowTitleFont * codeLines + 2, 0.96)
        draw.popClip()
    else
        draw.text(textX, titleY, title, f.rowTitleFont, ink, titleMax,
            false, true, 0, 0.96)
    end
    local metaY = code and (y + height - f.rowMetaFont - 8)
        or (titleY + f.rowTitleFont + 6)
    local meta = ellipsize(rowMeta(entry, zh, now, nowParts), f.rowMetaFont, titleMax, false)
    draw.text(textX, metaY, meta, f.rowMetaFont, ink,
        titleMax, false, true, 0, 0.58)

    local actionY = y + (height - actionSize) / 2
    if entry.kind == "text" then
        drawRowAction(f, "copy." .. entry.id, actionsX, actionY, actionSize,
            "copy", ink, hovered and 0.80 or 0.45,
            l10n.tr("lua_widget.clipboard.menu_copy"),
            l10n.tr("lua_widget.clipboard.menu_copy_hint"), entry.id)
    elseif entry.pinned then
        drawPin(actionsX + actionSize / 2, actionY + actionSize / 2,
            12, f.c.accent, 0.95)
    end
    drawRowAction(f, "delete." .. entry.id, actionsX + actionSize + actionGap,
        actionY, actionSize, "delete", ink, hovered and 0.72 or 0.40,
        l10n.tr("lua_widget.clipboard.menu_delete"),
        l10n.tr("lua_widget.clipboard.menu_delete_hint"), entry.id)
    if entry.pinned and entry.kind == "text" then
        drawPin(x + 5, y + 8, 8, f.c.accent, 0.9)
    end

    local regionTop = math.max(y, f.bodyTop)
    local regionBottom = math.min(y + height, f.bodyBottom)
    if regionBottom - regionTop > 2 then
        local label = rowTitle(entry, zh)
        interaction.region({
            key = key,
            shape = { type = "roundedRect", x = x, y = regionTop,
                width = math.max(1, actionsX - x), height = regionBottom - regionTop,
                radius = ROW_RADIUS },
            cursor = entry.kind == "text" and "hand" or "default",
            events = {
                click = { id = "entry.copy", value = entry.id },
                contextMenu = { id = "entry.menu", value = entry.id },
            },
            accessibility = {
                role = entry.kind == "text" and "button" or "listitem",
                label = entry.kind == "text" and label or
                    (label .. " · " .. l10n.tr("lua_widget.clipboard.meta_read_only")),
                hint = l10n.tr("lua_widget.clipboard.menu_pin_hint"),
                value = SEMANTIC_METADATA and rowMeta(entry, zh, now, nowParts) or nil,
            },
        })
    end
end

local function drawEmpty(f, model)
    local ink = f.c.ink
    local cx = f.left + (f.right - f.left) / 2
    local filter = f.cfg.filter
    local disc = f.compact and 34 or 44
    local titleFont = f.compact and 12 or 14
    local hintFont = f.compact and 10 or 11
    local buttonHeight = 28
    local spacing = f.compact and 10 or 16
    local block = disc + spacing + titleFont + 6 + hintFont + spacing + buttonHeight
    local top = f.bodyTop + math.max(0, (f.bodyHeight - block) / 2)
    local discTop = math.max(f.bodyTop + 8, top)
    draw.rect(cx - disc / 2, discTop, disc, disc, ink, disc / 2, 0.045)
    drawClipboardGlyph(cx, discTop + disc / 2, disc * 0.48, ink, 0.32)
    local titleKey = filter == "all" and "lua_widget.clipboard.empty_title"
        or "lua_widget.clipboard.empty_filter"
    local title = l10n.tr(titleKey)
    draw.text(cx - textWidth(title, titleFont, false) / 2,
        top + disc + spacing, title, titleFont, ink, 0, false, true, 0, 0.78)
    local hintKey = filter ~= "all" and "lua_widget.clipboard.empty_category_hint"
        or (model.watchId and "lua_widget.clipboard.empty_hint"
            or "lua_widget.clipboard.empty_hint_manual")
    local hintText = ellipsize(l10n.tr(hintKey), hintFont,
        f.right - f.left - 8, false)
    if hintText ~= "" then
        draw.text(cx - textWidth(hintText, hintFont, false) / 2,
            top + disc + spacing + titleFont + 6, hintText, hintFont, ink,
            0, false, true, 0, 0.42)
    end
    local actionKey = filter == "image" and "lua_widget.clipboard.menu_capture_image"
        or (filter == "files" and "lua_widget.clipboard.menu_capture_files"
            or "lua_widget.clipboard.empty_action")
    local label = l10n.tr(actionKey)
    local width = math.min(f.right - f.left, textWidth(label, hintFont, true) + 36)
    local x = cx - width / 2
    local y = top + disc + spacing + titleFont + 6 + hintFont + spacing
    draw.rect(x, y, width, buttonHeight, f.c.accent, 8, 0.92)
    draw.text(cx - textWidth(label, hintFont, true) / 2,
        y + (buttonHeight - hintFont) / 2, label, hintFont, f.c.accentInk,
        0, true, true, 0, 0.98)
    interaction.region({
        key = "empty.capture",
        shape = { type = "roundedRect", x = x, y = y, width = width,
            height = buttonHeight, radius = 8 },
        cursor = "hand",
        events = {
            click = { id = "capture.refresh" },
            contextMenu = { id = "capture.menu" },
        },
    })
end

local function drawToast(f, model)
    if not model.toast then return end
    local age = time.monotonic() - (model.toast.at or 0)
    if age > TOAST_MS then
        model.toast = nil
        return
    end
    local font = f.metaFont
    local maxWidth = f.right - f.left
    local text = ellipsize(model.toast.text, font, maxWidth - 24, false)
    local width = math.min(maxWidth, textWidth(text, font, false) + 24)
    local height = 30
    local x = f.left + (maxWidth - width) / 2
    local y = f.bodyBottom - height - 8
    local background = f.c.light and 0xFFFFFF or 0x252936
    draw.rect(x, y, width, height, background, 10, 0.98)
    draw.strokeRect(x, y, width, height, f.c.ink, 10, 1, 0.10)
    draw.text(x + 12, y + (height - font) / 2, text, font,
        f.c.ink, 0, false, true, 0, 0.94)
end

local function render(_context, model)
    local f = buildFrame(model)
    if not f then return end

    drawHeader(f, model)
    drawFilters(f, model)
    draw.line(f.left, f.bodyTop - 7, f.right, f.bodyTop - 7, 1, f.c.ink, 0.07)

    if f.count == 0 then
        drawEmpty(f, model)
    else
        local rowsPerColumn = math.ceil(f.count / f.columns)
        local contentHeight = math.floor(math.max(f.bodyHeight,
            rowsPerColumn * f.rowHeight))
        local scroll = interaction.scroll({
            key = "history",
            shape = { type = "rect", x = f.left, y = f.bodyTop,
                width = f.right - f.left, height = f.bodyHeight },
            contentHeight = contentHeight,
        })
        local offset = scroll and scroll.offset or 0
        local now = time.now()
        local nowParts = time.parts(now)
        local zh = isZh()

        draw.pushClip(f.left - 2, f.bodyTop, f.right - f.left + 4,
            f.bodyHeight)
        for index = 1, #f.rows do
            local column = (index - 1) % f.columns
            local rowIndex = math.floor((index - 1) / f.columns)
            local cellX = f.left + column * (f.cellWidth + f.gap)
            local y = f.bodyTop - offset + rowIndex * f.rowHeight
            if y + f.rowHeight > f.bodyTop - 1 and y < f.bodyBottom + 1 then
                drawRow(f, f.rows[index], cellX, f.cellWidth, y, now, zh, nowParts)
            end
        end
        draw.popClip()
    end

    drawToast(f, model)
end

-- Lifecycle ----------------------------------------------------------------

local function setup(context)
    local model = {
        history = {},
        tasks = {},
        seq = 0,
        toast = nil,
        confirmAt = 0,
        cfg = config(),
        preview = context.preview == true,
        watchId = nil,
        watchError = nil,
    }
    loadHistory(model)
    if model.preview and #model.history == 0 then
        -- Deterministic fixture for the catalog preview; never persisted.
        local now = time.now()
        model.history = clipboard.sorted({
            { id = "preview-1", ts = now - 120000, pinned = true,
                kind = "text", text = "https://snowdesktop.com/" },
            { id = "preview-2", ts = now - 25 * 60000, pinned = false,
                kind = "text", text = "npm run pack && npm run validate" },
            { id = "preview-3", ts = now - 2 * 3600000, pinned = false,
                kind = "text", text = "周五 9:30 站会，记得带上季度数据" },
            { id = "preview-4", ts = now - 26 * 3600000, pinned = false,
                kind = "files", names = { "课程表.txt", "课程表.mtz" } },
        })
    end
    startWatch(model)
    return model
end

local function menu(_context, model, _request)
    local request = _request or {}
    if request.id == "capture.menu" then
        local items = {
            { id = "capture.refresh",
                label = l10n.tr("lua_widget.clipboard.menu_capture") },
            { id = "capture.text",
                label = l10n.tr("lua_widget.clipboard.menu_capture_text") },
            { id = "capture.image",
                label = l10n.tr("lua_widget.clipboard.menu_capture_image") },
            { id = "capture.files",
                label = l10n.tr("lua_widget.clipboard.menu_capture_files") },
            { type = "separator" },
        }
        items[#items + 1] = {
            id = "watch.toggle",
            label = l10n.tr("lua_widget.clipboard.menu_watch"),
            checked = model.cfg.autoWatch,
        }
        items[#items + 1] = {
            id = "settings.open",
            label = l10n.tr("lua_widget.clipboard.menu_settings"),
        }
        return ui.menu(items)
    end

    if request.id == "filter.menu" then
        local items = {}
        for index = 1, #FILTERS do
            local key = FILTERS[index]
            items[#items + 1] = {
                id = "filter.set:" .. key,
                value = key,
                label = l10n.tr(FILTER_KEYS[key]),
                checked = model.cfg.filter == key,
            }
        end
        return ui.menu(items)
    end

    if request.id == "entry.menu" then
        local id = tostring(request.value or "")
        local entry = nil
        for index = 1, #model.history do
            if model.history[index].id == id then
                entry = model.history[index]
                break
            end
        end
        if not entry then return nil end
        local items = {
            {
                id = "entry.copy:" .. id,
                label = l10n.tr("lua_widget.clipboard.menu_copy"),
                enabled = entry.kind == "text",
            },
            {
                id = "entry.pin:" .. id,
                label = l10n.tr(entry.pinned and
                    "lua_widget.clipboard.menu_unpin" or
                    "lua_widget.clipboard.menu_pin"),
            },
            { type = "separator" },
            {
                id = "entry.delete:" .. id,
                label = l10n.tr("lua_widget.clipboard.menu_delete"),
            },
        }
        return ui.menu(items)
    end

    return nil
end

-- Actions ------------------------------------------------------------------

local function cycleFilter(model)
    storage.set("filter", clipboard.nextFilter(model.history,
        model.cfg.filter))
    model.cfg = config()
    widget.invalidate()
end

local function clearArmed(model)
    return model.confirmAt > 0 and time.monotonic() < model.confirmAt
end

local function requestClear(model)
    if #model.history == 0 then
        model.confirmAt = 0
        widget.invalidate()
        return
    end
    if clearArmed(model) then
        local changed = clearHistory(model)
        model.confirmAt = 0
        schedule.cancel("clearConfirm")
        if changed then
            local hasPinned = #model.history > 0
            toast(model, l10n.tr(hasPinned and
                "lua_widget.clipboard.toast_cleared_pinned" or
                "lua_widget.clipboard.toast_cleared"))
        else
            widget.invalidate()
        end
    else
        model.confirmAt = time.monotonic() + CONFIRM_MS
        schedule.after("clearConfirm", CONFIRM_MS)
        toast(model, l10n.tr("lua_widget.clipboard.toast_confirm"))
        widget.invalidate()
    end
end

-- Region actions carry their payload in value.value; menu items cannot repeat
-- an id, so their entry id rides in the id suffix. Both forms land here.
local function entryIdFrom(value)
    local id = tostring(value.id or "")
    local suffix = id:match("^entry%.[a-z]+:(.+)$")
    if suffix then return suffix end
    return tostring(value.value or "")
end

local function handleAction(model, value)
    local id = tostring(value.id or "")
    if id == "capture.refresh" then
        refreshClipboard(model)
    elseif id == "capture.text" then
        refreshClipboard(model, "text")
    elseif id == "capture.image" then
        refreshClipboard(model, "image")
    elseif id == "capture.files" then
        refreshClipboard(model, "file-reference")
    elseif id == "filter.cycle" then
        cycleFilter(model)
    elseif id:sub(1, 11) == "filter.set:" then
        local filter = id:sub(12)
        if FILTER_KEYS[filter] then
            storage.set("filter", filter)
            model.cfg = config()
            widget.invalidate()
        end
    elseif id == "clear.click" then
        requestClear(model)
    elseif id == "watch.toggle" then
        storage.set("autoWatch", model.cfg.autoWatch and "false" or "true")
        model.cfg = config()
        if model.cfg.autoWatch then startWatch(model) else stopWatch(model) end
        widget.invalidate()
    elseif id == "settings.open" then
        widget.openSettings()
    elseif id == "entry.copy" or id:sub(1, 11) == "entry.copy:" then
        copyEntry(model, entryIdFrom(value))
    elseif id == "entry.pin" or id:sub(1, 10) == "entry.pin:" then
        pinEntry(model, entryIdFrom(value))
    elseif id == "entry.delete" or id:sub(1, 13) == "entry.delete:" then
        deleteEntry(model, entryIdFrom(value))
    end
end

local function handleTask(model, value)
    local job = model.tasks[value.taskId]
    if not job then
        if value.taskId == model.watchId then
            model.watchId = nil
            model.watchError = value.error or "nativeExited"
            widget.invalidate()
        end
        return
    end
    model.tasks[value.taskId] = nil
    local batch = model.captureBatch
    if not batch or batch.generation ~= job.generation then batch = nil end

    if not value.ok or type(value.value) ~= "table" then
        local err = tostring(value.error or "readFailed")
        if job.kind == "read" then
            toast(model, err == "formatUnavailable"
                and l10n.tr("lua_widget.clipboard.toast_read_failed") or err)
        else
            toast(model, l10n.tr("lua_widget.clipboard.toast_write_failed"))
        end
        widget.log("warn", "clipboard " .. job.kind .. ": " .. err)
        if batch then finishCapture(model, batch)
        else widget.invalidate() end
        return
    end

    local result = value.value
    local captured = false
    local now = time.now()
    if job.format == "text" then
        local text = type(result.text) == "string" and result.text or ""
        if text == "" then
            toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
        elseif #text > MAX_TEXT then
            toast(model, l10n.tr("lua_widget.clipboard.toast_too_long"))
        else
            if not hasIdentity(model, text) then addTextEntry(model, text) end
            captured = true
        end
    elseif job.format == "image" then
        if result.image then
            local width = tonumber(result.width) or 0
            local height = tonumber(result.height) or 0
            captured = addSessionEntry(model, {
                id = nextId(model, now), ts = now, pinned = false,
                kind = "image", image = result.image,
                width = width, height = height, refreshId = job.refreshId,
            })
        end
    elseif job.format == "file-reference" then
        local items, names = {}, {}
        for index = 1, #(result.items or {}) do
            local item = result.items[index]
            if type(item) == "table" and type(item.name) == "string"
                and item.name ~= "" and item.ref then
                items[#items + 1] = { ref = item.ref, name = item.name, type = item.type }
                names[#names + 1] = item.name
            end
        end
        if #items > 0 then
            captured = addSessionEntry(model, {
                id = nextId(model, now), ts = now, pinned = false,
                kind = "files", names = names, items = items, refreshId = job.refreshId,
            })
        end
    end
    if captured and batch then batch.captured = batch.captured + 1 end
    if captured then
        toast(model, l10n.tr("lua_widget.clipboard.toast_captured"))
    end
    if batch then finishCapture(model, batch)
    else widget.invalidate() end
end

local function event(_context, model, value)
    if type(value) ~= "table" then return end
    if value.kind == "native.event" then
        if value.taskId == model.watchId and type(value.value) == "table" then
            local payload = value.value
            if payload.ignored then
                -- The native helper saw a source-app privacy marker. It never
                -- read the payload, so do not fall through to another branch.
                model.watchKind = nil
                model.watchEntryId = nil
            elseif type(payload.files) == "table" and model.cfg.captureFiles then
                -- Files outrank text: file copies can also expose path text.
                local names = {}
                for index = 1, math.min(32, #payload.files) do
                    local name = payload.files[index]
                    if type(name) == "string" and name ~= "" then
                        names[#names + 1] = clipboard.truncate(name, 256)
                    end
                end
                if #names > 0 then
                    model.watchKind = "files"
                    local now = time.now()
                    local entry = {
                        id = nextId(model, now), ts = now, pinned = false,
                        kind = "files", names = names,
                    }
                    addSessionEntry(model, entry)
                    model.watchEntryId = entry.id
                end
            elseif type(payload.text) == "string" and payload.text ~= "" then
                model.watchKind = "text"
                model.watchEntryId = nil
                addTextEntry(model, payload.text)
            elseif type(payload.imageData) == "string" and model.cfg.captureImages then
                local pixels = thumbnail.decode(payload.imageData,
                    payload.width, payload.height)
                if pixels then
                    model.watchKind = "image"
                    model.watchEntryId = nil
                    local now = time.now()
                    local entry = {
                        id = nextId(model, now), ts = now, pinned = false,
                        kind = "image", imageData = payload.imageData,
                        pixels = pixels, width = pixels.width, height = pixels.height,
                    }
                    addSessionEntry(model, entry)
                    model.watchEntryId = entry.id
                else
                    toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
                end
            elseif payload.tooLarge then
                toast(model, l10n.tr("lua_widget.clipboard.toast_too_long"))
            elseif payload.captureError then
                toast(model, l10n.tr("lua_widget.clipboard.toast_read_failed"))
            end
        end
        return
    end
    if value.kind == "action" then
        handleAction(model, value)
        return
    end
    if value.kind == "task.complete" then
        handleTask(model, value)
        return
    end
    if value.kind == "schedule" then
        if value.id == "toast" then
            model.toast = nil
            widget.invalidate()
        elseif value.id == "clearConfirm" then
            model.confirmAt = 0
            widget.invalidate()
        elseif value.id == "captureNext" then
            -- Legacy pending timers are cancelled during setup/dispose.
            model.captureNextAt = nil
        end
        return
    end
    if value.kind == "settings.changed" then
        local previousWatch = model.cfg.autoWatch
        model.cfg = config()
        if model.cfg.autoWatch ~= previousWatch then
            if model.cfg.autoWatch then startWatch(model) else stopWatch(model) end
        end
        if model.cfg.maxCount < #model.history then
            local pruned, dropped = clipboard.upsert(model.history, nil, model.cfg.maxCount)
            model.history = pruned
            if not removeDropped({}, dropped) then
                storageError(model, "storage remove failed")
            end
        end
        if #clipboard.filtered(model.history, model.cfg.filter) == 0
            and model.cfg.filter ~= "all" then
            storage.set("filter", "all")
            model.cfg = config()
        end
        widget.invalidate()
    end
end

local function dispose(_context, model)
    schedule.cancel("toast")
    schedule.cancel("clearConfirm")
    schedule.cancel("captureNext")
    model.captureGeneration = (model.captureGeneration or 0) + 1
    model.captureActive = false
    model.captureBatch = nil
    for taskId in pairs(model.tasks) do
        task.cancel(taskId)
    end
    stopWatch(model)
end

return widget.define({
    name = l10n.tr("lua_widget.clipboard.name"),
    useCustomStyle = true,
    followPersonalizationDefault = true,
    bg = 0x0E0E12,
    border = 0xFFFFFF,
    alpha = 0.24,
    borderAlpha = 0.10,
    gradientEndA = 0.24,
    settings = settings,
    setup = setup,
    render = render,
    menu = menu,
    event = event,
    dispose = dispose,
})
