// What floats over the picture: the chip in the middle that names a screen while it connects, and
// the switcher, a tab at the window's edge that opens a panel of the machine's screens (in full
// screen, or where the tab row isn't shown). Each is a
// small window of its own that never activates, so the picture never moves, rescales or resizes,
// and typing keeps going to the remote. The mouse over WebView2 never reaches WinForms, so a
// timer watches the pointer while the viewer is in front.
using System.Runtime.InteropServices;

namespace VoxlViewer;

// A small window over the viewer that never takes the focus: it doesn't activate when shown or
// clicked, and isn't in the taskbar or Alt+Tab. Sizes follow the viewer's monitor.
class Overlay : Form
{
    protected static readonly Color Back = Color.FromArgb(32, 32, 32), Lit = Color.FromArgb(62, 62, 62),
        Ink = Color.FromArgb(236, 236, 236), Faint = Color.FromArgb(150, 150, 150),
        Rule = Color.FromArgb(70, 70, 70), Accent = Color.FromArgb(17, 138, 243);
    protected const TextFormatFlags OneLine = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;

    static readonly Dictionary<int, Font> fonts = new();

    protected readonly ViewerForm viewer;

    protected Overlay(ViewerForm viewer)
    {
        this.viewer = viewer;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Back;
        DoubleBuffered = true;
        SetStyle(ControlStyles.Selectable, false);
        Owner = viewer;
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x8000000;
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var round = 3; // DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUNDSMALL, on Windows 11
        DwmSetWindowAttribute(Handle, 33, ref round, sizeof(int));
    }

    protected override void WndProc(ref Message m)
    {
        const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3;
        if (m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = MA_NOACTIVATE;
            return;
        }
        base.WndProc(ref m);
    }

    // Sizes are set on each show from the viewer's monitor, not scaled by Windows on the way.
    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        e.Cancel = true;
        base.OnDpiChanged(e);
    }

    // Segoe UI of a size at 100%, on the viewer's monitor.
    protected Font FontOf(int size)
    {
        var px = viewer.Px(size);
        if (!fonts.TryGetValue(px, out var font)) fonts[px] = font = new Font("Segoe UI", px, GraphicsUnit.Pixel);
        return font;
    }
}

// The middle of the picture: a screen's name while it connects, and what's wrong when it can't.
// Clicks go through it to the remote.
sealed class Chip : Overlay
{
    const int Opaque = 235;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 30 };
    string text = "";
    long fadeAt = long.MaxValue;
    int alpha = Opaque;

    public Chip(ViewerForm viewer) : base(viewer) => timer.Tick += (_, _) => Step();

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20;
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT;
            return cp;
        }
    }

    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr hwnd, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint relation);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    // A layered window shows nothing until it has an alpha.
    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        SetAlpha(alpha);
    }

    void SetAlpha(int a)
    {
        alpha = Math.Clamp(a, 0, 255);
        if (IsHandleCreated) SetLayeredWindowAttributes(Handle, 0, (byte)alpha, 2); // LWA_ALPHA
    }

    // Shows `say`, which fades after `ms`, or with 0 stays until the next Say or FadeBy.
    public void Say(string say, int ms)
    {
        text = say;
        fadeAt = ms > 0 ? Environment.TickCount64 + ms : long.MaxValue;
        SetAlpha(Opaque);
        Bounds = Where();
        Invalidate();
        if (!Visible)
        {
            Show();
            // Right above the viewer: the chip of a window in the back stays behind what's in front of it.
            const uint GW_HWNDPREV = 3, SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;
            var above = GetWindow(viewer.Handle, GW_HWNDPREV);
            if (above != Handle) SetWindowPos(Handle, above, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE);
        }
        timer.Enabled = ms > 0;
    }

    // Fades within `ms`, or at once with 0 (the picture is on).
    public void FadeBy(int ms)
    {
        if (!Visible) return;
        fadeAt = Math.Min(fadeAt, Environment.TickCount64 + ms);
        timer.Start();
    }

    // The viewer moved or changed size.
    public void Place()
    {
        if (Visible) Bounds = Where();
    }

    Padding Pad => new(viewer.Px(16), viewer.Px(10), viewer.Px(16), viewer.Px(10));

    // Centered on the picture, wrapped at 70% of its width.
    Rectangle Where()
    {
        var area = viewer.PictureArea;
        var pad = Pad;
        var most = Math.Max(viewer.Px(160), area.Width * 7 / 10) - pad.Horizontal;
        var size = TextRenderer.MeasureText(text, FontOf(15), new Size(most, int.MaxValue), TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak);
        size += pad.Size;
        return new Rectangle(area.Left + (area.Width - size.Width) / 2, area.Top + (area.Height - size.Height) / 2, size.Width, size.Height);
    }

    void Step()
    {
        if (Environment.TickCount64 < fadeAt) return;
        SetAlpha(alpha - 30);
        if (alpha > 0) return;
        timer.Stop();
        Hide();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var pad = Pad;
        var box = new Rectangle(pad.Left, pad.Top, Width - pad.Horizontal, Height - pad.Vertical);
        TextRenderer.DrawText(e.Graphics, text, FontOf(15), box, Ink,
            TextFormatFlags.NoPrefix | TextFormatFlags.WordBreak | TextFormatFlags.HorizontalCenter);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) timer.Dispose();
        base.Dispose(disposing);
    }
}

