local clipboard = module.require("modules/clipboard.lua")
local thumbnail = module.require("modules/preview.lua")

local function same(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label,
            tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, label)
    if not value then error(label, 2) end
end

local function entry(id, ts, pinned, text)
    return { id = id, ts = ts, pinned = pinned or false, kind = "text",
        text = text }
end

return {
    ["counts and truncates UTF-8 safely"] = function()
        same(clipboard.charCount("abc"), 3, "ascii")
        same(clipboard.charCount("剪贴板"), 3, "cjk")
        same(clipboard.charCount("\240\159\152\128"), 1, "emoji")
        same(clipboard.charCount("❤\239\184\143"), 1, "variation selector")
        same(clipboard.truncate("剪贴板测试", 2), "剪贴", "truncate cjk")
        truthy(clipboard.truncate("剪贴板", 10) == "剪贴板", "no cut")
    end,

    ["flattens a snippet onto one line"] = function()
        same(clipboard.preview("  a\n\nb\tc  "), "a b c", "collapse")
        local long = string.rep("x", 100)
        local cut = clipboard.preview(long, 10)
        same(clipboard.charCount(cut), 11, "ellipsis counted")
        truthy(cut:sub(-3) == "\226\128\166", "ellipsis tail")
        same(clipboard.preview("   "), "", "blank")
    end,

    ["detects links and code"] = function()
        same(clipboard.kindOf("https://example.com"), "link", "https")
        same(clipboard.kindOf("  http://a.b"), "link", "http padded")
        same(clipboard.kindOf("const x = 1"), "code", "const")
        same(clipboard.kindOf("local x = 1"), "code", "Lua")
        same(clipboard.kindOf("https://example.com\nmore"), "text", "not a bare URL")
        same(clipboard.kindOf("function f() end"), "code", "function")
        same(clipboard.kindOf("plain words"), "text", "text")
        same(clipboard.kindOf(""), "text", "empty")
    end,

    ["formats relative time"] = function()
        local now = 1000000000
        same(clipboard.relativeTime(now - 5000, now, true), "刚刚", "seconds")
        same(clipboard.relativeTime(now - 5 * 60000, now, true),
            "5 分钟前", "minutes zh")
        same(clipboard.relativeTime(now - 5 * 60000, now, false), "5m ago",
            "minutes en")
        same(clipboard.relativeTime(now - 3 * 3600000, now, true,
            { year = 2026, month = 6, day = 20, hour = 9, min = 5 },
            { year = 2026, month = 6, day = 20 }), "3 小时前", "hours")
        same(clipboard.relativeTime(now - 3 * 3600000, now, true,
            { year = 2026, month = 6, day = 19, hour = 23, min = 5 },
            { year = 2026, month = 6, day = 20 }), "06-19 23:05", "midnight")
        same(clipboard.relativeTime(now - 48 * 3600000, now, true,
            { month = 11, day = 16, hour = 9, min = 5 }), "11-16 09:05",
            "date fallback")
    end,

    ["round-trips entries through storage lines"] = function()
        local line = clipboard.encode(entry("a", 123, true, "x\ty\nz"))
        local back = clipboard.decode(line)
        same(back.ts, 123, "ts")
        same(back.pinned, true, "pin")
        same(back.text, "x\ty\nz", "tabs and newlines survive")
        same(back.kind, "text", "kind")
        same(clipboard.decode("garbage"), nil, "garbage rejected")
        same(clipboard.decode(nil), nil, "nil rejected")
    end,

    ["sorts pinned first, then newest"] = function()
        local list = {
            entry("a", 100, false, "a"),
            entry("b", 300, true, "b"),
            entry("c", 200, false, "c"),
        }
        local sorted = clipboard.sorted(list)
        same(sorted[1].id, "b", "pin first")
        same(sorted[2].id, "c", "newest second")
        same(sorted[3].id, "a", "oldest last")
        same(list[1].id, "a", "input not mutated")
    end,

    ["upsert moves duplicates to the top and keeps the pin"] = function()
        local list = {
            entry("a", 100, false, "same"),
            entry("b", 200, false, "other"),
        }
        local pin = clipboard.togglePin(list, "a", 250)
        local nextList, dropped = clipboard.upsert(pin, entry("new", 300, false, "same"), 10)
        same(#nextList, 2, "dedupe")
        same(nextList[1].id, "a", "stable id")
        same(nextList[1].pinned, true, "pin kept")
        same(nextList[1].ts, 300, "timestamp refreshed")
        same(#dropped, 0, "nothing dropped")
    end,

    ["prunes the oldest unpinned entry at the cap"] = function()
        local list = {
            entry("p", 100, true, "pin"),
            entry("a", 200, false, "a"),
            entry("b", 300, false, "b"),
        }
        local nextList, dropped = clipboard.upsert(list,
            entry("c", 400, false, "c"), 3)
        same(#nextList, 3, "cap held")
        truthy(nextList[1].id == "p" and nextList[2].id == "c"
            and nextList[3].id == "b", "pin kept, oldest dropped")
        same(dropped[1], "a", "dropped id reported")
    end,

    ["keeps all pins even past the cap"] = function()
        local list = {
            entry("p1", 100, true, "one"),
            entry("p2", 200, true, "two"),
        }
        local nextList, dropped = clipboard.upsert(list,
            entry("c", 300, false, "c"), 2)
        same(#nextList, 2, "cap held by the pins")
        same(dropped[1], "c", "the new unpinned entry is dropped")
        same(nextList[1].id, "p2", "newest pin first")
    end,

    ["removes, pins and clears"] = function()
        local list = { entry("a", 100, false, "a"), entry("b", 200, true, "b") }
        same(#clipboard.removeId(list, "a"), 1, "remove")
        same(#clipboard.removeId(list, "zz"), 2, "remove missing")
        local toggled = clipboard.togglePin(list, "a", 300)
        same(toggled[1].id, "b", "pins order by their own time")
        same(toggled[2].id, "a", "older pin follows")
        truthy(toggled[2].pinned, "a is pinned")
        local cleared = clipboard.clear(list, false)
        same(#cleared, 0, "clear all")
        local kept, changed = clipboard.clear(list, true)
        same(#kept, 1, "keep pinned")
        same(kept[1].id, "b", "pinned survived")
        same(changed, true, "changed flag")
    end,

    ["cycles to the next filter that has entries"] = function()
        local list = {
            entry("a", 100, false, "a"),
            { id = "f", ts = 200, pinned = false, kind = "files",
                names = { "a.txt" } },
        }
        same(clipboard.nextFilter(list, "all"), "text", "all -> text")
        same(clipboard.nextFilter(list, "text"), "files", "skips images")
        same(clipboard.nextFilter(list, "files"), "all", "wraps")
        same(clipboard.nextFilter({}, "text"), "all", "empty list")
        same(clipboard.nextFilter(list, "bogus"), "text", "unknown current")
    end,

    ["dedupes text duplicates keeping the pinned one"] = function()
        local list = {
            entry("a", 100, false, "same"),
            entry("b", 200, false, "same"),
            entry("c", 150, true, "same"),
            entry("d", 300, false, "other"),
        }
        local kept, removed = clipboard.dedupeText(list)
        same(#kept, 2, "two distinct texts")
        same(kept[1].id, "c", "pinned duplicate wins")
        same(kept[2].id, "d", "other text kept")
        same(#removed, 2, "two stale ids")
    end,

    ["keeps a refreshed entry when pruning at the cap"] = function()
        local list = { entry("same", 100, false, "same"),
            entry("other", 200, false, "other") }
        local kept, dropped = clipboard.upsert(list,
            entry("new", 300, false, "same"), 2)
        same(kept[1].id, "same", "refreshed stable id")
        same(kept[2].id, "other", "other entry survives refresh")
        same(#kept, 2, "cap remains two")
        same(#dropped, 0, "refresh does not add an entry")
        same(#dropped, 0, "refresh does not add an entry")
        local unchanged, none = clipboard.upsert(kept, nil, 2)
        same(#unchanged, 2, "no-op prune")
        same(#none, 0, "no-op delete list")
        local session = { id = "large", ts = 500, pinned = false,
            kind = "text", text = "large", sessionOnly = true }
        local pinned = clipboard.togglePin({ session }, "large", 600)[1]
        truthy(pinned.sessionOnly, "session marker kept when pinning")
        local refreshed = clipboard.upsert({ pinned },
            entry("fresh", 700, false, "large"), 2)[1]
        truthy(refreshed.sessionOnly and refreshed.pinned,
            "session marker and pin kept on duplicate")
    end,

    ["decodes bounded thumbnails and rejects malformed payloads"] = function()
        local image = thumbnail.decode("/+4AAP7/", 2, 1)
        truthy(image and image.width == 2 and image.height == 1, "two RGB pixels")
        same(image.rows[1][1].color, 0xFFEE00, "first RGB color")
        same(image.rows[1][2].color, 0x00FEFF, "second RGB color")
        same(thumbnail.decode("/+4AAP/=", 2, 1), nil, "nonzero base64 tail")
        same(thumbnail.decode("/+4AAP7/AAAA", 2, 1), nil, "extra trailing bytes")
        same(thumbnail.decode("/+4=AAAA", 2, 1), nil, "padding in the middle")
        same(thumbnail.decode("/+4AAP7", 2, 1), nil, "incomplete base64")
        same(thumbnail.decode("/+4AAP7/", 0, 1), nil, "invalid width")
        same(thumbnail.decode("/+4AAP7/", 33, 1), nil, "oversized dimensions")
    end,

    ["keeps every image copy and enriches only the watched entry"] = function()
        local first = { id = "first", ts = 1000, pinned = false, kind = "image",
            imageData = "first", width = 24, height = 16 }
        local second = { id = "second", ts = 2000, pinned = false, kind = "image",
            imageData = "first", width = 24, height = 16 }
        local list = clipboard.upsert({ first }, second, 20)
        same(#list, 2, "identical image copies remain independent")
        local enriched, found = clipboard.enrichSession(list, "second", {
            id = "host-result", ts = 2100, kind = "image",
            image = "host-image", width = 96, height = 64,
        })
        truthy(found, "watched image found")
        same(#enriched, 2, "refresh does not replace another image")
        same(enriched[1].id, "second", "target keeps its history id")
        same(enriched[1].imageData, "first", "target keeps its thumbnail")
        same(enriched[1].image, "host-image", "target gains host handle")
        same(enriched[2].image, nil, "other image is unchanged")
        local missing, ok = clipboard.enrichSession(list, "gone", second)
        truthy(not ok and missing == list, "missing refresh target is explicit")
    end,

    ["keeps repeated file copies and enriches only the target"] = function()
        local first = { id = "files-first", ts = 1000, pinned = false,
            kind = "files", names = { "a.txt", "b.txt" } }
        local second = { id = "files-second", ts = 2000, pinned = false,
            kind = "files", names = { "a.txt", "b.txt" } }
        local list = clipboard.upsert({ first }, second, 20)
        same(#list, 2, "same-name file copies remain independent")
        local enriched, found = clipboard.enrichSession(list, "files-second", {
            ts = 2100, kind = "files", names = { "a.txt", "b.txt" },
            items = { { ref = "r1", name = "a.txt" } },
        })
        truthy(found, "watched file found")
        same(#enriched, 2, "refresh does not remove the first copy")
        same(enriched[1].id, "files-second", "target id remains stable")
        same(enriched[1].items[1].ref, "r1", "target gains file reference")
        same(enriched[2].items, nil, "other file entry is unchanged")
    end,

    ["pinning preserves session thumbnails and file references"] = function()
        local image = { id = "image", ts = 100, pinned = false, kind = "image",
            image = "host-image", imageData = "pixels", pixels = { width = 12 },
            width = 12, height = 8 }
        local pinnedImage = clipboard.togglePin({ image }, "image", 200)[1]
        same(pinnedImage.image, "host-image", "host image retained")
        same(pinnedImage.imageData, "pixels", "native thumbnail retained")
        same(pinnedImage.pixels.width, 12, "decoded thumbnail retained")
        local files = { id = "files", ts = 100, pinned = false, kind = "files",
            names = { "a.txt" }, items = { { name = "a.txt", ref = "opaque" } } }
        local pinnedFiles = clipboard.togglePin({ files }, "files", 200)[1]
        same(pinnedFiles.items[1].ref, "opaque", "file reference retained")
        same(pinnedFiles.names[1], "a.txt", "file display name retained")
    end,

    ["filters and counts"] = function()
        local list = {
            entry("a", 100, false, "a"),
            { id = "i", ts = 200, pinned = false, kind = "image", width = 4,
                height = 4 },
            { id = "f", ts = 300, pinned = false, kind = "files",
                names = { "a.txt", "b.txt" } },
        }
        local counts = clipboard.counts(list)
        same(counts.all, 3, "all")
        same(counts.text, 1, "text")
        same(counts.image, 1, "image")
        same(counts.files, 1, "files")
        same(#clipboard.filtered(list, "all"), 3, "all filter")
        same(#clipboard.filtered(list, "image"), 1, "image filter")
        same(#clipboard.filtered(list, nil), 3, "nil filter")
        same(#clipboard.filtered({ entry("u", 1, false, "https://a.test"),
            entry("c", 2, false, "local x = 1") }, "link"), 1, "link filter")
        same(#clipboard.filtered({ entry("u", 1, false, "https://a.test"),
            entry("c", 2, false, "local x = 1") }, "code"), 1, "code filter")
        same(clipboard.fileTitle({ "a.txt", "b.txt" }, true), "a.txt +1",
            "file title zh")
        same(clipboard.fileTitle({}, true), "文件", "empty files")
    end,
}
