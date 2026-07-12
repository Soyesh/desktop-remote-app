using System.Drawing;
using System.Drawing.Imaging;
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

    /// <summary>
    /// Blocks (up to timeoutMs) until the screen changes, then returns a scaled
    /// JPEG frame. Returns null on timeout -- caller should just try again;
    /// there's nothing new to send.
    /// </summary>
    public static byte[]? TryCaptureJpeg(int timeoutMs, int quality = 40, double scale = 0.6)
    {
        if (!Duplicator.TryCaptureFrame(timeoutMs, out byte[] bgraData, out int stride))
            return null;

        int width = Duplicator.Width;
        int height = Duplicator.Height;

        var handle = GCHandle.Alloc(bgraData, GCHandleType.Pinned);
        try
        {
            using var fullBitmap = new Bitmap(width, height, stride, PixelFormat.Format32bppRgb, handle.AddrOfPinnedObject());

            using (var g = Graphics.FromImage(fullBitmap))
            {
                DrawCursor(g, new Rectangle(0, 0, width, height));
            }

            int scaledWidth = Math.Max(1, (int)(width * scale));
            int scaledHeight = Math.Max(1, (int)(height * scale));

            using var scaledBitmap = new Bitmap(scaledWidth, scaledHeight, PixelFormat.Format24bppRgb);
            using (var g = Graphics.FromImage(scaledBitmap))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                g.DrawImage(fullBitmap, 0, 0, scaledWidth, scaledHeight);
            }

            using var ms = new MemoryStream();
            var jpegEncoder = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
            var encoderParams = new EncoderParameters(1);
            encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
            scaledBitmap.Save(ms, jpegEncoder, encoderParams);

            return ms.ToArray();
        }
        finally
        {
            handle.Free();
        }
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


