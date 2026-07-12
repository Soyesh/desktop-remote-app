# Desktop Companion — Generic Remote Desktop (MVP, no security yet)

Streams your primary screen to your phone as a live JPEG feed, and applies
mouse/keyboard/scroll events received from the phone system-wide (not tied
to any specific app).

## What changed from the calculator version

- No more app-specific automation (`CalculatorController.cs` is gone).
- `ScreenCapture.cs` grabs and JPEG-encodes the screen ~15 times a second.
- `InputInjector.cs` uses the Win32 `SendInput` API to move the mouse,
  click, scroll, and type — this works with *whatever app currently has
  focus* on the desktop, not just Calculator.
- `Program.cs` runs a WebSocket server that pushes frames out continuously
  and reads input events in on the same connection.

## 1. Prerequisites

Same as before: **.NET 8 SDK** and **VS Code** with the C# Dev Kit
extension.

## 2. Set up the project

1. Copy these files into your `DesktopCompanion` folder, replacing the old
   versions:
   - `DesktopCompanion.csproj`
   - `Program.cs`
   - `ScreenCapture.cs`
   - `InputInjector.cs`
2. Delete `CalculatorController.cs` and `CommandHandler.cs` if they're
   still present — they're no longer used.
3. In the VS Code terminal:
   ```
   dotnet run
   ```
   You should see:
   ```
   Desktop Remote running on port 8080
   Waiting for phone to connect...
   ```

## 3. Find your laptop's local IP

```
ipconfig
```
Look for **IPv4 Address** under your active Wi-Fi adapter.

> As before, `ListenAnyIP(8080)` already binds to all network interfaces —
> unlike the old `HttpListener` version, you do **not** need to run this one
> as Administrator or edit the binding. Windows Firewall may still prompt
> you to allow the app the first time; click **Allow**.

## 4. Protocol reference (for your own understanding)

**Desktop → phone:**
- One JSON message on connect: `{"type":"screen_info","width":W,"height":H}`
- Then a continuous stream of raw binary JPEG frames

**Phone → desktop** (all JSON text messages):
- `{"type":"mouse_move","x":0.0-1.0,"y":0.0-1.0}` — move cursor (normalized position)
- `{"type":"mouse_down","button":"left"}` / `"mouse_up"` — press/release at current position
- `{"type":"mouse_click","x":..,"y":..,"button":"left"}` — move + click in one step
- `{"type":"scroll","dy":±N}` — scroll wheel
- `{"type":"key_text","text":"hello"}` — types literal characters
- `{"type":"key_special","code":"ENTER"}` — special keys: `ENTER`, `BACKSPACE`, `TAB`, `ESC`, `SPACE`, `ARROW_UP/DOWN/LEFT/RIGHT`, `DELETE`, `HOME`, `END`

## 5. What's NOT here yet (by design)

- No encryption or pairing — anyone on your Wi-Fi could technically connect
  to port 8080 right now. We're deferring this again until the mirroring +
  control loop is proven out, same as we did with the calculator version.
- Single monitor only (primary screen).
- No audio.

## Troubleshooting

- **Choppy / laggy video** — try lowering `scale` (e.g. `0.5`) or `quality`
  (e.g. `35`) in `ScreenCapture.CaptureJpeg(...)`'s call in `Program.cs`, or
  lower `targetFps` in `SendFramesLoop`. There's a real bandwidth/CPU
  trade-off here — higher resolution and fps costs more of both.
- **Mouse clicks land in the wrong place** — this usually means the phone's
  `screen_info` scaling assumption differs from actual usage; the phone
  normalizes against the *displayed image widget's* size, so as long as the
  image fills its container consistently this should track correctly. Worth
  double-checking if you resize the app window mid-session.
- **Typing does nothing** — click into a text field or app on the desktop
  first (via a tap) so it has keyboard focus before typing.
