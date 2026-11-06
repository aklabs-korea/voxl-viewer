// The saved machines, window places and the two choices every window shares, in
// %LOCALAPPDATA%\voxl-viewer\settings.json, and the Start-menu shortcuts. Passwords typed at voxl's
// prompt go to Credential Manager instead (Credentials.cs); a URL with ?token= is kept as given,
// here and in its shortcut.
//
// The file, for a script that seeds it (a machine needs only "name" and a screen with a "url"):
//   {
//     "machines": [
//       { "name": "M3", "isMac": true, "cpuDecode": true, "screens": [
//           { "name": "bottom", "url": "https://m3.example.ts.net:6901/", "sharp": "https://m3.example.ts.net:6903/" },
//           { "name": "top", "url": "https://m3.example.ts.net:6902/", "sharp": "https://m3.example.ts.net:6904/" } ] },
//       { "name": "M1", "isMac": true, "screens": [ { "name": "M1", "url": "https://m1.example.ts.net:6901/" } ] }
//     ],
//     "last": "M3",
//     "windows": { "M3": { "x": 0, "y": 0, "width": 1280, "height": 800, "maximized": true } },
//     "edge": "top",
//     "sharp": false
//   }
// Screens are in the user's order: the first opens with the window and Win+Alt+N goes to the Nth.
// A screen's "sharp" is a smaller stream of it; the top-level "sharp" shows those (Sharp) instead
// of the screens' own (Full) on machines whose every screen has one. "last" is the machine a plain
// launch opens, "windows" each machine's window place, "edge" where the switcher's tab is (top,
// left, bottom or right). Settings saved before screens existed (one "url" per machine, places
// and "last" by URL) load as one-screen machines. The app also writes each machine's "url" (its
// first screen's) for older viewers and scripts; a seed needn't, as "screens" wins.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VoxlViewer;

// One of a machine's screens: its voxl page, and optionally Sharp, a smaller stream of the same screen.
sealed record Screen(string Name, string Url, string? Sharp = null);

// IsMac: the Win key goes to the page as the Mac's Control key (WinKeys.cs).
// CpuDecode: WebView2 decodes Full video on the CPU, for GPUs that can't decode the remote's size.
sealed record Machine(string Name, IReadOnlyList<Screen> Screens, bool IsMac = false, bool CpuDecode = false)
{
    // A machine's one URL from before screens: read from old settings as its first screen, and
    // written as its first screen's for older viewers and scripts that read it.
    [JsonPropertyName("url")]
    public string? OldUrl { get; init; }

    // Full | Sharp is a choice only when every screen has a Sharp stream.
    [JsonIgnore]
    public bool HasSharp => Screens.All(s => s.Sharp is not null);

    public static Machine One(string name, string url, bool isMac = false, bool cpuDecode = false) =>
        new(name, new[] { new Screen(name, url) }, isMac, cpuDecode);

    public bool Owns(string url) => Screens.Any(s => s.Url == url || s.Sharp == url);
}

sealed record Place(int X, int Y, int Width, int Height, bool Maximized);

enum Side { Top, Left, Bottom, Right }

sealed class Settings
{
    public List<Machine> Machines { get; set; } = new();
    // A machine's name.
    public string? Last { get; set; }
    // Window places by machine name.
    public Dictionary<string, Place> Windows { get; set; } = new();
    public string? Edge { get; set; } = "top";
    public bool Sharp { get; set; }