// The tab and the panel slide in from the edge, as if from behind it: the window shows the part
// that is in.
abstract class Slide : Overlay
{
    const int Ms = 120;
    Rectangle full;  // the window when all the way in
    Side side;
    double from, to, laid = -1;
    long since;
    Point offset;    // the content's top left in the window, while partly in

    protected Slide(ViewerForm viewer) : base(viewer)
    {
    }

    public Rectangle Full => full;

    // In, or on its way in.
    public bool Open => Visible && to == 1;

    public void SlideIn(Rectangle at, Side edge)
    {
        full = at;
        side = edge;
        Go(1);
        Lay(Progress(Environment.TickCount64));
        if (!Visible) Show();
    }

    public void SlideOut()
    {
        if (Open) Go(0);
    }

    public void HideNow()
    {
        from = to = 0;
        Hide();
    }

    // On each tick of the switcher's timer.
    public void Step(long now)
    {
        if (!Visible) return;
        var f = Progress(now);
        if (to == 0 && f <= 0) Hide();
        else if (f != laid) Lay(f);
    }

    void Go(double target)
    {
        var now = Environment.TickCount64;
        from = Visible ? Progress(now) : 0;
        to = target;
        since = now;
    }

    double Progress(long now) => from + (to - from) * Math.Clamp((now - since) / (double)Ms, 0, 1);

    // The part that is in, `f` of it, against the edge.
    void Lay(double f)
    {
        laid = f;
        var across = side is Side.Top or Side.Bottom ? full.Height : full.Width;
        var n = Math.Clamp((int)Math.Ceiling(across * f), 1, Math.Max(1, across));
        Bounds = side switch
        {
            Side.Top => new Rectangle(full.X, full.Y, full.Width, n),
            Side.Bottom => new Rectangle(full.X, full.Bottom - n, full.Width, n),
            Side.Left => new Rectangle(full.X, full.Y, n, full.Height),
            _ => new Rectangle(full.Right - n, full.Y, n, full.Height),
        };
        offset = side switch
        {
            Side.Top => new Point(0, n - full.Height),
            Side.Left => new Point(n - full.Width, 0),
            _ => Point.Empty,
        };
        Invalidate();
    }

    // A point in the window, in the content's own coordinates.
    protected Point Inside(Point client) => new(client.X - offset.X, client.Y - offset.Y);

    protected override void OnPaint(PaintEventArgs e) => Draw(e.Graphics, offset);

    // Draws the content with its top left at `at`.
    protected abstract void Draw(Graphics g, Point at);
}

// The tab: "2 · top", where the pointer rests at the edge. A click opens the panel.
sealed class TabPane : Slide
{
    readonly Action open;
    string caption = "";

    public TabPane(ViewerForm viewer, Action open) : base(viewer) => this.open = open;

