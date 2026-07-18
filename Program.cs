using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

// Without this, Windows reports a scaled/virtualized screen size to the process,
// and CopyFromScreen only grabs that smaller region -- looks like a "windowed" capture.
SetPerMonitorDpiAwareness();

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options =>
{
    options.ListenAnyIP(8080); // plain ws:// for now -- TLS + pairing come once this works end to end
});

var app = builder.Build();
app.UseWebSockets();

app.Map("/ws", async context =>
{
    if (!context.WebSockets.IsWebSocketRequest)
    {
        context.Response.StatusCode = 400;
        return;
    }

    using var socket = await context.WebSockets.AcceptWebSocketAsync();
    Console.WriteLine("[+] Phone connected.");

    var (screenW, screenH) = ScreenCapture.GetScaledScreenSize();
    string screenInfo = JsonSerializer.Serialize(new { type = "screen_info", width = screenW, height = screenH });
    await socket.SendAsync(Encoding.UTF8.GetBytes(screenInfo), WebSocketMessageType.Text, true, CancellationToken.None);

    using var cts = new CancellationTokenSource();

    var sendTask = SendFramesLoop(socket, cts.Token);
    var receiveTask = ReceiveInputLoop(socket, cts.Token);
    var caretTask = WatchTextInputFocusLoop(socket, cts.Token);

    await Task.WhenAny(sendTask, receiveTask, caretTask);
    cts.Cancel();
    Console.WriteLine("[-] Phone disconnected.");
});

Console.WriteLine("=========================================");
Console.WriteLine(" Desktop Remote running on port 8080");
Console.WriteLine(" Waiting for phone to connect...");
Console.WriteLine(" (No security yet -- local network testing only!)");
Console.WriteLine("=========================================");

app.Run();

async Task SendFramesLoop(WebSocket socket, CancellationToken token)
{
    while (!token.IsCancellationRequested && socket.State == WebSocketState.Open)
    {
        byte[]? packet;
        try
        {
            // Blocks up to 200ms for the next screen change; returns null on
            // timeout (nothing changed) so we just loop and wait again.
            packet = ScreenCapture.TryCaptureFramePacket(timeoutMs: 200);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"    [!] Capture error: {ex}");
            break; // socket closed or capture failed; let the outer loop notice and clean up
        }

        if (packet == null) continue;

        try
        {
            await socket.SendAsync(packet, WebSocketMessageType.Binary, true, token);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"    [!] Send error: {ex}");
            break;
        }
    }
}

async Task WatchTextInputFocusLoop(WebSocket socket, CancellationToken token)
{
    Console.WriteLine("[CARET] Watch loop started");
    bool lastActive = false;
    while (!token.IsCancellationRequested && socket.State == WebSocketState.Open)
    {
        bool active = TextInputWatcher.IsTextInputActive();
        Console.WriteLine($"[CARET] poll active={active}");
        if (active != lastActive)
        {
            lastActive = active;
            string msg = JsonSerializer.Serialize(new { type = "text_input_focus", active });
            try
            {
                await socket.SendAsync(Encoding.UTF8.GetBytes(msg), WebSocketMessageType.Text, true, token);
                Console.WriteLine($"[CARET] sent text_input_focus active={active}");
            }
            catch { break; }
        }

        try { await Task.Delay(250, token); }
        catch (OperationCanceledException) { break; }
    }
    Console.WriteLine("[CARET] Watch loop exited");
}

async Task ReceiveInputLoop(WebSocket socket, CancellationToken token)
{
    var buffer = new byte[4096];

    while (!token.IsCancellationRequested && socket.State == WebSocketState.Open)
    {
        WebSocketReceiveResult result;
        try
        {
            result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
        }
        catch
        {
            break;
        }

        if (result.MessageType == WebSocketMessageType.Close) break;
        if (result.MessageType != WebSocketMessageType.Text) continue;

        string json = Encoding.UTF8.GetString(buffer, 0, result.Count);
        HandleInput(json);
    }
}

void HandleInput(string json)
{
    try
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        string type = root.GetProperty("type").GetString() ?? "";
        Console.WriteLine($"[RECV] type={type}");
        switch (type)
        {
            case "mouse_move":
                var mb = ScreenCapture.GetCaptureBounds();
                InputInjector.MoveTo(root.GetProperty("x").GetDouble(), root.GetProperty("y").GetDouble(), mb.left, mb.top, mb.width, mb.height);
                break;

            case "mouse_move_relative":
                double dx = root.GetProperty("dx").GetDouble();
                double dy = root.GetProperty("dy").GetDouble();
                InputInjector.MoveRelative((int)Math.Round(dx), (int)Math.Round(dy));
                break;

            case "mouse_down":
                InputInjector.MouseButton(GetButton(root), true);
                break;

            case "mouse_up":
                InputInjector.MouseButton(GetButton(root), false);
                break;

            case "mouse_click":
                InputInjector.Click(GetButton(root));
                break;

            case "mouse_double_click":
                InputInjector.DoubleClick(GetButton(root));
                break;
            
            case "mouse_click_at":
                var cb = ScreenCapture.GetCaptureBounds();
                InputInjector.MoveTo(root.GetProperty("x").GetDouble(), root.GetProperty("y").GetDouble(), cb.left, cb.top, cb.width, cb.height);
                InputInjector.Click(GetButton(root));
                break;
            case "mouse_double_click_at":
                var dcb = ScreenCapture.GetCaptureBounds();
                InputInjector.MoveTo(root.GetProperty("x").GetDouble(), root.GetProperty("y").GetDouble(), dcb.left, dcb.top, dcb.width, dcb.height);
                InputInjector.DoubleClick(GetButton(root));
                break;

            case "scroll":
                InputInjector.Scroll(root.GetProperty("dy").GetInt32());
                break;

            case "key_text":
                InputInjector.TypeText(root.GetProperty("text").GetString() ?? "");
                break;

            case "key_special":
                InputInjector.PressSpecial(root.GetProperty("code").GetString() ?? "");
                break;
        }
    }
    catch (Exception ex)
    {
        Console.WriteLine($"    Bad input message: {ex.Message}");
    }
}

string GetButton(JsonElement root) =>
    root.TryGetProperty("button", out var b) ? (b.GetString() ?? "left") : "left";

static void SetPerMonitorDpiAwareness()
{
    try
    {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4 (Windows 10 1703+)
        SetProcessDpiAwarenessContext(new IntPtr(-4));
    }
    catch
    {
        // Fallback for older Windows versions
        try { SetProcessDPIAware(); } catch { /* best effort */ }
    }
}

[DllImport("user32.dll")]
static extern bool SetProcessDpiAwarenessContext(IntPtr value);

[DllImport("user32.dll")]
static extern bool SetProcessDPIAware();