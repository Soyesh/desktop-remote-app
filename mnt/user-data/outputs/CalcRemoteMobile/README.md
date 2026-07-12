# Desktop Remote (mobile app)

Displays a live view of your laptop's screen and lets you control it with
touch: tap to click, drag to drag, two fingers to scroll, and a keyboard
button for typing.

## What changed from the calculator version

- `main.dart` is now just a simple "enter IP address" screen.
- `remote_client.dart` replaces the old request/response `CalcClient` — it
  now handles a continuous stream of binary JPEG frames plus outgoing
  input events (no more calculator-specific commands).
- `remote_screen.dart` is new: shows the live frame feed and translates
  gestures into mouse/keyboard events.

## 1. Prerequisites

Same as before: **Flutter SDK**, and an Android phone with USB debugging
enabled (or an emulator), on the **same Wi-Fi network** as your laptop.

## 2. Set up the project

1. If you don't already have the project scaffolded:
   ```
   flutter create calc_remote
   ```
2. Copy these files in, replacing what's there:
   - `pubspec.yaml` (unchanged from before — still just needs `web_socket_channel`)
   - `lib/main.dart`
   - `lib/remote_client.dart` (new file)
   - `lib/remote_screen.dart` (new file)
3. From the project folder:
   ```
   flutter pub get
   ```

## 3. Run it

1. Make sure the desktop companion (`dotnet run`) is running on your laptop.
2. Connect your phone via USB, or start your emulator.
3. From the Flutter project folder:
   ```
   flutter run
   ```
4. Enter your laptop's IP address (from `ipconfig`) and tap **Connect**.
5. You should see your laptop's screen appear within a second or two.

## 4. Controls

- **Tap** — click at that point
- **Drag with one finger** — press, move, release (for dragging windows,
  selecting text, etc.)
- **Drag with two fingers, vertically** — scroll
- **Keyboard icon** (bottom toolbar) — brings up your phone's keyboard;
  typing sends characters to whatever has focus on the desktop
- **Enter / Backspace / Esc icons** — send those specific keys directly

## Troubleshooting

- **"Waiting for first frame..." never resolves** — almost always a
  connectivity issue: confirm same Wi-Fi network, confirm the desktop app
  is running and shows "Waiting for phone to connect...", and double-check
  the IP address (re-run `ipconfig`, it can change between reboots).
- **Video is laggy** — this is a tunable trade-off on the desktop side (see
  the desktop README's troubleshooting section) — lower resolution/quality
  there for smoother motion on slower networks.
- **Taps land slightly off target** — make sure you're tapping directly on
  the video image, not the black letterboxing around it if your phone's
  aspect ratio doesn't exactly match your laptop's.
- **Nothing happens when typing** — tap into a text field or app window on
  the desktop first so it actually has keyboard focus.

## Still not secure

Same caveat as before: no encryption, no pairing yet. Keep this to your own
local network for now — we're building the security layer once this base
experience feels solid.