    // Its size with this caption.
    public Size Fit(string say)
    {
        caption = say;
        var size = TextRenderer.MeasureText(caption, FontOf(13), Size.Empty, OneLine);
        return new Size(size.Width + viewer.Px(20), size.Height + viewer.Px(10));
    }

    protected override void Draw(Graphics g, Point at) =>
        TextRenderer.DrawText(g, caption, FontOf(13), new Rectangle(at, Full.Size), Ink, OneLine | TextFormatFlags.HorizontalCenter);

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button == MouseButtons.Left && ClientRectangle.Contains(e.Location)) open();
    }
}

// The panel: the machine's screens with their shortcuts, the one on show ticked; Full | Sharp when
// every screen has a Sharp stream; Full screen; Settings…
sealed class PanelPane : Slide
{
    // A line: a screen or a command, or the Full | Sharp choice. Box is in content coordinates.
    sealed record Line(Rectangle Box, bool Ticked, string Number, string Name, string Hint, Action? Act, bool Choice = false);

    readonly Action<Action> choose; // closes the panel, then acts
    readonly List<Line> lines = new();
    int hover = -1, hoverHalf, rule;

    public PanelPane(ViewerForm viewer, Action<Action> choose) : base(viewer) => this.choose = choose;

    int Pad => viewer.Px(6);
    int TickWidth => viewer.Px(22);
    int NumberWidth => viewer.Px(18);

    // Lays the panel out for the window as it is now, and returns its size.
    public Size Build()
    {
        var m = viewer.Machine;
        var font = FontOf(13);
        int Width(string s) => TextRenderer.MeasureText(s, font, Size.Empty, OneLine).Width;
        var items = new List<(bool Ticked, string Number, string Name, string Hint, Action? Act, bool Choice)>();
        for (var i = 0; i < m.Screens.Count; i++)
        {
            var n = i;
            // The one on show connects again, for a stuck picture. Decided on the click: a key may
            // have switched screens while the panel was open.
            items.Add((i == viewer.Row, (i + 1).ToString(), m.Screens[i].Name, ViewerForm.Shortcut(i), () =>
            {
                if (viewer.Row == n) viewer.Reconnect();
                else viewer.SwitchTo(n);
            }, false));
        }
        var commands = items.Count;
        if (m.HasSharp) items.Add((false, "", "Full | Sharp", "", null, true));
        items.Add((false, "", viewer.FullScreen ? "Leave full screen" : "Full screen", "F11", viewer.ToggleFullScreen, false));
        items.Add((false, "", "Settings…", "", viewer.OpenSettings, false));

        int pad = Pad, height = viewer.Px(26), gap = viewer.Px(24);
        var width = Math.Max(viewer.Px(220),
            pad * 3 + TickWidth + NumberWidth + items.Max(x => Width(x.Name)) + gap + items.Max(x => Width(x.Hint)));
        lines.Clear();
        hover = -1;
        var y = pad;
        for (var i = 0; i < items.Count; i++)
        {
            if (i == commands)
            {
                rule = y + viewer.Px(4);
                y += viewer.Px(9);
            }
            var x = items[i];
            lines.Add(new Line(new Rectangle(pad, y, width - 2 * pad, height), x.Ticked, x.Number, x.Name, x.Hint, x.Act, x.Choice));
            y += height;
        }
        return new Size(width, y + pad);
    }

