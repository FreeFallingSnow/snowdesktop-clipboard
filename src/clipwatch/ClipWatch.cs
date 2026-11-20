using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// clipwatch - resident clipboard watcher for the SnowDesktop "Clipboard"
// widget. It emits text, bounded image thumbnails and display-only file names
// over native protocol v1. It never sends paths, writes files or changes the
// clipboard. Full host image handles and file references still require a click.
//
// A message-only window with AddClipboardFormatListener was tried (2026-11-20)
// and rejected on evidence: under the host's helper environment the listener
// never fires (standalone runs of the same binary work, the helper's startup
// capture still reaches the widget, yet no update event is ever delivered),
// so the watcher keeps the proven sequence-number polling loop.
internal static class ClipWatch
{
    private const uint CF_BITMAP = 2;
    private const uint CF_DIB = 8;
    private const uint CF_UNICODETEXT = 13;
    private const uint CF_HDROP = 15;
    private const uint CF_DIBV5 = 17;
    private const int MaxTextBytes = 12000; // keep frames under the 16 KiB cap
    private const int ThumbSize = 32;
    private const int MaxImageDimension = 16384;
    private const int PollMilliseconds = 300;
    private const int HeartbeatPolls = 33; // ~10 s between heartbeats

    // These are conventions, not access control: only cooperative clipboard
    // managers and Windows' own history/cloud sync honor them.
    private static readonly uint CfViewerIgnore =
        RegisterClipboardFormat("Clipboard Viewer Ignore");
    private static readonly uint CfExcludeContent =
        RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    private static readonly uint CfCanInclude =
        RegisterClipboardFormat("CanIncludeInClipboardHistory");
    private static readonly uint CfCanUpload =
        RegisterClipboardFormat("CanUploadToCloudClipboard");

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint RegisterClipboardFormat(string name);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr owner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll")]
    private static extern IntPtr GetClipboardData(uint format);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalUnlock(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr GlobalSize(IntPtr handle);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern UIntPtr DragQueryFile(IntPtr hDrop, uint index,
        StringBuilder file, uint chars);

    private static Stream output;
    private static readonly object WriteLock = new object();
    private static volatile bool requested;
    private static volatile bool stopped;
    private static uint lastSeq;

    private static void Emit(string json)
    {
        if (output == null) return;
        byte[] bytes = new UTF8Encoding(false).GetBytes(json + "\n");
        lock (WriteLock)
        {
            output.Write(bytes, 0, bytes.Length);
            output.Flush();
        }
    }

    private static string Escape(string value)
    {
        StringBuilder sb = new StringBuilder(value.Length + 16);
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20 || c == 0x7f)
                        sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else
                        sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private static void EmitText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        // Budget against the *escaped* payload: quotes, newlines and control
        // characters can double or triple the byte count of the raw text.
        string escaped = Escape(text);
        if (Encoding.UTF8.GetByteCount(escaped) > MaxTextBytes)
        {
            Emit("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":"
                + "{\"tooLarge\":true,\"length\":" + text.Length + "}}");
            return;
        }
        Emit("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":"
            + "{\"text\":\"" + escaped + "\",\"ts\":" + Now() + "}}");
    }

