using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public static class ScreenCapture
{
    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x, y;
    }

    [DllImport("user32.dll")]
    private static extern bool GetCursorInfo(out CURSORINFO pci);

    [DllImport("user32.dll")]
    private static extern bool DrawIcon(IntPtr hDC, int x, int y, IntPtr hIcon);

    private const int CURSOR_SHOWING = 0x00000001;

    private static readonly DesktopDuplicator Duplicator = new();
    private const double Scale = 0.6;

    /// <summary>
    /// Blocks (up to timeoutMs) until the screen changes, then returns a packet
    /// containing ONLY the region that actually changed: a 16-byte header
    /// (x, y, width, height as little-endian int32, in the SAME scaled
    /// coordinate space reported by GetScaledScreenSize) followed by a JPEG of
    /// just that region. Returns null if there's nothing worth sending yet.
    /// </summary>
    public static byte[]? TryCaptureFramePacket(int timeoutMs, int quality = 40)
    {
        if (!Duplicator.TryCaptureFrame(timeoutMs, out byte[] bgraData, out int stride, out Rectangle dirty))
            return null;

        if (dirty.Width <= 0 || dirty.Height <= 0)
            return null;

        int nativeWidth = Duplicator.Width;
        int nativeHeight = Duplicator.Height;

        var handle = GCHandle.Alloc(bgraData, GCHandleType.Pinned);
        try
        {
            using var fullBitmap = new Bitmap(nativeWidth, nativeHeight, stride, PixelFormat.Format32bppRgb, handle.AddrOfPinnedObject());

            // Cursor intentionally not composited -- absolute-click UX doesn't need
            // the desktop's local cursor rendered on the phone.

            // Crop out just the region that changed, instead of re-encoding
            // the whole screen every time -- this is the whole point.
            using var cropped = fullBitmap.Clone(dirty, PixelFormat.Format24bppRgb);

            int scaledW = Math.Max(1, (int)Math.Round(dirty.Width * Scale));
            int scaledH = Math.Max(1, (int)Math.Round(dirty.Height * Scale));

            using var scaledPatch = new Bitmap(scaledW, scaledH, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(scaledPatch))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                g.DrawImage(cropped, 0, 0, scaledW, scaledH);
            }

            using var ms = new MemoryStream();
            var jpegEncoder = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
            var encoderParams = new EncoderParameters(1);
            encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
            scaledPatch.Save(ms, jpegEncoder, encoderParams);
            byte[] jpegBytes = ms.ToArray();

            int scaledX = (int)Math.Round(dirty.X * Scale);
            int scaledY = (int)Math.Round(dirty.Y * Scale);

            var packet = new byte[16 + jpegBytes.Length];
            BitConverter.GetBytes(scaledX).CopyTo(packet, 0);
            BitConverter.GetBytes(scaledY).CopyTo(packet, 4);
            BitConverter.GetBytes(scaledW).CopyTo(packet, 8);
            BitConverter.GetBytes(scaledH).CopyTo(packet, 12);
            Buffer.BlockCopy(jpegBytes, 0, packet, 16, jpegBytes.Length);

            return packet;
        }
        finally
        {
            handle.Free();
        }
    }

    /// <summary>The scaled canvas size the phone should allocate -- matches the coordinate space of every patch.</summary>
    public static (int width, int height) GetScaledScreenSize()
    {
        return ((int)Math.Round(Duplicator.Width * Scale), (int)Math.Round(Duplicator.Height * Scale));
    }

    public static (int left, int top, int width, int height) GetCaptureBounds()
    {
        return (Duplicator.Left, Duplicator.Top, Duplicator.Width, Duplicator.Height);
    }

    // Desktop Duplication captures pixels only -- the OS cursor is composited by
    // a separate layer and won't show up unless we draw it in ourselves.
    private static void DrawCursor(Graphics g, Rectangle bounds)
    {
        var cursorInfo = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(out cursorInfo)) return;
        if (cursorInfo.flags != CURSOR_SHOWING) return;

        int x = cursorInfo.ptScreenPos.x - bounds.Left;
        int y = cursorInfo.ptScreenPos.y - bounds.Top;

        // Best-effort: draw the real OS cursor icon (shows the actual shape --
        // arrow, I-beam, hand, etc.). Exact hotspot alignment varies by shape.
        IntPtr hdc = g.GetHdc();
        try
        {
            DrawIcon(hdc, x, y, cursorInfo.hCursor);
        }
        finally
        {
            g.ReleaseHdc(hdc);
        }

        // Always draw a clearly visible marker too, centered exactly on the
        // cursor's true hotspot -- guarantees it's visible after JPEG
        // compression shrinks/blurs the tiny native icon.
        const int radius = 10;
        using var outerPen = new Pen(Color.White, 3);
        using var innerPen = new Pen(Color.FromArgb(255, 255, 60, 60), 2);
        g.DrawEllipse(outerPen, x - radius, y - radius, radius * 2, radius * 2);
        g.DrawEllipse(innerPen, x - radius, y - radius, radius * 2, radius * 2);
    }
}


