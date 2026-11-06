// voxl viewer for Windows: voxl's own page in WebView2, one window per machine, plus what a
// browser tab can't do (ViewerForm.cs).
//
// VoxlViewer.exe                  opens the machine used last, or asks for one on first launch
// VoxlViewer.exe <url> [name]     opens that voxl page (Start-menu entries use this)
//
// One process per user holds every window: a second launch hands its arguments to the first,
// which opens that machine or brings its window to the front.
using System.Runtime.InteropServices;
using Microsoft.VisualBasic.ApplicationServices;

namespace VoxlViewer;

static class Program
{
    static readonly List<ViewerForm> windows = new();

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
            var name = args.Length > 1 && args[1].Trim().Length > 0 ? args[1].Trim() : new Uri(url).Host;
            return settings.Find(url) ?? new Machine(name, url);
        }
        if (settings.Machines.Count == 0) return AddMachine(null);
        return settings.Find(settings.Last) ?? settings.Machines[0];
    }

    // Asks for a new machine and saves it. null when cancelled.
    public static Machine? AddMachine(IWin32Window? owner)
    {
        using var dialog = new MachineDialog("Add machine", null);
        if (dialog.ShowDialog(owner) != DialogResult.OK) return null;
        var added = dialog.Result;
        Settings.Change(s => s.Machines.Add(added));
        return added;
    }

    // Opens a window for the machine, or brings its window to the front. The app quits when the
    // last window closes.
    public static ViewerForm Open(Machine machine)
    {
        if (windows.Find(w => w.Machine.Url == machine.Url) is { } open)
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

    // For changes WebView2 only takes at start: a new window takes the old one's place.
    public static void Reopen(ViewerForm old, Machine machine)
    {
        old.Retarget(machine);
        windows.Remove(old);
        Open(machine);
        old.Close();
    }
}
