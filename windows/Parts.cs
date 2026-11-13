// Part of a screen: the screen's key (F1..F9) or its tab again steps Whole, Left half, Right half,
// the window under the remote's pointer, Whole. Each screen keeps its part. The stream doesn't
// change: the page zooms into it (shared/part.js, embedded), so a switch is instant and nobody
// else's view changes.
//
// A window part asks the screen's voxl where the window is twice a second (voxl's window routes):
// the view follows it, goes to the machine's other screen with it, and back to Whole when it's
// closed or minimized. With Fit window on, voxl gives that window this window's shape, and puts it
// back when the part changes or the window closes, unless it was moved or resized at the remote since.
using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;

namespace VoxlViewer;

enum PartKind { Whole, Left, Right, Window }

// Window: where the window is, as fractions of the screen [x, y, w, h].
readonly record struct Part(PartKind Kind, ulong Id = 0, string App = "", double[]? Window = null)
{
    // The part as fractions of the screen, null for all of it.
    public double[]? Box => Kind switch
    {
        PartKind.Left => [0, 0, 0.5, 1],
        PartKind.Right => [0.5, 0, 0.5, 1],
        PartKind.Window => Window,
        _ => null,
    };

    public string Name => Kind switch
    {
        PartKind.Left => "Left half",
        PartKind.Right => "Right half",
        PartKind.Window => App.Length == 0 ? "Window" : App,
        _ => "Whole",
    };
}