    public static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "voxl-viewer");
    static readonly string FilePath = Path.Combine(Dir, "settings.json");
    static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static Settings Load()
    {
        Settings? settings;
        try
        {
            settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json);
        }
        catch (Exception)
        {
            settings = null;
        }
        settings ??= new();
        settings.Upgrade();
        return settings;
    }

    public void Save()
    {
        Machines = Machines.Select(m => m with { OldUrl = m.Screens[0].Url }).ToList();
        Directory.CreateDirectory(Dir);
        var temp = FilePath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
        File.Move(temp, FilePath, true);
    }

    // Load, edit, save. A failed write (another viewer process writing at the same moment) only
    // loses this one change.
    public static void Change(Action<Settings> edit)
    {
        var settings = Load();
        edit(settings);
        try
        {
            settings.Save();
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    public Machine? Find(string? name) => Machines.Find(m => m.Name == name);

    // The machine with a screen at this URL, Full or Sharp.
    public Machine? FindByUrl(string url) => Machines.Find(m => m.Owns(url));

    // Settings from before screens kept one URL per machine, and window places and "last" by that
    // URL. What can't work (a screen without a usable URL, a machine without screens) is dropped.
    void Upgrade()
    {
        Machines = (Machines ?? new()).Select(Upgrade).OfType<Machine>().ToList();
        Windows ??= new();
        foreach (var key in Windows.Keys.Where(k => k.Contains("://")).ToList())
        {
            if (FindByUrl(key) is { } m && !Windows.ContainsKey(m.Name))
            {
                Windows[m.Name] = Windows[key];
                Windows.Remove(key);
            }
        }
        if (Last is not null && Last.Contains("://")) Last = FindByUrl(Last)?.Name;
    }

    static Machine? Upgrade(Machine? m)
    {
        if (m is null) return null;
        var given = m.Screens ?? (m.OldUrl is null ? Array.Empty<Screen>() : new[] { new Screen(m.Name, m.OldUrl) });
        var screens = new List<Screen>();
        foreach (var s in given)
        {
            if (s is null || NormalizeUrl(s.Url ?? "") is not { } url) continue;
            screens.Add(new Screen(NameOr(s.Name, url), url, s.Sharp is null ? null : NormalizeUrl(s.Sharp)));
        }
        return screens.Count == 0 ? null : new Machine(NameOr(m.Name, screens[0].Url), screens, m.IsMac, m.CpuDecode);
    }

    // A name, or the URL's host and port when there's none.
    public static string NameOr(string? name, string url) =>
        string.IsNullOrWhiteSpace(name) ? new Uri(url).Authority : name.Trim();

    // An http(s) URL in one spelling, so the same screen always has the same key. A missing
    // scheme means https.
    public static string? NormalizeUrl(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return null;
        if (!text.Contains("://")) text = "https://" + text;
        return Uri.TryCreate(text, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp)
            && uri.Host.Length > 0
            ? uri.AbsoluteUri
            : null;
    }
}

// The two choices every window shares: the switcher's edge, and Full or Sharp. Read once, saved
// when changed.
static class Prefs
{
    public static Side Edge { get; private set; }
    public static bool Sharp { get; private set; }

    static Prefs()
    {
        var settings = Settings.Load();
        Edge = settings.Edge?.Trim().ToLowerInvariant() switch
        {
            "left" => Side.Left,
            "bottom" => Side.Bottom,
            "right" => Side.Right,
            _ => Side.Top,
        };
        Sharp = settings.Sharp;
    }

    public static void SetEdge(Side side)
    {
        Edge = side;
        Settings.Change(s => s.Edge = side.ToString().ToLowerInvariant());
    }

    public static void SetSharp(bool on)
    {
        Sharp = on;
        Settings.Change(s => s.Sharp = on);
    }
}

// One Start-menu entry per machine, in a "voxl viewer" folder (install.ps1 puts the app there too).
// It opens the machine's first screen by URL, with the machine's name.
static class StartMenu
{
    static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "voxl viewer");

    // The entry's file name for a machine name: two machines whose names give the same one would share it.
    public static string FileName(string machineName)
    {
        var name = string.Concat(machineName.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim(' ', '.');
        return (name.Length > 0 ? name : "voxl") + ".lnk";
    }

    // Each machine's entry is named after it, so machine names must differ by this.
    public static bool SameName(string a, string b) =>
        string.Equals(FileName(a), FileName(b), StringComparison.OrdinalIgnoreCase);

    static string PathFor(Machine m) => Path.Combine(Folder, FileName(m.Name));

    public static void Add(Machine m)
    {
        Directory.CreateDirectory(Folder);
        var exe = Environment.ProcessPath ?? Application.ExecutablePath;
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
        var link = shell.CreateShortcut(PathFor(m));
        link.TargetPath = exe;
        link.Arguments = $"\"{m.Screens[0].Url}\" \"{m.Name}\"";
        link.WorkingDirectory = Path.GetDirectoryName(exe);
        link.IconLocation = exe + ",0";
        link.Description = m.Name + " through voxl";
        link.Save();
    }

    // After an edit or a removal: an entry the machine had follows it, or goes with it.
    public static void Update(Machine old, Machine? now)
    {
        var path = PathFor(old);
        if (!File.Exists(path)) return;
        File.Delete(path);
        if (now is not null) Add(now);
    }

    // A Start-menu change that fails is reported, not fatal.
    public static bool Try(IWin32Window owner, Action action)
    {
        try
        {
            action();
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(owner, "The Start-menu entry couldn't be changed: " + ex.Message, "voxl viewer",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }
}
