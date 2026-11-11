// One machine's window. It shows one of the machine's screens at a time, in voxl's own page in
// WebView2, and adds only what a browser tab can't do:
// - F1..F9 (WinKeys.cs), the tab row (ScreenTabs.cs) and, in full screen, a tab at the window's
//   edge (Switcher.cs) go to the machine's screens, Full or Sharp; a chip in the middle names the
//   screen while it connects;
// - WebView2's browser shortcuts are off, so Ctrl+W/T/R/F5 reach the remote machine;
// - for a Mac, the Win key reaches the page as the Mac's Control key (WinKeys.cs);
// - F11 is borderless full screen; the window menu (click the icon or right-click the title bar)
//   has the machines, Settings, Reload and voxl's stats overlay;
// - voxl's password can be kept in Windows Credential Manager;
// - a screen that doesn't answer is tried again every 3 s, and never swapped for another by itself.
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using WinScreen = System.Windows.Forms.Screen;

namespace VoxlViewer;

sealed class ViewerForm : Form
{
    // Window-menu commands (Windows keeps the low four bits of WM_SYSCOMMAND for itself).
    const int CmdAdd = 0x1100, CmdSettings = 0x1110, CmdRemove = 0x1120, CmdStartMenu = 0x1130;
    const int CmdFullScreen = 0x1200, CmdReload = 0x1210, CmdStats = 0x1220;
    const int CmdMachine = 0x2000, MaxMachines = 200; // CmdMachine + 16 * index

    // What the page script below posts once a screen's picture is on.
    const string Picture = "voxl-viewer:picture";

    // Runs in each page before voxl's own scripts.
    // - voxl's toolbar has a Full screen button whenever the page can go full screen. WebView2's
    //   page full screen only fills the window and ends on the next Esc, which belongs to the
    //   remote, so hide the button, as WebKit does on the Mac: F11 is this app's full screen.
    // - Keys typed while a screen connects would land on a screen nobody has seen yet: they go
    //   nowhere until its picture plays (voxl shows it in <video>s), or for 3 s. Before its page
    //   has loaded, the view is hidden and takes no keys at all (ShowView).
    const string PageScript = $$"""
        Object.defineProperty(Document.prototype, 'fullscreenEnabled', { get: () => false });
        if (window === window.top) {
          let hold = true, told = false;
          const drop = (e) => { if (hold) { e.stopImmediatePropagation(); e.preventDefault(); } };
          for (const type of ['keydown', 'keyup', 'keypress', 'input', 'compositionend', 'paste'])
            addEventListener(type, drop, true);
          setTimeout(() => { hold = false; }, 3000);
          addEventListener('playing', () => {
            hold = false;
            if (!told) { told = true; window.chrome?.webview?.postMessage('{{Picture}}'); }
          }, true);
        }
        """;

    // Every window shares one browser process, which the host leaves out of its audio capture.
    static Task<CoreWebView2Environment>? environment;
    static Icon? appIcon;

    Machine machine;
    int row;                    // the screen on show
    readonly WebView2 web;
    bool started;               // this view's WebView2 is up
    DateTime browserStarted;    // a new browser stays muted while the host notices it
    readonly System.Windows.Forms.Timer audioTimer = new() { Interval = 250 };
    string? shownUrl;           // the screen page the view was last sent to, without ?stats
    bool loading;               // that page hasn't loaded yet: the view is hidden
    bool down;                  // that page didn't answer: the view is hidden while it's tried again
    bool starting;              // Connect asked for that page and its load hasn't started yet
    ulong navigation;           // the load started last: only its end says how the screen is
    WinKeys? winKeys;
    readonly Chip chip;
    readonly Switcher switcher;
    readonly ScreenTabs tabs;
    SettingsForm? settings;
    bool stats, fullScreen, f11Down, forget;
    long f11Time;
    int retryId; // bumped by each success, connect and scheduled retry: only the latest retry runs
    FormWindowState savedState;
    Rectangle savedBounds;
    int menuBase = -1;
    List<Machine> menuMachines = new();
    // Basic auth: whether this load already answered a challenge, and what to save once a login works.
    bool answered;
    (string Target, string User, string Password, bool Keep)? pendingLogin;