sealed partial class ViewerForm
{
    static readonly string PartScript = ReadPartScript();
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(3) };

    readonly Dictionary<string, Part> parts = new(); // by screen URL
    readonly System.Windows.Forms.Timer follow = new() { Interval = 500 };
    readonly System.Windows.Forms.Timer fitLater = new() { Interval = 400 };
    int partTurn;      // bumped by every change of screen or part: answers to earlier questions are dropped
    bool asking;
    DateTime fitAsked;

    static string ReadPartScript()
    {
        using var s = typeof(ViewerForm).Assembly.GetManifestResourceStream("part.js");
        return s is null ? "" : new StreamReader(s).ReadToEnd();
    }

    void SetUpParts()
    {
        follow.Tick += (_, _) => AskWhere();
        fitLater.Tick += (_, _) =>
        {
            fitLater.Stop();
            FitWindow();
        };
    }

    Part CurrentPart => parts.GetValueOrDefault(ShownScreen.Url);

    public string PartLabel => CurrentPart.Kind == PartKind.Whole ? ScreenLabel(row) : $"{ScreenLabel(row)} · {CurrentPart.Name}";

    // Screen r's page, Full or Sharp: its voxl answers the window routes.
    string PageOf(int r) => UsesSharp ? machine.Screens[r].Sharp! : machine.Screens[r].Url;

    // The screen's key or tab again.
    void Step()
    {
        switch (CurrentPart.Kind)
        {
            case PartKind.Whole: SetPart(new(PartKind.Left)); break;
            case PartKind.Left: SetPart(new(PartKind.Right)); break;
            case PartKind.Right: PickWindow(); break;
            default: SetPart(default); break;
        }
    }

    // Shows part p of the screen on show, and says so (or note).
    void SetPart(Part p, string? note = null)
    {
        if (CurrentPart.Kind == PartKind.Window && (p.Kind != PartKind.Window || p.Id != CurrentPart.Id)) LeaveWindow();
        parts[ShownScreen.Url] = p;
        KeyLog.Write($"{machine.Name} screen {row + 1} part {p.Kind}");
        ShowPart();
        chip.Say(note ?? PartLabel, note is null ? 1200 : 3000);
        UpdateTitle();
        WatchWindow();
    }

    // The page zooms to the part.
    void ShowPart()
    {
        if (Core is not { } core) return;
        var box = CurrentPart.Box is { } b ? "[" + string.Join(",", b.Select(v => v.ToString(CultureInfo.InvariantCulture))) + "]" : "null";
        _ = core.ExecuteScriptAsync($"window.voxlPart && voxlPart({box})");
    }

    // The window under the remote's pointer becomes the part; with none, the whole screen.
    async void PickWindow()
    {
        var turn = partTurn;
        var (status, j) = await WindowCall(PageOf(row), "/window/at-pointer");
        if (turn != partTurn || IsDisposed) return;
        if (status != 200 || Id(j) is not { } id)
        {
            SetPart(default, status == 204 ? "No window under the pointer: whole screen" : $"{ShownScreen.Name} can't show one window: whole screen");
            return;
        }
        var app = Str(j, "app");
        if (Flag(j, "elsewhere")) FindWindow(id, app);
        else if (WindowBox(j) is { } box) SetPart(new(PartKind.Window, id, app, box));
        else SetPart(default);
    }

    // While the part is a window: fits it, and asks where it is twice a second.
    void WatchWindow()
    {
        partTurn++;
        follow.Stop();
        fitLater.Stop();
        if (CurrentPart.Kind != PartKind.Window) return;
        FitWindow();
        follow.Start();
    }

    // The view follows the window. Moved to another of the machine's screens, that screen comes on
    // show with it; closed or minimized, the whole screen.
    async void AskWhere()
    {
        if (asking || CurrentPart is not { Kind: PartKind.Window } p) return;
        var turn = partTurn;
        var url = ShownScreen.Url;
        asking = true;
        var (status, j) = await WindowCall(PageOf(row), $"/window/{p.Id}");
        asking = false;
        if (turn != partTurn || IsDisposed) return;
        if (status == 404)
        {
            SetPart(default, $"{(p.App.Length == 0 ? "The window" : p.App)} closed or minimized: whole screen");
            return;
        }
        if (status != 200) return; // voxl restarting or offline: ask again
        if (Flag(j, "elsewhere"))
        {
            FindWindow(p.Id, p.App);
            return;
        }
        if (WindowBox(j) is { } box && !box.SequenceEqual(p.Window!))
        {
            parts[url] = p with { Window = box };
            ShowPart();
        }
        // Not fitted (yet, or any more after a while unasked): fit it. Moved or resized at the remote
        // ("changed"), it stays as it is.
        var fit = j.TryGetProperty("fit", out var f) ? f.GetString() : null;
        if (Prefs.Fit != FitSize.Off && fit is null && DateTime.UtcNow - fitAsked > TimeSpan.FromSeconds(5)) FitWindow();
        if (Prefs.Fit == FitSize.Off && fit == "on") _ = WindowCall(PageOf(row), $"/window/{p.Id}/restore", new { });
    }

    // Has voxl give the part's window this window's shape: Large is one remote pixel per point here,
    // Fine one per pixel here, Medium in between.
    async void FitWindow()
    {
        if (Prefs.Fit == FitSize.Off || CurrentPart is not { Kind: PartKind.Window } p) return;
        fitAsked = DateTime.UtcNow;
        var k = DeviceDpi / 96.0;
        var f = Prefs.Fit switch { FitSize.Medium => Math.Sqrt(k), FitSize.Fine => k, _ => 1.0 };
        var area = PictureArea.Size; // pixels here
        var turn = partTurn;
        var url = ShownScreen.Url;
        var (status, j) = await WindowCall(PageOf(row), $"/window/{p.Id}/fit",
            new { w = Math.Round(area.Width / k * f), h = Math.Round(area.Height / k * f) });
        if (turn != partTurn || IsDisposed || status != 200 || WindowBox(j) is not { } box) return;
        parts[url] = p with { Window = box };
        ShowPart();
    }

    // After this window changes size: fits again once it has settled.
    void FitSoon()
    {
        fitLater.Stop();
        if (CurrentPart.Kind == PartKind.Window && Prefs.Fit != FitSize.Off) fitLater.Start();
    }

    // Fit window changed (in any window).
    public void FitChanged()
    {
        if (CurrentPart is not { Kind: PartKind.Window } p) return;
        if (Prefs.Fit == FitSize.Off) _ = WindowCall(PageOf(row), $"/window/{p.Id}/restore", new { });
        else FitWindow();
    }

    // The part's window moved to another of the machine's screens: that screen, showing it.
    async void FindWindow(ulong id, string app)
    {
        var turn = partTurn;
        for (var r = 0; r < machine.Screens.Count; r++)
        {
            if (r == row) continue;
            var (status, j) = await WindowCall(PageOf(r), $"/window/{id}");
            if (turn != partTurn || IsDisposed) return;
            if (status != 200 || Flag(j, "elsewhere") || WindowBox(j) is not { } box) continue;
            LeaveWindow();
            parts[ShownScreen.Url] = default;
            parts[machine.Screens[r].Url] = new(PartKind.Window, id, app, box);
            Connect(r);
            return;
        }
        SetPart(default, $"{(app.Length == 0 ? "The window" : app)} is on a screen not in this window: whole screen");
    }

    // Stops following the part's window and has voxl put it back, unless it was moved or resized at
    // the remote since. The screen keeps its part for when it's on show again.
    void LeaveWindow(bool wait = false)
    {
        follow.Stop();
        fitLater.Stop();
        partTurn++;
        if (CurrentPart is not { Kind: PartKind.Window } p) return;
        var page = PageOf(row);
        // Waited for when the window closes, off this thread: the answer would come back to it.
        var call = Task.Run(() => WindowCall(page, $"/window/{p.Id}/restore", new { }));
        if (wait) call.Wait(1000);
    }

    // voxl's window routes on a screen's voxl, with the screen's password if it has one. Status 0:
    // no answer.
    static async Task<(int Status, JsonElement Json)> WindowCall(string page, string path, object? body = null)
    {
        try
        {
            var uri = new Uri(page);
            // voxl listens on IPv4 by default, and Windows takes 2 s to give up on localhost's IPv6.
            if (uri.IsLoopback && uri.Host == "localhost") uri = new UriBuilder(uri) { Host = "127.0.0.1" }.Uri;
            using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, new Uri(uri, path));
            request.Headers.Add("X-Voxl-Window", "1");
            var token = uri.Query.TrimStart('?').Split('&').Select(q => q.Split('=', 2))
                .FirstOrDefault(q => q[0] == "token" && q.Length == 2)?[1];
            if (token is not null)
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Uri.UnescapeDataString(token));
            else if (Credentials.Read(Credentials.Target(uri)) is { } login)
                request.Headers.Authorization = new AuthenticationHeaderValue("Basic",
                    Convert.ToBase64String(Encoding.UTF8.GetBytes($"{login.User}:{login.Password}")));
            if (body is not null) request.Content = JsonContent.Create(body);
            using var response = await Http.SendAsync(request);
            var text = await response.Content.ReadAsStringAsync();
            var json = default(JsonElement);
            try
            {
                if (text.Length > 0) json = JsonDocument.Parse(text).RootElement.Clone();
            }
            catch (JsonException)
            {
            }
            return ((int)response.StatusCode, json);
        }
        catch (Exception)
        {
            return (0, default);
        }
    }

    static double? Number(JsonElement j, string name) =>
        j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var v) && v.TryGetDouble(out var d) ? d : null;

    static ulong? Id(JsonElement j) =>
        j.ValueKind == JsonValueKind.Object && j.TryGetProperty("id", out var v) && v.TryGetUInt64(out var id) ? id : null;

    static string Str(JsonElement j, string name) =>
        j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";

    static bool Flag(JsonElement j, string name) =>
        j.ValueKind == JsonValueKind.Object && j.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    // Where voxl says the window is, as fractions of the screen, cut to the screen.
    static double[]? WindowBox(JsonElement j)
    {
        if (Number(j, "x") is not { } x || Number(j, "y") is not { } y || Number(j, "w") is not { } w || Number(j, "h") is not { } h
            || !j.TryGetProperty("screen", out var s) || Number(s, "w") is not { } sw || Number(s, "h") is not { } sh || sw <= 0 || sh <= 0)
            return null;
        double x0 = Math.Max(0, x / sw), y0 = Math.Max(0, y / sh), x1 = Math.Min(1, (x + w) / sw), y1 = Math.Min(1, (y + h) / sh);
        return x1 > x0 && y1 > y0 ? [x0, y0, x1 - x0, y1 - y0] : null;
    }
}
