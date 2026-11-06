// One machine's window. It hosts voxl's page in WebView2 and adds only what a browser tab can't do:
// - WebView2's browser shortcuts are off, so Ctrl+W/T/R/F5 reach the remote machine;
// - for a Mac, the Win key reaches the page as the Mac's Control key (WinKeys.cs);
// - F11 is borderless full screen; the window menu (click the icon or right-click the title bar)
//   has the machines, Reload and voxl's stats overlay;
// - voxl's password can be kept in Windows Credential Manager;
// - the page loads again while the machine is unreachable or answers 5xx.
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace VoxlViewer;

sealed class ViewerForm : Form
{
    // Window-menu commands (Windows keeps the low four bits of WM_SYSCOMMAND for itself).
    const int CmdAdd = 0x1100, CmdEdit = 0x1110, CmdRemove = 0x1120, CmdStartMenu = 0x1130;
    const int CmdFullScreen = 0x1200, CmdReload = 0x1210, CmdStats = 0x1220;
    const int CmdMachine = 0x2000, MaxMachines = 200; // CmdMachine + 16 * index

    static readonly Dictionary<bool, Task<CoreWebView2Environment>> environments = new();
    static Icon? appIcon;

    Machine machine;
    readonly WebView2 web = new() { Dock = DockStyle.Fill };
    WinKeys? winKeys;
    bool stats, fullScreen, f11Down, retrying, forget;
    long f11Time;
    int retryId; // bumped by each success and each scheduled retry: only the latest retry runs
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
        stats = new Uri(machine.Url).Query.TrimStart('?').Split('&').Any(IsStats);
        Text = machine.Name;
        Icon = appIcon ??= Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        PlaceWindow();
        Controls.Add(web);
        web.KeyDown += OnWebKeyDown;
        web.KeyUp += OnWebKeyUp;
    }

    public Machine Machine => machine;
    public CoreWebView2? Core => web.CoreWebView2;

    protected override async void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        try
        {
            await web.EnsureCoreWebView2Async(await WebEnvironment(machine.CpuDecode));
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
        var core = web.CoreWebView2;
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
        core.BasicAuthenticationRequested += OnBasicAuth;
        core.NavigationCompleted += OnNavigationCompleted;
        SetMacKeys(machine.IsMac);
        var url = machine.Url;
        Settings.Change(s => s.Last = url);
        core.Navigate(PageUrl());
    }

    // The decode choice belongs to WebView2's browser process, so each has its own data folder.
    static Task<CoreWebView2Environment> WebEnvironment(bool cpuDecode)
    {
        if (!environments.TryGetValue(cpuDecode, out var task))
        {
            var options = new CoreWebView2EnvironmentOptions(cpuDecode ? "--disable-accelerated-video-decode" : null);
            var folder = Path.Combine(Settings.Dir, cpuDecode ? "WebView2-cpu" : "WebView2");
            environments[cpuDecode] = task = CoreWebView2Environment.CreateAsync(null, folder, options);
        }
        return task;
    }

    string PageUrl() => WithStats(machine.Url, stats);

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

    // ------------------------------------------------------------------ loading and passwords

    // The machine is offline, or voxl restarts behind a proxy that answers 502: try again (voxl's
    // page reconnects on its own once it has loaded). Not for a wrong password, a bad certificate
    // or a missing page, which no retry fixes.
    async void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (e.IsSuccess && e.HttpStatusCode < 500)
        {
            retryId++; // a retry still waiting is dropped; a later failure schedules its own
            retrying = false;
            Text = machine.Name;
            answered = false;
            if (pendingLogin is { } login)
            {
                if (login.Keep) Credentials.Write(login.Target, login.User, login.Password);
                else Credentials.Delete(login.Target);
                pendingLogin = null;
            }
            return;
        }
        if (e.HttpStatusCode < 500 && (e.HttpStatusCode >= 400 || e.WebErrorStatus is
                CoreWebView2WebErrorStatus.OperationCanceled
                or CoreWebView2WebErrorStatus.ValidAuthenticationCredentialsRequired
                or CoreWebView2WebErrorStatus.ValidProxyAuthenticationRequired
                or CoreWebView2WebErrorStatus.CertificateCommonNameIsIncorrect
                or CoreWebView2WebErrorStatus.CertificateExpired
                or CoreWebView2WebErrorStatus.CertificateIsInvalid
                or CoreWebView2WebErrorStatus.CertificateRevoked
                or CoreWebView2WebErrorStatus.ClientCertificateContainsErrors))
            return;
        if (retrying) return;
        retrying = true;
        Text = machine.Name + " (waiting for voxl)";
        var id = ++retryId;
        await Task.Delay(5000);
        // A reload in the meantime may have worked: don't cut that session off.
        if (id != retryId) return;
        retrying = false;
        if (!IsDisposed && Core is { } core) core.Navigate(PageUrl());
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

    void SetMacKeys(bool on)
    {
        if (on && winKeys is null)
        {
            winKeys = new WinKeys(this, Handle);
        }
        else if (!on && winKeys is not null)
        {
            winKeys.Reset();
            winKeys.Dispose();
            winKeys = null;
        }
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
        var saved = menuMachines.Any(m => m.Url == machine.Url);
        AppendMenu(menu, MF_SEPARATOR, 0, null);
        for (var i = 0; i < menuMachines.Count; i++)
        {
            var m = menuMachines[i];
            AppendMenu(menu, m.Url == machine.Url ? MF_CHECKED : MF_STRING, (nuint)(CmdMachine + 16 * i), m.Name.Replace("&", "&&"));
        }
        AppendMenu(menu, MF_STRING, CmdAdd, "Add machine...");
        AppendMenu(menu, MF_STRING, CmdEdit, saved ? "Edit this machine..." : "Save this machine...");
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
        if (m.Msg == WM_INITMENU && m.WParam == GetSystemMenu(Handle, false)) BuildMenu();
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
            CmdEdit => EditMachine,
            CmdRemove => RemoveMachine,
            CmdStartMenu => AddToStartMenu,
            CmdFullScreen => ToggleFullScreen,
            CmdReload => () =>
            {
                answered = false;
                Core?.Navigate(PageUrl());
            },
            CmdStats => () =>
            {
                stats = !stats;
                Core?.Navigate(PageUrl());
            },
            _ => null,
        };
    }

    void EditMachine()
    {
        var saved = Settings.Load().Find(machine.Url) is not null;
        using var dialog = new MachineDialog(saved ? "Edit machine" : "Save machine", machine);
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var old = machine;
        var now = dialog.Result;
        Settings.Change(s =>
        {
            var i = s.Machines.FindIndex(m => m.Url == old.Url);
            if (i >= 0) s.Machines[i] = now;
            else s.Machines.Add(now);
            if (now.Url != old.Url && s.Windows.Remove(old.Url, out var place)) s.Windows[now.Url] = place;
        });
        Try(() => StartMenu.Update(old, now));
        if (now.Url != old.Url || now.CpuDecode != old.CpuDecode)
        {
            Program.Reopen(this, now);
            return;
        }
        machine = now;
        Text = now.Name;
        SetMacKeys(now.IsMac);
    }

    void RemoveMachine()
    {
        var question = $"Remove \"{machine.Name}\"? Its window closes, and its Start-menu entry and saved password go too.";
        if (MessageBox.Show(this, question, "Remove machine", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        var url = machine.Url;
        var target = Credentials.Target(new Uri(url));
        var shared = false;
        Settings.Change(s =>
        {
            s.Machines.RemoveAll(m => m.Url == url);
            s.Windows.Remove(url);
            if (s.Last == url) s.Last = null;
            shared = s.Machines.Any(m => Credentials.Target(new Uri(m.Url)) == target);
        });
        if (!shared) Credentials.Delete(target);
        Try(() => StartMenu.Update(machine, null));
        forget = true;
        Close();
    }

    void AddToStartMenu()
    {
        var m = machine;
        Settings.Change(s =>
        {
            if (s.Find(m.Url) is null) s.Machines.Add(m);
        });
        if (Try(() => StartMenu.Add(m)))
            MessageBox.Show(this, $"\"{m.Name}\" is in the Start menu, in the voxl viewer folder.", Text);
    }

    bool Try(Action action)
    {
        try
        {
            action();
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "The Start-menu entry couldn't be changed: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }

    // ------------------------------------------------------------------ window

    // Where this machine's window was last time; maximized the first time.
    void PlaceWindow()
    {
        var place = Settings.Load().Windows.GetValueOrDefault(machine.Url);
        var bounds = place is null ? Rectangle.Empty : new Rectangle(place.X, place.Y, place.Width, place.Height);
        if (bounds.Width >= 200 && bounds.Height >= 150 && Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(bounds)))
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
        var url = machine.Url;
        Settings.Change(s => s.Windows[url] = new Place(bounds.X, bounds.Y, bounds.Width, bounds.Height, maximized));
    }

    // Before Program.Reopen: the new window opens where this one is.
    public void Retarget(Machine now)
    {
        machine = now;
        SavePlace();
    }

    public void BringUp()
    {
        if (WindowState == FormWindowState.Minimized) ShowWindow(Handle, 9); // SW_RESTORE, maximized again if it was
        Activate();
    }

    // Borderless over the whole monitor. Not the page's own fullscreen, which WebView2 leaves on a
    // single Esc that the remote machine should get.
    void ToggleFullScreen()
    {
        if (!fullScreen)
        {
            savedState = WindowState;
            savedBounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            WindowState = FormWindowState.Normal;
            FormBorderStyle = FormBorderStyle.None;
            Bounds = Screen.FromControl(this).Bounds;
        }
        else
        {
            FormBorderStyle = FormBorderStyle.Sizable;
            Bounds = savedBounds;
            WindowState = savedState;
        }
        fullScreen = !fullScreen;
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        menuBase = -1;
        if (winKeys is not null) winKeys.FormHandle = Handle;
        BuildMenu();
    }

    // voxl stops the video while its page is hidden, but WebView2 only hides when told.
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        web.Visible = WindowState != FormWindowState.Minimized;
    }

    protected override void OnActivated(EventArgs e)
    {
        base.OnActivated(e);
        web.Focus();
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
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
        winKeys?.Dispose();
        base.OnFormClosed(e);
    }
}
