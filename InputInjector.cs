using System.Runtime.InteropServices;

public static class InputInjector
{
    private const int INPUT_MOUSE = 0;
    private const int INPUT_KEYBOARD = 1;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public InputUnion U;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private static readonly Dictionary<string, ushort> SpecialKeys = new()
    {
        ["ENTER"] = 0x0D,
        ["BACKSPACE"] = 0x08,
        ["TAB"] = 0x09,
        ["ESC"] = 0x1B,
        ["SPACE"] = 0x20,
        ["ARROW_LEFT"] = 0x25,
        ["ARROW_UP"] = 0x26,
        ["ARROW_RIGHT"] = 0x27,
        ["ARROW_DOWN"] = 0x28,
        ["DELETE"] = 0x2E,
        ["HOME"] = 0x24,
        ["END"] = 0x23,
    };

    public static (int width, int height) GetScreenSize()
    {
        var bounds = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
        return (bounds.Width, bounds.Height);
    }

    /// <summary>Moves the cursor. x/y are normalized 0..1 relative to the primary screen.</summary>
    /// <summary>Moves the cursor. x/y are normalized 0..1 within the captured monitor's bounds.</summary>
    public static void MoveTo(double normX, double normY, int captureLeft, int captureTop, int captureWidth, int captureHeight)
    {
        int targetX = captureLeft + (int)Math.Round(Math.Clamp(normX, 0, 1) * captureWidth);
        int targetY = captureTop + (int)Math.Round(Math.Clamp(normY, 0, 1) * captureHeight);

        int vLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int vHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);

        int absX = (int)((double)(targetX - vLeft) / vWidth * 65535);
        int absY = (int)((double)(targetY - vTop) / vHeight * 65535);

        Console.WriteLine($"[MOVE] norm=({normX:F3},{normY:F3}) capture=({captureLeft},{captureTop},{captureWidth}x{captureHeight}) target=({targetX},{targetY}) virt=({vLeft},{vTop},{vWidth}x{vHeight}) abs=({absX},{absY})");

        var input = new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion
            {
                mi = new MOUSEINPUT { dx = absX, dy = absY, dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK }
            }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    /// <summary>Moves the cursor relative to its current position, trackpad-style.</summary>
    public static void MoveRelative(int dx, int dy)
    {
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = MOUSEEVENTF_MOVE } }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public static void MouseButton(string button, bool down)
    {
        uint flag = (button, down) switch
        {
            ("left", true) => MOUSEEVENTF_LEFTDOWN,
            ("left", false) => MOUSEEVENTF_LEFTUP,
            ("right", true) => MOUSEEVENTF_RIGHTDOWN,
            ("right", false) => MOUSEEVENTF_RIGHTUP,
            _ => 0u
        };
        if (flag == 0) return;

        var input = new INPUT { type = INPUT_MOUSE, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = flag } } };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public static void Click(string button)
    {
        MouseButton(button, true);
        MouseButton(button, false);
    }

    /// <summary>Fires two clicks close enough together for Windows to register a double-click.</summary>
    public static void DoubleClick(string button)
    {
        Click(button);
        Thread.Sleep(40); // comfortably inside Windows' default double-click time threshold
        Click(button);
    }

    public static void Scroll(int delta)
    {
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion { mi = new MOUSEINPUT { dwFlags = MOUSEEVENTF_WHEEL, mouseData = unchecked((uint)delta) } }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public static void TypeText(string text)
    {
        var inputs = new List<INPUT>();
        foreach (char c in text)
        {
            inputs.Add(KeyUnicode(c, false));
            inputs.Add(KeyUnicode(c, true));
        }
        if (inputs.Count > 0)
            SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    private static INPUT KeyUnicode(char c, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT { wScan = c, dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0) }
        }
    };

    public static void PressSpecial(string code)
    {
        if (!SpecialKeys.TryGetValue(code, out ushort vk)) return;

        var down = new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk } } };
        var up = new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = KEYEVENTF_KEYUP } } };
        SendInput(2, new[] { down, up }, Marshal.SizeOf<INPUT>());
    }
}