    protected override void Draw(Graphics g, Point at)
    {
        var font = FontOf(13);
        using (var pen = new Pen(Rule)) g.DrawLine(pen, at.X + Pad, at.Y + rule, at.X + Full.Width - Pad, at.Y + rule);
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            var box = line.Box;
            box.Offset(at);
            if (line.Choice)
            {
                // Two halves, the one in use filled.
                var sharp = Prefs.Sharp;
                var left = new Rectangle(box.X + TickWidth, box.Y + viewer.Px(2), (box.Width - TickWidth) / 2, box.Height - viewer.Px(4));
                var right = new Rectangle(left.Right, left.Y, box.Right - left.Right, left.Height);
                Fill(g, sharp ? right : left, Rule);
                if (i == hover) Fill(g, hoverHalf == 0 ? left : right, Lit);
                TextRenderer.DrawText(g, "Full", font, left, sharp ? Faint : Ink, OneLine | TextFormatFlags.HorizontalCenter);
                TextRenderer.DrawText(g, "Sharp", font, right, sharp ? Ink : Faint, OneLine | TextFormatFlags.HorizontalCenter);
                continue;
            }
            if (i == hover) Fill(g, box, Lit);
            var tick = new Rectangle(box.X, box.Y, TickWidth, box.Height);
            var number = new Rectangle(tick.Right, box.Y, NumberWidth, box.Height);
            var name = new Rectangle(number.Right, box.Y, box.Right - number.Right, box.Height);
            if (line.Ticked) TextRenderer.DrawText(g, "✓", font, tick, Accent, OneLine | TextFormatFlags.HorizontalCenter);
            TextRenderer.DrawText(g, line.Number, font, number, Faint, OneLine);
            TextRenderer.DrawText(g, line.Name, font, name, Ink, OneLine);
            TextRenderer.DrawText(g, line.Hint, font, new Rectangle(name.X, name.Y, name.Width - Pad, name.Height), Faint,
                OneLine | TextFormatFlags.Right);
        }
    }

    static void Fill(Graphics g, Rectangle box, Color color)
    {
        using var brush = new SolidBrush(color);
        g.FillRectangle(brush, box);
    }

    // The line under a point, and for Full | Sharp which half (0 Full, 1 Sharp).
    (int Line, int Half) Hit(Point client)
    {
        var p = Inside(client);
        var i = lines.FindIndex(l => l.Box.Contains(p));
        if (i < 0) return (-1, 0);
        var box = lines[i].Box;
        return (i, p.X < box.X + TickWidth + (box.Width - TickWidth) / 2 ? 0 : 1);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var (line, half) = Hit(e.Location);
        if (line == hover && half == hoverHalf) return;
        hover = line;
        hoverHalf = half;
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hover < 0) return;
        hover = -1;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        var (i, half) = Hit(e.Location);
        if (i < 0) return;
        var line = lines[i];
        if (!line.Choice)
        {
            if (line.Act is { } act) choose(act);
        }
        else if ((half == 1) != Prefs.Sharp)
        {
            var sharp = half == 1;
            choose(() => ViewerForm.SetSharp(sharp));
        }
    }
}

