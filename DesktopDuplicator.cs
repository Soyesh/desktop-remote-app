using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

/// <summary>
/// Captures the primary display via DXGI Desktop Duplication. This is the same
/// API real screen-sharing tools (OBS, Discord, Parsec) use on Windows -- it's
/// GPU-accelerated and event-driven: AcquireNextFrame blocks until the screen
/// actually changes, so we're never wasting time capturing an unchanged frame.
/// </summary>
public sealed class DesktopDuplicator : IDisposable
{
    private const int DXGI_ERROR_WAIT_TIMEOUT = unchecked((int)0x887A0027);
    private const int DXGI_ERROR_ACCESS_LOST = unchecked((int)0x887A0026);

    private ID3D11Device _device = null!;
    private ID3D11DeviceContext _context = null!;
    private IDXGIOutputDuplication _duplication = null!;

    public int Width { get; private set; }
    public int Height { get; private set; }

    public DesktopDuplicator()
    {
        Initialize();
    }

    private void Initialize()
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();

        // On hybrid-GPU laptops (Intel + NVIDIA/AMD "Optimus"-style setups), an
        // adapter can report an output that LOOKS valid via EnumOutputs but
        // still isn't actually duplicable -- it's a render-only GPU, not the
        // one physically driving the screen. Rather than guess, we try every
        // adapter/output combination and keep whichever one actually works.
        for (uint adapterIndex = 0; ; adapterIndex++)
        {
            var adapterResult = factory.EnumAdapters1(adapterIndex, out IDXGIAdapter1? adapter);
            if (adapterResult.Failure || adapter == null) break;

            try
            {
                for (uint outputIndex = 0; ; outputIndex++)
                {
                    var outputResult = adapter.EnumOutputs(outputIndex, out IDXGIOutput? output);
                    if (outputResult.Failure || output == null) break;

                    try
                    {
                        if (TryDuplicate(adapter, output))
                            return; // success -- _device/_context/_duplication/Width/Height are set
                    }
                    finally
                    {
                        output.Dispose();
                    }
                }
            }
            finally
            {
                adapter.Dispose();
            }
        }

        throw new InvalidOperationException(
            "No display output on this system supports Desktop Duplication. This commonly " +
            "happens over Remote Desktop, inside a VM, or with certain external/USB displays.");
    }

    private bool TryDuplicate(IDXGIAdapter1 adapter, IDXGIOutput output)
    {
        ID3D11Device? device = null;
        ID3D11DeviceContext? context = null;
        IDXGIOutput1? output1 = null;
        IDXGIOutputDuplication? duplication = null;

        try
        {
            // Must be DriverType.Unknown when an explicit adapter is supplied --
            // the native API rejects any other value in that case.
            D3D11.D3D11CreateDevice(
                adapter,
                DriverType.Unknown,
                DeviceCreationFlags.BgraSupport,
                null,
                out device,
                out context);

            output1 = output.QueryInterface<IDXGIOutput1>();
            duplication = output1.DuplicateOutput(device);

            var desc = output.Description;
            Width = desc.DesktopCoordinates.Right - desc.DesktopCoordinates.Left;
            Height = desc.DesktopCoordinates.Bottom - desc.DesktopCoordinates.Top;

            _device = device;
            _context = context;
            _duplication = duplication;
            return true;
        }
        catch (SharpGenException ex)
        {
            Console.WriteLine($"    [i] Output not duplicable, trying next: {ex.Message.Trim()}");
            duplication?.Dispose();
            device?.Dispose();
            context?.Dispose();
            return false;
        }
        finally
        {
            output1?.Dispose();
        }
    }

    /// <summary>
    /// Blocks (up to timeoutMs) until the next screen change, then returns the
    /// raw BGRA32 pixel buffer. Returns false on timeout (screen hasn't
    /// changed -- not an error, just means there's nothing new to send).
    /// </summary>
    public bool TryCaptureFrame(int timeoutMs, out byte[] bgraData, out int stride)
    {
        bgraData = Array.Empty<byte>();
        stride = 0;

        var result = _duplication.AcquireNextFrame((uint)timeoutMs, out _, out IDXGIResource? desktopResource);

        if (result.Failure)
        {
            desktopResource?.Dispose();

            if (result.Code == DXGI_ERROR_WAIT_TIMEOUT)
                return false; // normal: nothing changed within the wait window

            if (result.Code == DXGI_ERROR_ACCESS_LOST)
            {
                // Happens on resolution changes, UAC prompts, fullscreen exclusive
                // apps taking over, etc. Recreate the duplication and try again next call.
                Reinitialize();
                return false;
            }

            return false;
        }

        using (desktopResource)
        {
            using var texture = desktopResource!.QueryInterface<ID3D11Texture2D>();
            var texDesc = texture.Description;

            var stagingDesc = texDesc;
            stagingDesc.Usage = ResourceUsage.Staging;
            stagingDesc.CPUAccessFlags = CpuAccessFlags.Read;
            stagingDesc.BindFlags = BindFlags.None;
            stagingDesc.MiscFlags = ResourceOptionFlags.None;

            using var staging = _device.CreateTexture2D(stagingDesc);
            _context.CopyResource(staging, texture);

            var map = _context.Map(staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            try
            {
                int rowBytes = Width * 4;
                bgraData = new byte[rowBytes * Height];
                stride = rowBytes;

                unsafe
                {
                    byte* src = (byte*)map.DataPointer;
                    for (int y = 0; y < Height; y++)
                    {
                        Marshal.Copy((IntPtr)(src + y * map.RowPitch), bgraData, y * rowBytes, rowBytes);
                    }
                }
            }
            finally
            {
                _context.Unmap(staging, 0);
            }

            _duplication.ReleaseFrame();
        }

        return true;
    }

    private void Reinitialize()
    {
        try { _duplication?.Dispose(); } catch { /* best effort */ }
        try { _context?.Dispose(); } catch { /* best effort */ }
        try { _device?.Dispose(); } catch { /* best effort */ }

        Initialize();
    }

    public void Dispose()
    {
        _duplication?.Dispose();
        _context?.Dispose();
        _device?.Dispose();
    }
}
