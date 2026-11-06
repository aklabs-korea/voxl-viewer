// The saved machines and window places, in %LOCALAPPDATA%\voxl-viewer\settings.json, and the
// Start-menu shortcuts. Passwords typed at voxl's prompt go to Credential Manager instead
// (Credentials.cs); a URL with ?token= is kept as given, here and in its shortcut.
using System.Text.Json;

namespace VoxlViewer;

// IsMac: the Win key goes to the page as the Mac's Control key (WinKeys.cs).
// CpuDecode: WebView2 decodes video on the CPU, for GPUs that can't decode the remote's size.
sealed record Machine(string Name, string Url, bool IsMac = false, bool CpuDecode = false);

sealed record Place(int X, int Y, int Width, int Height, bool Maximized);

sealed class Settings
{
    public List<Machine> Machines { get; set; } = new();
    public string? Last { get; set; }
    // Window places by machine URL.
    public Dictionary<string, Place> Windows { get; set; } = new();

    public static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "voxl-viewer");
    static readonly string FilePath = Path.Combine(Dir, "settings.json");
    static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public static Settings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json) ?? new();
        }
        catch (Exception)
        {
            return new();
        }
    }

    public void Save()
    {
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

    public Machine? Find(string? url) => Machines.Find(m => m.Url == url);

    // An http(s) URL in one spelling, so the same machine always has the same key. A missing
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

// One Start-menu entry per machine, in a "voxl viewer" folder (install.ps1 puts the app there too).
static class StartMenu
{
    static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "voxl viewer");

    static string PathFor(Machine m)
    {
        var name = string.Concat(m.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c)).Trim(' ', '.');
        return Path.Combine(Folder, (name.Length > 0 ? name : "voxl") + ".lnk");
    }

    public static void Add(Machine m)
    {
        Directory.CreateDirectory(Folder);
        var exe = Environment.ProcessPath ?? Application.ExecutablePath;
        dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell")!)!;
        var link = shell.CreateShortcut(PathFor(m));
        link.TargetPath = exe;
        link.Arguments = $"\"{m.Url}\" \"{m.Name}\"";
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
}