    private static long Now()
    {
        return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0,
            DateTimeKind.Utc)).TotalMilliseconds;
    }

    private static byte[] GlobalBytes(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return null;
        long length = (long)GlobalSize(handle).ToUInt64();
        if (length < 1 || length > 256 * 1024 * 1024) return null;
        IntPtr pointer = GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try
        {
            byte[] bytes = new byte[(int)length];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally { GlobalUnlock(handle); }
    }

    // Callers hold the clipboard lock for the whole snapshot so text, file
    // names and image bytes come from one clipboard sequence.
    private static string ReadTextLocked()
    {
        byte[] bytes = GlobalBytes(GetClipboardData(CF_UNICODETEXT));
        if (bytes == null || bytes.Length < 2) return null;
        int length = 0;
        while (length + 1 < bytes.Length
            && (bytes[length] != 0 || bytes[length + 1] != 0)) length += 2;
        if ((length & 1) != 0) length--;
        return Encoding.Unicode.GetString(bytes, 0, length);
    }

    private static uint? ReadDwordLocked(uint format)
    {
        if (format == 0) return null;
        byte[] bytes = GlobalBytes(GetClipboardData(format));
        if (bytes == null || bytes.Length < 4) return null;
        return BitConverter.ToUInt32(bytes, 0);
    }

    private static bool IsSensitiveLocked()
    {
        if ((CfViewerIgnore != 0 && IsFormat(CfViewerIgnore))
            || (CfExcludeContent != 0 && IsFormat(CfExcludeContent)))
            return true;
        uint? include = ReadDwordLocked(CfCanInclude);
        if (include.HasValue && include.Value == 0) return true;
        uint? upload = ReadDwordLocked(CfCanUpload);
        return upload.HasValue && upload.Value == 0;
    }

    private static bool LooksLikeImageMarkup(string text)
    {
        return !string.IsNullOrEmpty(text)
            && text.IndexOf("<img", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static Image ReadDib(uint format)
    {
        byte[] bytes = GlobalBytes(GetClipboardData(format));
        if (bytes == null || bytes.Length < 40) return null;
        int header = BitConverter.ToInt32(bytes, 0);
        int width = BitConverter.ToInt32(bytes, 4);
        int height = BitConverter.ToInt32(bytes, 8);
        if (header < 40 || header > bytes.Length || width < 1 || height == 0
            || width > MaxImageDimension || Math.Abs((long)height) > MaxImageDimension)
            return null;
        int bitCount = BitConverter.ToInt16(bytes, 14);
        int compression = BitConverter.ToInt32(bytes, 16);
        if (compression == 4 || compression == 5)
        {
            using (MemoryStream encoded = new MemoryStream(bytes, header,
                bytes.Length - header, false))
                return new Bitmap(encoded);
        }
        long pixelOffset = header;
        if (bitCount <= 8)
        {
            int colors = BitConverter.ToInt32(bytes, 32);
            pixelOffset += (colors > 0 ? colors : 1 << bitCount) * 4L;
        }
        else if (compression == 3 && header == 40) pixelOffset += 12;
        else if (compression == 6 && header == 40) pixelOffset += 16;
        if (pixelOffset < header || pixelOffset > bytes.Length) return null;

        // GDI+ does not decode a bare DIB stream, but it decodes the equivalent
        // BMP when supplied with its 14-byte file header. The clipboard's
        // shared DIB bytes stay owned by Windows and are only copied.
        byte[] bmp = new byte[bytes.Length + 14];
        bmp[0] = 0x42;
        bmp[1] = 0x4d;
        BitConverter.GetBytes(bmp.Length).CopyTo(bmp, 2);
        BitConverter.GetBytes((int)(pixelOffset + 14)).CopyTo(bmp, 10);
        Buffer.BlockCopy(bytes, 0, bmp, 14, bytes.Length);
        using (MemoryStream stream = new MemoryStream(bmp, false))
            return new Bitmap(stream);
    }

    private static Image ReadImageLocked()
    {
        if (IsFormat(CF_DIBV5)) return ReadDib(CF_DIBV5);
        if (IsFormat(CF_DIB)) return ReadDib(CF_DIB);
        if (IsFormat(CF_BITMAP))
        {
            IntPtr bitmap = GetClipboardData(CF_BITMAP);
            if (bitmap != IntPtr.Zero) return Image.FromHbitmap(bitmap);
        }
        return null;
    }

    private static bool IsFormat(uint format)
    {
        return IsClipboardFormatAvailable(format);
    }

    [DllImport("user32.dll")]
    private static extern bool IsClipboardFormatAvailable(uint format);

    private static string Thumbnail(Image source)
    {
        int width = Math.Max(1, Math.Min(ThumbSize, source.Width));
        int height = Math.Max(1, Math.Min(ThumbSize,
            (int)Math.Round((double)source.Height * width / source.Width)));
        using (source)
        using (Bitmap thumb = new Bitmap(width, height, PixelFormat.Format24bppRgb))
        {
            using (Graphics graphics = Graphics.FromImage(thumb))
            {
                graphics.Clear(Color.White);
                graphics.CompositingMode = CompositingMode.SourceOver;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.DrawImage(source, new Rectangle(0, 0, width, height));
            }
            BitmapData data = thumb.LockBits(new Rectangle(0, 0, width, height),
                ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            try
            {
                int stride = Math.Abs(data.Stride);
                byte[] pixels = new byte[stride * height];
                Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                byte[] rgb = new byte[width * height * 3];
                for (int y = 0; y < height; y++)
                {
                    int row = (data.Stride < 0 ? height - 1 - y : y) * stride;
                    for (int x = 0; x < width; x++)
                    {
                        int sourceOffset = row + x * 3;
                        int targetOffset = (y * width + x) * 3;
                        rgb[targetOffset] = pixels[sourceOffset + 2];
                        rgb[targetOffset + 1] = pixels[sourceOffset + 1];
                        rgb[targetOffset + 2] = pixels[sourceOffset];
                    }
                }
                return Convert.ToBase64String(rgb);
            }
            finally { thumb.UnlockBits(data); }
        }
    }

    private static string[] ReadFilesLocked()
    {
        IntPtr drop = GetClipboardData(CF_HDROP);
        if (drop == IntPtr.Zero) return null;
        uint count = DragQueryFile(drop, 0xffffffff, null, 0).ToUInt32();

        if (count < 1) return null;
        List<string> names = new List<string>();
        for (uint index = 0; index < Math.Min(count, 32); index++)
        {
            StringBuilder path = new StringBuilder(32768);
            uint length = DragQueryFile(drop, index, path, (uint)path.Capacity).ToUInt32();
            if (length == 0) continue;
            string full = path.ToString();
            string name = Path.GetFileName(full.TrimEnd('\\', '/'));
            if (string.IsNullOrEmpty(name)) name = "File";
            if (name.Length > 64)
            {
                // Do not split a surrogate pair at the frame budget boundary.
                int cut = 64;
                if (char.IsHighSurrogate(name[cut - 1])) cut--;
                name = name.Substring(0, cut);
            }
            names.Add(name);
        }
        return names.Count == 0 ? null : names.ToArray();
    }

    private static void EmitFiles(string[] names)
    {
        StringBuilder json = new StringBuilder();
        json.Append("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":{")
            .Append("\"files\":[");
        for (int index = 0; index < names.Length; index++)
        {
            if (index > 0) json.Append(',');
            json.Append('"').Append(Escape(names[index])).Append('"');
        }
        json.Append("],\"ts\":").Append(Now()).Append("}}");
        Emit(json.ToString());
    }

    private static void EmitCapture()
    {
        bool opened = false;
        bool sensitive = false;
        bool textPresent = false;
        bool dropPresent = false;
        bool imagePresent = false;
        string text = null;
        string[] names = null;
        Image image = null;
        try
        {
            // One clipboard lock gives a consistent snapshot and lets the
            // privacy check run before any payload is read. A listener event
            // can arrive while the source application still holds the board,
            // so a failed open retries briefly instead of dropping the change.
            opened = OpenClipboard(IntPtr.Zero);
            for (int attempt = 0; !opened && attempt < 3; attempt++)
            {
                Thread.Sleep(15);
                opened = OpenClipboard(IntPtr.Zero);
            }
            if (!opened)
            {
                EmitCaptureError();
                return;
            }
            sensitive = IsSensitiveLocked();
            if (!sensitive)
            {
                textPresent = IsFormat(CF_UNICODETEXT);
                dropPresent = IsFormat(CF_HDROP);
                imagePresent = IsFormat(CF_BITMAP) || IsFormat(CF_DIB)
                    || IsFormat(CF_DIBV5);

                // Image sources can expose HDROP alongside the actual pixels.
                // Prefer those pixels: treating the companion drop as files
                // turns a copied image into a misleading file-name entry.
                if (textPresent) text = ReadTextLocked();
                bool textUseful = !string.IsNullOrWhiteSpace(text);
                if (imagePresent
                    && (dropPresent || LooksLikeImageMarkup(text) || !textUseful))
                    image = ReadImageLocked();

                // Files still outrank accompanying plain path text when no
                // decodable image exists.
                if (image == null && dropPresent) names = ReadFilesLocked();
            }
        }
        catch (Exception)
        {
            // Do not leak clipboard contents, paths or exception messages.
            EmitCaptureError();
            return;
        }
        finally
        {
            if (opened) CloseClipboard();
        }

        if (sensitive)
        {
            Emit("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":"
                + "{\"ignored\":\"sensitive\",\"ts\":" + Now() + "}}");
            return;
        }
        if (image != null)
        {
            int sourceWidth = image.Width;
            int width = Math.Max(1, Math.Min(ThumbSize, sourceWidth));
            int height = Math.Max(1, Math.Min(ThumbSize,
                (int)Math.Round((double)image.Height * width / sourceWidth)));
            Emit("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":{"
                + "\"imageData\":\"" + Thumbnail(image) + "\",\"width\":" + width
                + ",\"height\":" + height + ",\"ts\":" + Now() + "}}");
            return;
        }
        if (names != null && names.Length > 0)
        {
            EmitFiles(names);
            return;
        }
        if (!string.IsNullOrWhiteSpace(text))
        {
            EmitText(text);
            return;
        }
        if (textPresent || dropPresent || imagePresent)
            EmitCaptureError();
        else
            Emit("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":"
                + "{\"image\":false,\"fileCount\":0}}");
    }

    private static void EmitCaptureError()
    {
        Emit("{\"version\":1,\"kind\":\"event\",\"id\":\"1\",\"value\":"
            + "{\"captureError\":\"clipboardReadFailed\"}}");
    }

    private static void CheckClipboard()
    {
        uint seq = GetClipboardSequenceNumber();
        if (seq == 0 || seq == lastSeq) return;
        lastSeq = seq;
        EmitCapture();
    }

    private static void ReadInput(Stream input)
    {
        byte[] buffer = new byte[4096];
        StringBuilder pending = new StringBuilder();
        try
        {
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                pending.Append(Encoding.UTF8.GetString(buffer, 0, read));
                string all = pending.ToString();
                int newline;
                while ((newline = all.IndexOf('\n')) >= 0)
                {
                    string line = all.Substring(0, newline);
                    all = all.Substring(newline + 1);
                    if (line.IndexOf("\"kind\":\"request\"", StringComparison.Ordinal) >= 0)
                        requested = true;
                    if (line.IndexOf("\"kind\":\"stop\"", StringComparison.Ordinal) >= 0)
                    {
                        stopped = true;
                        return;
                    }
                }
                pending.Length = 0;
                pending.Append(all);
            }
        }
        catch (IOException) { }
        finally { stopped = true; }
    }

    private static int Main(string[] args)
    {
        bool native = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--snowdesktop-native-v1") native = true;
        }
        if (!native)
        {
            Console.Error.WriteLine("clipwatch: SnowDesktop native helper only");
            return 2;
        }

        output = Console.OpenStandardOutput();
        Stream input = Console.OpenStandardInput();
        Thread reader = new Thread(delegate() { ReadInput(input); });
        reader.IsBackground = true;
        reader.Start();

        Emit("{\"version\":1,\"kind\":\"hello\",\"protocol\":\"snowdesktop-native\"}");

        DateTime deadline = DateTime.UtcNow.AddSeconds(8);
        while (!requested && !stopped && DateTime.UtcNow < deadline)
            Thread.Sleep(50);
        if (!requested || stopped) return 0;

        lastSeq = GetClipboardSequenceNumber();
        EmitCapture();
        int ticks = 0;
        while (!stopped)
        {
            Thread.Sleep(PollMilliseconds);
            CheckClipboard();
            ticks++;
            if (ticks % HeartbeatPolls == 0)
                Emit("{\"version\":1,\"kind\":\"heartbeat\",\"id\":\"1\"}");
        }
        return 0;
    }
}
