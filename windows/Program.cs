// voxl viewer for Windows: voxl's own page in WebView2, one window per machine, plus what a
// browser tab can't do (ViewerForm.cs). A machine has one or more screens, each its own voxl page;
// its window shows one at a time and switches between them (Switcher.cs, WinKeys.cs).
//
// VoxlViewer.exe                  opens the machine used last, or asks for one on first launch
// VoxlViewer.exe <url> [name]     opens the machine with a screen at that URL (at its first screen),
//                                 or else that page as a machine of its own (Start-menu entries use this)
//
// One process per user holds every window: a second launch hands its arguments to the first,
// which opens that machine or brings its window to the front.
using System.Runtime.InteropServices;
using Microsoft.VisualBasic.ApplicationServices;

namespace VoxlViewer;

static class Program
{
    static readonly List<ViewerForm> windows = new();

    public static IReadOnlyList<ViewerForm> Windows => windows;

    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int processId);

    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        // A second launch has the right to come to the front (it was just clicked); pass it on to
        // the first process, which shows the window.
        AllowSetForegroundWindow(-1); // ASFW_ANY
        try
        {
            new App(singleInstance: true).Run(args);
        }
        catch (CantStartSingleInstanceException)
        {
            // .NET's instance pipe is one per machine, so while another Windows account runs the
            // viewer this one can't join it: run on its own instead.
            new App(singleInstance: false).Run(args);
        }
    }

    sealed class App : WindowsFormsApplicationBase
    {
        Machine? first;

        public App(bool singleInstance)
        {
            IsSingleInstance = singleInstance;
            ShutdownStyle = ShutdownMode.AfterAllFormsClose;
            EnableVisualStyles = true;
            HighDpiMode = HighDpiMode.PerMonitorV2;
        }

        // Nothing to open (the first Add machine was cancelled): quit.
        protected override bool OnStartup(StartupEventArgs e)
        {
            first = FirstMachine(e.CommandLine.ToArray());
            return first is not null;
        }

        protected override void OnCreateMainForm() => MainForm = Open(first!);

        // Not the base: it would bring up whichever window is the main one. Before the first window
        // is up this runs on a pool thread, where no window can live, so a launch that lands while
        // the app is still starting is dropped: the starting instance opens its own window.
        protected override void OnStartupNextInstance(StartupNextInstanceEventArgs e)
        {
            if (MainForm is null || MainForm.InvokeRequired) return;
            if (FirstMachine(e.CommandLine.ToArray()) is { } machine) Open(machine);
        }
    }

    static Machine? FirstMachine(string[] args)
    {
        var settings = Settings.Load();
        if (args.Length > 0 && args[0].Contains("://") && Settings.NormalizeUrl(args[0]) is { } url)
        {
            if (settings.FindByUrl(url) is { } saved) return saved;
            // Opened by this URL before and still open: that window comes to the front.
            if (windows.Find(w => w.Machine.Owns(url)) is { } open) return open.Machine;
            var name = Settings.NameOr(args.Length > 1 ? args[1] : null, url);
            if (TakenName(name) is not null) name = new Uri(url).Authority;
            return Machine.One(name, url);
        }
        if (settings.Machines.Count == 0) return AddMachine(null);
        return settings.Find(settings.Last) ?? settings.Machines[0];
    }

    // The machine already called this, saved or open in a window, other than `self`; null when the
    // name is free. Names must differ: windows are found by name, and each machine's place and
    // Start-menu entry go by it.
    public static string? TakenName(string name, string? self = null) =>
        Settings.Load().Machines.Select(m => m.Name).Concat(windows.Select(w => w.Machine.Name))
            .FirstOrDefault(n => n != self && StartMenu.SameName(n, name));

    // Asks for a new machine and its first screen, and saves it. null when cancelled.
    public static Machine? AddMachine(IWin32Window? owner)
    {
        using var dialog = new AddMachineDialog();
        if (dialog.ShowDialog(owner) != DialogResult.OK) return null;
        var added = dialog.Result;
        Settings.Change(s => s.Machines.Add(added));
        return added;
    }

    // Opens a window for the machine at its first screen, or brings its window to the front as it
    // is. The app quits when the last window closes.
    public static ViewerForm Open(Machine machine)
    {
        if (windows.Find(w => w.Machine.Name == machine.Name) is { } open)
        {
            open.BringUp();
            return open;
        }
        var window = new ViewerForm(machine);
        windows.Add(window);
        window.FormClosed += (_, _) => windows.Remove(window);
        window.Show();
        return window;
    }
}
