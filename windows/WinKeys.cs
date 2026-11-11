// The keyboard while a viewer window is in front, through a low-level keyboard hook:
// - Keys other programs inject go nowhere. voxl on this PC types what someone viewing the PC
//   types; in front of this window that would go on to the remote, which may be showing this PC,
//   and a key could bounce PC -> remote -> PC forever.
// - For a Mac machine, the Mac's Control key is the PC's Win key (voxl sends Win as Control and
//   Ctrl as Cmd to a Mac). Windows normally keeps Win combos for itself (Win+C, Win+R,
//   Win+Space, ...), so the hook swallows Win and every key pressed with it, and replays them into
//   voxl's page through the DevTools protocol. Those are trusted events that skip the IME, so with
//   a Korean layout Win+C never becomes a Hangul letter, and they never pass through the hook.
// Windows keeps Win+L and Ctrl+Alt+Del whatever a hook does.
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace VoxlViewer;

sealed class WinKeys : IDisposable
{
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public nuint extraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, StringBuilder buf, int size, uint flags, IntPtr layout);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string? name);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_SYSKEYDOWN = 0x104;
    const uint WM_QUIT = 0x12, LLKHF_INJECTED = 0x10;
    const uint VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    const uint VK_HANGUL = 0x15, VK_HANJA = 0x19, VK_PROCESSKEY = 0xE5;
    const uint VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5;

    // One key event for the page, with the modifiers held when it happened (CDP bits: Alt 1,
    // Control 2, Meta 4, Shift 8).
    readonly record struct Key(uint Vk, uint Scan, bool Down, bool Repeat, int Modifiers);

    readonly ViewerForm form;
    readonly HookProc proc; // a field, so the delegate outlives the hook
    volatile IntPtr hook;
    volatile uint hookThread;
    public volatile IntPtr FormHandle;
    public volatile bool Mac;                 // the machine is a Mac: Win is its Control key

    readonly object sync = new();
    readonly HashSet<uint> held = new();      // keys down right now, as the hook saw them
    readonly HashSet<uint> swallowed = new(); // keys whose key-down Windows never saw: their key-up goes the same way
    readonly HashSet<uint> bounced = new();   // injected keys dropped: their key-ups too
    readonly HashSet<uint> injected = new();  // injected keys let through: their repeats and key-ups too
    readonly ConcurrentQueue<Key> queue = new();
    int pending;                              // replays queued but not yet in the page
    bool draining;

    public WinKeys(ViewerForm form, IntPtr formHandle)
    {
        this.form = form;
        FormHandle = formHandle;
        proc = OnKey;
        // A low-level hook runs inside the message loop of the thread that set it. Its own thread
        // keeps it quick: Windows silently drops a hook that takes too long, so the callback below
        // only sorts keys and the UI thread does the rest.
        var thread = new Thread(() =>
        {
            hookThread = GetCurrentThreadId();
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(null), 0);
            while (GetMessage(out _, IntPtr.Zero, 0, 0) > 0) { }
        }) { IsBackground = true, Name = "win-key hook" };
        thread.Start();
        // Win+L locks Windows on the spot, and the key-ups that follow happen on the lock screen,
        // where no hook sees them. Without this, Win would stay "down" after unlocking and every
        // key would reach the Mac as Control+key.
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    void OnSessionSwitch(object? sender, SessionSwitchEventArgs e) => Reset();

    IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (code >= 0)
            {
                var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
                var msg = (int)wParam;
                var down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                bool swallow;
                lock (sync)
                    swallow = (k.flags & LLKHF_INJECTED) != 0 ? DecideInjected(k.vkCode, down) : Decide(k.vkCode, k.scanCode, down);
                if (swallow) return 1;
            }
        }
        catch (Exception)
        {
            // Never let an exception escape into Windows' input path.
        }
        return CallNextHookEx(hook, code, wParam, lParam);
    }

    bool InFront => FormHandle != IntPtr.Zero && GetForegroundWindow() == FormHandle;

    // On the hook thread, under the lock, for the keyboard's own keys. true: Windows never sees
    // this key event.
    bool Decide(uint vk, uint scan, bool down)
    {
        if (!down)
        {
            held.Remove(vk);
            if (!swallowed.Remove(vk)) return false;
            Enqueue(vk, scan, false, false);
            return true;
        }
        if (!held.Add(vk)) // autorepeat
        {
            // Windows keeps the repeats of a key whose key-down it saw, or it would think the key is stuck.
            if (!swallowed.Contains(vk)) return false;
            if (vk is not (VK_LWIN or VK_RWIN)) Enqueue(vk, scan, true, true);
            return true;
        }
        if (!InFront) return false;
        if (!Mac) return false;
        if (vk is VK_HANGUL or VK_HANJA or VK_PROCESSKEY) return false; // the IME's own keys
        var winHeld = swallowed.Contains(VK_LWIN) || swallowed.Contains(VK_RWIN);
        // While replays are still on their way, later keys join them: a key typed right after a Win
        // chord must not reach the page before the chord's key-ups, or the Mac sees Control+key.
        if (vk is VK_LWIN or VK_RWIN || winHeld || Volatile.Read(ref pending) > 0)
        {
            swallowed.Add(vk);
            Enqueue(vk, scan, true, false);
            return true;
        }
        return false;
    }

    // On the hook thread, under the lock, for keys another program injected. While the window is in
    // front they go nowhere; a key's repeats and key-up go the way its key-down went, so Windows
    // never sees a key stuck down.
    bool DecideInjected(uint vk, bool down)
    {
        if (!down)
        {
            injected.Remove(vk);
            return bounced.Remove(vk);
        }
        if (bounced.Contains(vk)) return true;
        if (injected.Contains(vk) || !InFront)
        {
            injected.Add(vk);
            return false;
        }
        bounced.Add(vk);
        return true;
    }

    // The viewer lost the focus (Alt+Tab, a dialog), the session locked or the machine stopped
    // being a Mac: release in the page whatever the hook holds back, and forget every key. Windows
    // never saw the swallowed key-downs, so letting their key-ups through later changes nothing there.
    public void Reset()
    {
        lock (sync)
        {
            foreach (var vk in swallowed) Enqueue(vk, 0, false, false);
            swallowed.Clear();
            held.Clear();
            bounced.Clear();
            injected.Clear();
        }
    }

    // Under the lock, from either thread.
    void Enqueue(uint vk, uint scan, bool down, bool repeat)
    {
        var modifiers = (Held(VK_LMENU, VK_RMENU) ? 1 : 0) | (Held(VK_LCONTROL, VK_RCONTROL) ? 2 : 0)
            | (Held(VK_LWIN, VK_RWIN) ? 4 : 0) | (Held(VK_LSHIFT, VK_RSHIFT) ? 8 : 0);
        Interlocked.Increment(ref pending);
        queue.Enqueue(new Key(vk, scan, down, repeat, modifiers));
        Post(Drain);
    }

    bool Held(uint left, uint right) => held.Contains(left) || held.Contains(right);

    void Post(Action action)
    {
        try
        {
            if (form.IsHandleCreated && !form.IsDisposed) form.BeginInvoke(action);
        }
        catch (InvalidOperationException)
        {
            // The window is closing.
        }
    }

    // On the UI thread: sends the queued events in order, one at a time.
    async void Drain()
    {
        if (draining) return;
        draining = true;
        while (queue.TryDequeue(out var k))
        {
            try
            {
                // Not into a page still loading, which may be the screen being left.
                if (form.TakesKeys && form.Core is { } core && Json(k) is { } json)
                    await core.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", json);
            }
            catch (Exception)
            {
                // The page went away; voxl releases every key on its own when it does.
            }
            finally
            {
                Interlocked.Decrement(ref pending);
            }
        }
        draining = false;
    }

    // Input.dispatchKeyEvent parameters, or null for a key with nothing to send (voxl drops those too).
    static string? Json(Key k)
    {
        var (key, code, location) = Describe(k.Vk, k.Scan, (k.Modifiers & 8) != 0);
        if (key is null) return null;
        return JsonSerializer.Serialize(new
        {
            type = k.Down ? "rawKeyDown" : "keyUp", // raw: no character event, so nothing is typed twice
            modifiers = k.Modifiers,
            key,
            code,
            location = location == 3 ? 0 : location,
            isKeypad = location == 3,
            windowsVirtualKeyCode = (int)k.Vk,
            nativeVirtualKeyCode = (int)k.Vk,
            autoRepeat = k.Repeat,
        });
    }

    // What the page should see: KeyboardEvent.key, .code and the location (1 left, 2 right,
    // 3 keypad). voxl maps modifiers and named keys by these, and printable keys by their character.
    static (string? key, string code, int location) Describe(uint vk, uint scan, bool shift)
    {
        switch (vk)
        {
            case VK_LWIN: return ("Meta", "MetaLeft", 1);
            case VK_RWIN: return ("Meta", "MetaRight", 2);
            case VK_LSHIFT: return ("Shift", "ShiftLeft", 1);
            case VK_RSHIFT: return ("Shift", "ShiftRight", 2);
            case VK_LCONTROL: return ("Control", "ControlLeft", 1);
            case VK_RCONTROL: return ("Control", "ControlRight", 2);
            case VK_LMENU: return ("Alt", "AltLeft", 1);
            case VK_RMENU: return ("Alt", "AltRight", 2);
            case 0x08: return ("Backspace", "Backspace", 0);
            case 0x09: return ("Tab", "Tab", 0);
            case 0x0D: return ("Enter", "Enter", 0);
            case 0x1B: return ("Escape", "Escape", 0);
            case 0x20: return (" ", "Space", 0);
            case 0x21: return ("PageUp", "PageUp", 0);
            case 0x22: return ("PageDown", "PageDown", 0);
            case 0x23: return ("End", "End", 0);
            case 0x24: return ("Home", "Home", 0);
            case 0x25: return ("ArrowLeft", "ArrowLeft", 0);
            case 0x26: return ("ArrowUp", "ArrowUp", 0);
            case 0x27: return ("ArrowRight", "ArrowRight", 0);
            case 0x28: return ("ArrowDown", "ArrowDown", 0);
            case 0x2D: return ("Insert", "Insert", 0);
            case 0x2E: return ("Delete", "Delete", 0);
            case 0x6A: return ("*", "NumpadMultiply", 3);
            case 0x6B: return ("+", "NumpadAdd", 3);
            case 0x6D: return ("-", "NumpadSubtract", 3);
            case 0x6E: return (".", "NumpadDecimal", 3);
            case 0x6F: return ("/", "NumpadDivide", 3);
        }
        if (vk is >= 0x60 and <= 0x69) return (((char)('0' + vk - 0x60)).ToString(), $"Numpad{vk - 0x60}", 3);
        if (vk is >= 0x70 and <= 0x87) return ($"F{vk - 0x6F}", $"F{vk - 0x6F}", 0);
        var code = vk switch
        {
            >= 0x41 and <= 0x5A => "Key" + (char)vk,
            >= 0x30 and <= 0x39 => "Digit" + (char)vk,
            0xBA => "Semicolon",
            0xBB => "Equal",
            0xBC => "Comma",
            0xBD => "Minus",
            0xBE => "Period",
            0xBF => "Slash",
            0xC0 => "Backquote",
            0xDB => "BracketLeft",
            0xDC => "Backslash",
            0xDD => "BracketRight",
            0xDE => "Quote",
            _ => null,
        };
        if (code is null) return (null, "", 0);
        var ch = Character(vk, scan, shift);
        if (ch is null && vk is >= 0x41 and <= 0x5A) ch = ((char)(shift ? vk : vk + 32)).ToString();
        if (ch is null && vk is >= 0x30 and <= 0x39) ch = ((char)vk).ToString();
        return (ch, code, 0);
    }

    // The character the key types in the viewer's keyboard layout (this, the UI thread's), with
    // only Shift applied: Ctrl would turn letters into control characters.
    static string? Character(uint vk, uint scan, bool shift)
    {
        var state = new byte[256];
        if (shift) state[0x10] = 0x80;
        var buf = new StringBuilder(8);
        // Flag 4: don't disturb the keyboard's dead-key state.
        var n = ToUnicodeEx(vk, scan, state, buf, buf.Capacity, 4, GetKeyboardLayout(0));
        return n == 1 && !char.IsControl(buf[0]) ? buf.ToString(0, 1) : null;
    }

    public void Dispose()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook);
        if (hookThread != 0) PostThreadMessage(hookThread, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }
}