// The tab and panel at the edge every window shares (Prefs.Edge). Nothing shows until the pointer
// rests 0.4 s at the middle third of that edge, 3 px deep, with no button held: corners and the
// outer thirds stay with the remote. Not after a click at the edge, and not again after the tab
// was left alone 3 s, until the pointer has left the edge.
sealed class Switcher : IDisposable
{
    readonly ViewerForm viewer;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 25 };
    TabPane? tab;
    PanelPane? panel;
    long resting, tabShown, away; // when the pointer came to rest at the edge, the tab appeared, the pointer left the panel
    Point restAt;                 // where it came to rest
    bool blocked, wasHeld;

    public Switcher(ViewerForm viewer)
    {
        this.viewer = viewer;
        timer.Tick += (_, _) => Tick();
    }

    // The viewer came to the front: watch the pointer from now on. Not stopped when it goes to the
    // back: after an unlock, Ctrl+Alt+Del or a UAC prompt, Windows puts it in front again without
    // activating it.
    public void Start() => timer.Start();

    // The window moved, changed size or went to the back: both go at once.
    public void HideAll()
    {
        tab?.HideNow();
        panel?.HideNow();
        resting = away = 0;
    }

    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);

    static bool ButtonHeld() =>
        GetAsyncKeyState(0x01) < 0 || GetAsyncKeyState(0x02) < 0 || GetAsyncKeyState(0x04) < 0
        || GetAsyncKeyState(0x05) < 0 || GetAsyncKeyState(0x06) < 0;

    void Tick()
    {
        // In a window with the tab row, the screens are a click away already.
        if (!viewer.InFront || viewer.TabsShown)
        {
            HideAll();
            blocked = wasHeld = false;
            return;
        }
        var now = Environment.TickCount64;
        tab?.Step(now);
        panel?.Step(now);
        var p = Cursor.Position;
        var held = ButtonHeld();
        var pressed = held && !wasHeld;
        wasHeld = held;

        if (panel is { Open: true })
        {
            // It goes on a click elsewhere, which still reaches the remote, or once the pointer has
            // been away 0.6 s.
            if (panel.Bounds.Contains(p)) away = 0;
            else if (pressed) ClosePanel();
            else if (away == 0) away = now;
            else if (now - away >= 600) ClosePanel();
            return;
        }
        var area = viewer.PictureArea;
        var onTab = tab is { Open: true } && tab.Bounds.Contains(p);
        if (!onTab && !Zone(area).Contains(p))
        {
            blocked = false;
            resting = 0;
            tab?.SlideOut();
            return;
        }
        if (tab is { Open: true })
        {
            // A click beside it belongs to the remote; left alone 3 s, it goes.
            if ((held && !onTab) || now - tabShown >= 3000)
            {
                blocked = true;
                tab.SlideOut();
            }
            return;
        }
        if (held)
        {
            // A click or a drag at the edge belongs to the remote.
            blocked = true;
            resting = 0;
            return;
        }
        if (blocked) return;
        // At rest means stopped: a pointer sliding along the edge (to the Mac's menus or its clock)
        // starts again wherever it stops.
        var still = viewer.Px(2);
        if (resting == 0 || Math.Abs(p.X - restAt.X) > still || Math.Abs(p.Y - restAt.Y) > still)
        {
            resting = now;
            restAt = p;
        }
        else if (now - resting >= 400) ShowTab(p, area, now);
    }

    // The middle third of the edge, 3 px deep.
    Rectangle Zone(Rectangle a)
    {
        var d = Math.Max(1, viewer.Px(3));
        return Prefs.Edge switch
        {
            Side.Top => new Rectangle(a.Left + a.Width / 3, a.Top, a.Width / 3, d),
            Side.Bottom => new Rectangle(a.Left + a.Width / 3, a.Bottom - d, a.Width / 3, d),
            Side.Left => new Rectangle(a.Left, a.Top + a.Height / 3, d, a.Height / 3),
            _ => new Rectangle(a.Right - d, a.Top + a.Height / 3, d, a.Height / 3),
        };
    }

    // Something of this size against the edge, centered on `p` along it, inside the picture.
    static Rectangle At(Size s, Point p, Rectangle a)
    {
        var x = Math.Clamp(p.X - s.Width / 2, a.Left, Math.Max(a.Left, a.Right - s.Width));
        var y = Math.Clamp(p.Y - s.Height / 2, a.Top, Math.Max(a.Top, a.Bottom - s.Height));
        return Prefs.Edge switch
        {
            Side.Top => new Rectangle(x, a.Top, s.Width, s.Height),
            Side.Bottom => new Rectangle(x, a.Bottom - s.Height, s.Width, s.Height),
            Side.Left => new Rectangle(a.Left, y, s.Width, s.Height),
            _ => new Rectangle(a.Right - s.Width, y, s.Width, s.Height),
        };
    }

    void ShowTab(Point p, Rectangle area, long now)
    {
        tab ??= new TabPane(viewer, OpenPanel);
        tab.SlideIn(At(tab.Fit(viewer.ScreenLabel(viewer.Row)), p, area), Prefs.Edge);
        tabShown = now;
    }

    // The panel opens inward from the tab, in its place.
    void OpenPanel()
    {
        if (tab is null) return;
        var from = tab.Full;
        tab.HideNow();
        panel ??= new PanelPane(viewer, act =>
        {
            ClosePanel();
            viewer.BeginInvoke(act);
        });
        var center = new Point(from.X + from.Width / 2, from.Y + from.Height / 2);
        panel.SlideIn(At(panel.Build(), center, viewer.PictureArea), Prefs.Edge);
        away = 0;
    }

    // No tab right after: not until the pointer has left the edge.
    void ClosePanel()
    {
        panel?.SlideOut();
        blocked = true;
        away = 0;
    }

    public void Dispose() => timer.Dispose();
}