    public ViewerForm(Machine machine)
    {
        this.machine = machine;
        stats = new Uri(machine.Screens[0].Url).Query.TrimStart('?').Split('&').Any(IsStats);
        BackColor = Color.Black; // what shows while the view is hidden
        Icon = appIcon ??= Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        chip = new Chip(this);
        switcher = new Switcher(this);
        web = NewView();
        tabs = new ScreenTabs(this);
        UpdateTitle();
        PlaceWindow();
        Controls.Add(web);
        Controls.Add(tabs);
        web.BringToFront(); // docked last: it fills what the tab row leaves
        audioTimer.Tick += (_, _) => UpdateAudio();
    }

    public Machine Machine => machine;
    public int Row => row;
    public bool FullScreen => fullScreen;
    public CoreWebView2? Core => web.CoreWebView2;

    // Whether the page shown is the screen's, loaded: replayed keys (WinKeys.cs) go nowhere else.
    public bool TakesKeys => started && !loading && !down;

    // The picture's place on the screen: the window's client area, below the tab row.
    public Rectangle PictureArea
    {
        get
        {
            var area = ClientRectangle;
            if (tabs.Visible)
            {
                area.Y += tabs.Height;
                area.Height -= tabs.Height;
            }
            return RectangleToScreen(area);
        }
    }

