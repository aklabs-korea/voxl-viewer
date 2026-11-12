// keys.log, next to settings.json: where each key went on its way to the remote (the key hook,
// the window, WebView2, the page), and the focus and screen changes around it, so a lost or
// stuck key can be traced to the layer that lost it. It names only modifiers, F keys, Esc,
// Caps Lock and the IME's keys; every other key is "key", so no text or letter is ever written.
// Keys typed while no viewer window is in front aren't written at all. At most two files of
// 1 MB: keys.log and keys.old.log.
using System.Collections.Concurrent;
using System.Text;

namespace VoxlViewer;

static class KeyLog
{
    static readonly string FilePath = Path.Combine(Settings.Dir, "keys.log");
    static readonly ConcurrentQueue<string> lines = new();
    static readonly object file = new();
    static int queued;

    // From any thread, the key hook's too: it only queues the line, and a pool thread writes it.
    public static void Write(string what)
    {
        lines.Enqueue($"{DateTime.Now:HH:mm:ss.fff} {what}");
        if (Interlocked.Exchange(ref queued, 1) == 0) ThreadPool.QueueUserWorkItem(_ => Flush());
    }

    static void Flush()
    {
        Thread.Sleep(200); // a burst of keys goes in one write
        Interlocked.Exchange(ref queued, 0);
        lock (file)
        {
            var text = new StringBuilder();
            while (lines.TryDequeue(out var line)) text.Append(line).Append('\n');
            if (text.Length == 0) return;
            try
            {
                Directory.CreateDirectory(Settings.Dir);
                if (new FileInfo(FilePath) is { Exists: true, Length: > 1_000_000 })
                    File.Move(FilePath, Path.ChangeExtension(FilePath, ".old.log"), overwrite: true);
                File.AppendAllText(FilePath, text.ToString());
            }
            catch (Exception)
            {
                // A log that can't be written changes nothing else.
            }
        }
    }

    // A Windows virtual-key code as the log may name it.
    public static string Name(uint vk) => vk switch
    {
        0x5B => "LWin", 0x5C => "RWin",
        0xA0 => "LShift", 0xA1 => "RShift", 0x10 => "Shift",
        0xA2 => "LCtrl", 0xA3 => "RCtrl", 0x11 => "Ctrl",
        0xA4 => "LAlt", 0xA5 => "RAlt", 0x12 => "Alt",
        0x1B => "Esc", 0x14 => "CapsLock",
        0x15 => "Han/Eng", 0x19 => "Hanja", 0xE5 => "IME",
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        _ => "key",
    };
}