    // The tab row is up: the edge tab stays away (it is for full screen).
    public bool TabsShown => tabs.Visible;

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);

    public bool InFront => IsHandleCreated && WindowState != FormWindowState.Minimized && GetForegroundWindow() == Handle;

    // Settings and dialogs owned by this window count for sound, but never take its remote keys.
    bool AudioInFront => IsHandleCreated && WindowState != FormWindowState.Minimized
        && GetAncestor(GetForegroundWindow(), 3) == Handle; // GA_ROOTOWNER

    public void UpdateAudio()
    {
        if (!started || IsDisposed || Core is not { } core) return;
        var audible = !loading && !down && AudioInFront && PhysicalInput.Recent
            && DateTime.UtcNow - browserStarted >= TimeSpan.FromSeconds(2);
        if (core.IsMuted != !audible) core.IsMuted = !audible;
    }

    // Pixels on this window's monitor for a size at 100%.
    public int Px(int size) => (int)Math.Round(size * DeviceDpi / 96.0);

    public string ScreenLabel(int i) => $"{i + 1} · {machine.Screens[i].Name}";

    public static string Shortcut(int i) => i < 9 ? $"F{i + 1}" : "";

    Screen ShownScreen => machine.Screens[row];
    bool UsesSharp => Prefs.Sharp && machine.HasSharp;
    // Sharp always decodes on the GPU; Full on the CPU when the machine asks for it.
    bool Cpu => machine.CpuDecode && !UsesSharp;
    string ScreenUrl => WithDecode(UsesSharp ? ShownScreen.Sharp! : ShownScreen.Url, Cpu);

    WebView2 NewView()
    {
        var view = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Black };
        view.KeyDown += OnWebKeyDown;
        view.KeyUp += OnWebKeyUp;
        return view;
    }

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        winKeys = new WinKeys(this, Handle) { Mac = machine.IsMac, Rows = machine.Screens.Count };
        tabs.Sync();
        var name = machine.Name;
        Settings.Change(s => s.Last = name);
        audioTimer.Start();
        StartView();
    }

    // Starts this window's WebView2 and connects the screen on show.
    async void StartView()
    {
        try
        {
            await web.EnsureCoreWebView2Async(await WebEnvironment());
            if (IsDisposed) return;
            var core = web.CoreWebView2;
            core.IsMuted = true;
            try
            {
                using var process = Process.GetProcessById((int)core.BrowserProcessId);
                browserStarted = process.StartTime.ToUniversalTime();
            }
            catch (Exception)
            {
                browserStarted = DateTime.UtcNow;
            }
            var options = core.Settings;
            options.AreBrowserAcceleratorKeysEnabled = false;
            options.AreDefaultContextMenusEnabled = false;
            options.IsStatusBarEnabled = false;
            options.IsZoomControlEnabled = false;
            options.IsPinchZoomEnabled = false;
            options.IsSwipeNavigationEnabled = false;
            options.IsGeneralAutofillEnabled = false;
            options.IsPasswordAutosaveEnabled = false;
            options.IsReputationCheckingRequired = false; // SmartScreen would send each URL to Microsoft
            options.IsBuiltInErrorPageEnabled = false; // a screen that doesn't answer shows black and the chip
            core.BasicAuthenticationRequested += OnBasicAuth;
            core.NavigationStarting += OnNavigationStarting;
            core.NavigationCompleted += OnNavigationCompleted;
            core.WebMessageReceived += OnWebMessage;
            core.ProcessFailed += OnProcessFailed;
            await core.AddScriptToExecuteOnDocumentCreatedAsync(PageScript);
        }
        catch (Exception ex)
        {
            if (IsDisposed) return;
            var help = ex is WebView2RuntimeNotFoundException
                ? "\n\nvoxl viewer needs the Microsoft Edge WebView2 Runtime: https://developer.microsoft.com/microsoft-edge/webview2/"
                : "";
            MessageBox.Show(this, ex.Message + help, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
            return;
        }
        if (IsDisposed) return;
        started = true;
        Connect(row);
    }

    static Task<CoreWebView2Environment> WebEnvironment() =>
        environment ??= CoreWebView2Environment.CreateAsync(null, Path.Combine(Settings.Dir, "WebView2"));

    // CPU decode is a page option, so Full | Sharp and decode changes use the same browser.
    // Other parameters, including ?token= and ?stats, stay.
    internal static string WithDecode(string url, bool cpu)
    {
        var b = new UriBuilder(url);
        var query = b.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(p => p != "decode" && !p.StartsWith("decode=")).ToList();
        if (cpu) query.Add("decode=cpu");
        b.Query = string.Join("&", query);
        return b.Uri.AbsoluteUri;
    }

    // voxl's page with or without its ?stats overlay; other parameters such as ?token= stay.
    internal static string WithStats(string url, bool stats)
    {
        var b = new UriBuilder(url);
        var query = b.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Where(p => !IsStats(p)).ToList();
        if (stats) query.Add("stats");
        b.Query = string.Join("&", query);
        return b.Uri.AbsoluteUri;
    }

    static bool IsStats(string part) => part == "stats" || part.StartsWith("stats=");

    // ------------------------------------------------------------------ screens

    // Sends the view to screen `to`. Until its page has loaded the view is hidden (black, and no
    // keys reach the page being left), so a screen slow to answer never shows the old one under
    // its name. The chip names it until its picture is on, or for 3 s once its page has loaded; a
    // retry of a screen that isn't answering keeps the chip that says so.
    void Connect(int to, bool retry = false)
    {
        row = Math.Clamp(to, 0, machine.Screens.Count - 1);
        retryId++;
        UpdateTitle();
        tabs.Invalidate();
        if (!retry) chip.Say(ScreenLabel(row), 0);
        if (Core is not { } core) return; // StartView connects once WebView2 is up
        loading = true;
        ShowView();
        shownUrl = ScreenUrl;
        answered = false;
        pendingLogin = null; // a password typed for the page being left is saved only if that page loads
        starting = true;
        // The same browser keeps its mute and its age; a switch doesn't start another grace.
        core.Navigate(WithStats(shownUrl, stats));
    }

    // F1..F9, a tab, or a screen in the switcher's panel. The screen on show only shows its name again.
    public void SwitchTo(int to)
    {
        if (to >= machine.Screens.Count) chip.Say($"{machine.Name} has no screen {to + 1}", 1500);
        else if (to != row) Connect(to);
        else if (!down && !loading) chip.Say(ScreenLabel(row), 900);
    }

    // The ticked screen in the panel, or Reload: the screen on show again, for a stuck picture.
    public void Reconnect() => Connect(row);

    // Full | Sharp is one choice for every window; each one whose machine has Sharp streams follows.
    public static void SetSharp(bool on)
    {
        if (on == Prefs.Sharp) return;
        Prefs.SetSharp(on);
        foreach (var window in Program.Windows.ToList()) window.ApplyView();
    }

    // A change from Settings: the machine as saved, and where the screen on show is now.
    public void Apply(Machine now, int nowRow)
    {
        machine = now;
        row = Math.Clamp(nowRow, 0, now.Screens.Count - 1);
        if (winKeys is not null)
        {
            if (winKeys.Mac && !now.IsMac) winKeys.Reset();
            winKeys.Mac = now.IsMac;
            winKeys.Rows = now.Screens.Count;
        }
        ApplyView();
    }

    // After a change to the machine or to Full | Sharp: the screen again if its address or decode
    // changed. Nothing else reconnects.
    void ApplyView()
    {
        UpdateTitle();
        tabs.Sync();
        if (shownUrl is not null && ScreenUrl != shownUrl) Connect(row);
    }

    // "M3 · top · Sharp": the machine, the screen (left out when it's the only one and named the
    // same) and Full or Sharp when the machine has the choice.
    void UpdateTitle()
    {
        var text = machine.Name;
        if (machine.Screens.Count > 1 || ShownScreen.Name != machine.Name) text += " · " + ShownScreen.Name;
        if (machine.HasSharp) text += UsesSharp ? " · Sharp" : " · Full";
        Text = down ? text + " (not answering)" : text;
    }

    public void OpenSettings()
    {
        if (settings is { IsDisposed: false })
        {
            settings.Activate();
            return;
        }
        settings = new SettingsForm(this);
        settings.Show(this);
    }

    // ------------------------------------------------------------------ loading and passwords

    // Connect's load, or one the page starts itself (a redirect keeps its load's id).
    void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        starting = false;
        navigation = e.NavigationId;
    }

    async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        // A load cut short by the next one (a switch, a retry), or one that ends after Connect asked
        // for the next, says nothing about the screen on show.
        if (starting || e.NavigationId != navigation) return;
        // Cut short while the page is on show, as a download from voxl's Files panel is: nothing
        // changed. Connect's own load cut short is tried again, below.
        if (e.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled && !loading) return;
        if (e.IsSuccess && e.HttpStatusCode < 500)
        {
            retryId++; // a retry still waiting is dropped; a later failure schedules its own
            answered = false;
            if (pendingLogin is { } login)
            {
                if (login.Keep) Credentials.Write(login.Target, login.User, login.Password);
                else Credentials.Delete(login.Target);
                pendingLogin = null;
            }
            if (Loaded(answering: true)) chip.Say(ScreenLabel(row), 0);
            chip.FadeBy(3000); // sooner when the picture comes (OnWebMessage)
            return;
        }
        // No retry fixes a wrong password, a bad certificate or a missing page.
        if (e.HttpStatusCode < 500 && (e.HttpStatusCode >= 400 || e.WebErrorStatus is
                CoreWebView2WebErrorStatus.ValidAuthenticationCredentialsRequired
                or CoreWebView2WebErrorStatus.ValidProxyAuthenticationRequired
                or CoreWebView2WebErrorStatus.CertificateCommonNameIsIncorrect
                or CoreWebView2WebErrorStatus.CertificateExpired
                or CoreWebView2WebErrorStatus.CertificateIsInvalid
                or CoreWebView2WebErrorStatus.CertificateRevoked
                or CoreWebView2WebErrorStatus.ClientCertificateContainsErrors))
        {
            Loaded(answering: true);
            chip.Say(Problem(e), 0);
            return;
        }
        // The machine is offline, voxl restarts behind a proxy that answers 502, or the load was cut
        // short with nothing after it: black and the chip while it's tried again (voxl's page
        // reconnects on its own once it has loaded).
        Loaded(answering: false);
        chip.Say(NotAnswering(), 0);
        var id = ++retryId;
        await Task.Delay(3000);
        // A switch or a reload in the meantime may have worked: don't cut that session off.
        if (id != retryId || IsDisposed) return;
        Connect(row, retry: true);
    }

    // The page loaded, or didn't answer: the view shows it, or stays hidden while it's tried
    // again. true when the screen answers again after not answering.
    bool Loaded(bool answering)
    {
        var back = down && answering;
        var changed = down == answering;
        loading = false;
        down = !answering;
        ShowView();
        UpdateAudio();
        if (changed) UpdateTitle();
        return back;
    }

    string Problem(CoreWebView2NavigationCompletedEventArgs e)
    {
        var name = ShownScreen.Name;
        if (e.HttpStatusCode == 401 || e.WebErrorStatus is CoreWebView2WebErrorStatus.ValidAuthenticationCredentialsRequired
                or CoreWebView2WebErrorStatus.ValidProxyAuthenticationRequired)
            return $"{name} wants voxl's password. Reload to sign in.";
        return e.HttpStatusCode >= 400 ? $"{name} answered {e.HttpStatusCode}." : $"{name}'s certificate isn't valid.";
    }

    // With the way to the first screen, or to the second when the first is the one down.
    string NotAnswering()
    {
        var text = $"{ShownScreen.Name} isn't answering. Trying again every 3 s.";
        var other = row != 0 ? 0 : machine.Screens.Count > 1 ? 1 : -1;
        return other < 0 ? text : $"{text}\n{Shortcut(other)}: {machine.Screens[other].Name}";
    }

    // The page script's word that the picture is on: the chip goes. Only from the screen on show.
    void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (down || shownUrl is null || e.WebMessageAsJson != "\"" + Picture + "\"") return;
        if (Uri.TryCreate(e.Source, UriKind.Absolute, out var from) && Uri.Compare(from, new Uri(shownUrl),
                UriComponents.SchemeAndServer, UriFormat.Unescaped, StringComparison.OrdinalIgnoreCase) == 0)
            chip.FadeBy(0);
    }

    // With WebView2's error pages off, a page whose process died would stay black: load it again.
    void OnProcessFailed(object? sender, CoreWebView2ProcessFailedEventArgs e)
    {
        if (e.ProcessFailedKind == CoreWebView2ProcessFailedKind.RenderProcessExited) BeginInvoke(Reconnect);
    }

    // voxl may ask for its password (HTTP Basic). A saved one is tried first; the dialog runs after
    // the event returns, not inside WebView2's callback.
    void OnBasicAuth(object? sender, CoreWebView2BasicAuthenticationRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();
        BeginInvoke(() =>
        {
            try
            {
                AnswerLogin(e);
            }
            finally
            {
                deferral.Complete();
            }
        });
    }

    void AnswerLogin(CoreWebView2BasicAuthenticationRequestedEventArgs e)
    {
        var uri = new Uri(e.Uri);
        var target = Credentials.Target(uri);
        var saved = Credentials.Read(target);
        if (!answered && saved is { } login)
        {
            answered = true;
            e.Response.UserName = login.User;
            e.Response.Password = login.Password;
            return;
        }
        using var dialog = new PasswordDialog(uri.Host, saved?.User, answered);
        if (dialog.ShowDialog(this) != DialogResult.OK)
        {
            e.Cancel = true;
            return;
        }
        answered = true;
        e.Response.UserName = dialog.User;
        e.Response.Password = dialog.Password;
        // Saved (or a saved one forgotten) only once the page loads with it.
        pendingLogin = (target, dialog.User, dialog.Password, dialog.Remember);
    }

    // ------------------------------------------------------------------ keys

    // F11 reaches WebView2 as an accelerator key; handled here, the page never sees it.
    void OnWebKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.KeyData != Keys.F11) return;
        e.Handled = true;
        // Autorepeat arrives as more key-downs. The time limit keeps a lost key-up from eating the
        // next press.
        var now = Environment.TickCount64;
        var repeat = f11Down && now - f11Time < 1500;
        f11Down = true;
        f11Time = now;
        if (!repeat) BeginInvoke(ToggleFullScreen); // the browser process waits while this handler runs
    }

    void OnWebKeyUp(object? sender, KeyEventArgs e)
    {
        // Only the release of an F11 handled here: Shift+F11 and the like went to the remote, press and release.
        if (e.KeyCode != Keys.F11 || !f11Down) return;
        e.Handled = true;
        f11Down = false;
    }

    // F11 while the view is hidden (a screen that isn't answering) comes to the window itself.
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData != Keys.F11) return base.ProcessCmdKey(ref msg, keyData);
        if (((long)msg.LParam & 0x40000000) == 0) ToggleFullScreen(); // not an autorepeat
        return true;
    }

    // ------------------------------------------------------------------ window menu

    [DllImport("user32.dll")] static extern IntPtr GetSystemMenu(IntPtr hWnd, bool revert);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(IntPtr menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] static extern bool DeleteMenu(IntPtr menu, uint position, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int command);

    // Rebuilt each time it opens, so it shows machines added in any window.
    void BuildMenu()
    {
        const uint MF_STRING = 0, MF_GRAYED = 0x1, MF_CHECKED = 0x8, MF_SEPARATOR = 0x800, MF_BYPOSITION = 0x400;
        var menu = GetSystemMenu(Handle, false);
        if (menuBase < 0) menuBase = GetMenuItemCount(menu);
        while (GetMenuItemCount(menu) > menuBase) DeleteMenu(menu, (uint)menuBase, MF_BYPOSITION);
        menuMachines = Settings.Load().Machines.Take(MaxMachines).ToList();
        var saved = menuMachines.Any(m => m.Name == machine.Name);
        AppendMenu(menu, MF_SEPARATOR, 0, null);
        for (var i = 0; i < menuMachines.Count; i++)
        {
            var m = menuMachines[i];
            AppendMenu(menu, m.Name == machine.Name ? MF_CHECKED : MF_STRING, (nuint)(CmdMachine + 16 * i), m.Name.Replace("&", "&&"));
        }
        AppendMenu(menu, MF_STRING, CmdAdd, "Add machine...");
        AppendMenu(menu, MF_STRING, CmdSettings, "Settings...");
        AppendMenu(menu, saved ? MF_STRING : MF_GRAYED, CmdRemove, "Remove this machine...");
        AppendMenu(menu, MF_STRING, CmdStartMenu, "Add this machine to the Start menu");
        AppendMenu(menu, MF_SEPARATOR, 0, null);
        AppendMenu(menu, fullScreen ? MF_CHECKED : MF_STRING, CmdFullScreen, "Full screen\tF11");
        AppendMenu(menu, MF_STRING, CmdReload, "Reload");
        AppendMenu(menu, stats ? MF_CHECKED : MF_STRING, CmdStats, "voxl's stats overlay");
    }

    protected override void WndProc(ref Message m)
    {
        const int WM_SYSCOMMAND = 0x112, WM_INITMENU = 0x116, SC_KEYMENU = 0xF100;
        // Every time: opened from the icon, the menu arrives inside a wrapper with another handle,
        // and this window has no other menu.
        if (m.Msg == WM_INITMENU) BuildMenu();
        if (m.Msg == WM_SYSCOMMAND)
        {
            var id = (int)(m.WParam.ToInt64() & 0xFFF0);
            if (id == SC_KEYMENU) return; // a lone Alt belongs to the remote machine, not this window's menu
            if (Command(id) is { } action)
            {
                BeginInvoke(action);
                return;
            }
        }
        base.WndProc(ref m);
    }

    Action? Command(int id)
    {
        if (id >= CmdMachine && id < CmdMachine + 16 * MaxMachines && (id - CmdMachine) / 16 < menuMachines.Count)
        {
            var chosen = menuMachines[(id - CmdMachine) / 16];
            return () => Program.Open(chosen);
        }
        return id switch
        {
            CmdAdd => () =>
            {
                if (Program.AddMachine(this) is { } added) Program.Open(added);
            },
            CmdSettings => OpenSettings,
            CmdRemove => RemoveMachine,
            CmdStartMenu => AddToStartMenu,
            CmdFullScreen => ToggleFullScreen,
            CmdReload => Reconnect,
            CmdStats => () =>
            {
                stats = !stats;
                Connect(row);
            },
            _ => null,
        };
    }

    void RemoveMachine()
    {
        var question = $"Remove \"{machine.Name}\"? Its window closes, and its Start-menu entry and saved passwords go too.";
        if (MessageBox.Show(this, question, "Remove machine", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        if (settings is { IsDisposed: false }) settings.Close(); // first, so an edit it holds can't save the machine again
        var name = machine.Name;
        var kept = new HashSet<string>();
        Settings.Change(s =>
        {
            s.Machines.RemoveAll(m => m.Name == name);
            s.Windows.Remove(name);
            if (s.Last == name) s.Last = null;
            foreach (var m in s.Machines) kept.UnionWith(Targets(m));
        });
        // A password another machine uses stays.
        foreach (var target in Targets(machine).Except(kept)) Credentials.Delete(target);
        StartMenu.Try(this, () => StartMenu.Update(machine, null));
        forget = true;
        Close();
    }

    // The Credential Manager entries a machine's screens would use.
    static IEnumerable<string> Targets(Machine m) =>
        m.Screens.SelectMany(s => new[] { s.Url, s.Sharp }).OfType<string>().Select(u => Credentials.Target(new Uri(u))).Distinct();

    void AddToStartMenu()
    {
        var m = machine;
        Settings.Change(s =>
        {
            if (s.Find(m.Name) is null) s.Machines.Add(m);
        });
        if (StartMenu.Try(this, () => StartMenu.Add(m)))
            MessageBox.Show(this, $"\"{m.Name}\" is in the Start menu, in the voxl viewer folder.", Text);
    }

    // ------------------------------------------------------------------ window

    // Where this machine's window was last time; maximized the first time.
    void PlaceWindow()
    {
        var place = Settings.Load().Windows.GetValueOrDefault(machine.Name);
        var bounds = place is null ? Rectangle.Empty : new Rectangle(place.X, place.Y, place.Width, place.Height);
        if (bounds.Width >= 200 && bounds.Height >= 150 && WinScreen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(bounds)))
        {
            StartPosition = FormStartPosition.Manual;
            Bounds = bounds;
        }
        else
        {
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1280, 800);
        }
        WindowState = place is null || place.Maximized ? FormWindowState.Maximized : FormWindowState.Normal;
    }

    void SavePlace()
    {
        var bounds = fullScreen ? savedBounds : WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
        var maximized = fullScreen ? savedState == FormWindowState.Maximized : WindowState == FormWindowState.Maximized;
        var name = machine.Name;
        Settings.Change(s => s.Windows[name] = new Place(bounds.X, bounds.Y, bounds.Width, bounds.Height, maximized));
    }

    public void BringUp()
    {
        if (WindowState == FormWindowState.Minimized) ShowWindow(Handle, 9); // SW_RESTORE, maximized again if it was
        Activate();
    }

    // Borderless over the whole monitor. Not the page's own fullscreen, which WebView2 leaves on a
    // single Esc that the remote machine should get.
    public void ToggleFullScreen()
    {
        if (!fullScreen)
        {
            savedState = WindowState;
            savedBounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            WindowState = FormWindowState.Normal;
            FormBorderStyle = FormBorderStyle.None;
            Bounds = WinScreen.FromControl(this).Bounds;
            // Full screen hides the title bar and its menu, so say how to leave. Not over a screen's
            // own note while it connects or isn't answering.
            if (!loading && !down)
                chip.Say($"Full screen. To leave, rest the pointer at the {Prefs.Edge.ToString().ToLowerInvariant()} edge and click the tab, or press F11.", 4000);
        }
        else
        {
            FormBorderStyle = FormBorderStyle.Sizable;
            Bounds = savedBounds;
            WindowState = savedState;
        }
        fullScreen = !fullScreen;
        tabs.Sync();
        chip.Place();
    }

    // After a click on the tab row: keys go on to the remote.
    public void FocusPicture()
    {
        if (web.Visible && InFront) web.Focus();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        tabs.Sync();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        menuBase = -1;
        if (winKeys is not null) winKeys.FormHandle = Handle;
        BuildMenu();
    }

    // voxl stops the video while its page is hidden, but WebView2 only hides when told. A page
    // still loading, or a screen that isn't answering, shows black (this window) instead; not
    // before the view's WebView2 is up, which it might not do in a hidden control.
    void ShowView()
    {
        var show = WindowState != FormWindowState.Minimized && (!started || (!loading && !down));
        if (web.Visible == show) return;
        // Hidden, the view could keep the focus (its window is WebView2's) and still type into the
        // page being left: the window itself takes the keys meanwhile, F11 among them.
        if (!show && InFront)
        {
            ActiveControl = null;
            Focus();
        }
        web.Visible = show;
        if (show && InFront) web.Focus();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        ShowView();
        UpdateAudio();
        chip.Place();
        switcher.HideAll();
    }

    protected override void OnMove(EventArgs e)
    {
        base.OnMove(e);
        chip.Place();
        switcher.HideAll();
    }

    protected override void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        UpdateAudio();
        web.Focus();
        switcher.Start();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        UpdateAudio();
        winKeys?.Reset();
        f11Down = false;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!forget) SavePlace();
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        audioTimer.Dispose();
        winKeys?.Dispose();
        switcher.Dispose();
        base.OnFormClosed(e);
    }
}
