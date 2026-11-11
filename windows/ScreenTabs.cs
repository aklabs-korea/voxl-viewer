// The tab row along the top of a viewer window: a tab per screen, the one on show lit, and
// Full | Sharp at the right when the machine has Sharp streams. A click does what F1..F9 and the
// switcher's panel do. Only in a window, on a machine with more than one screen: full screen keeps
// the whole monitor for the picture (the edge tab is there instead). It never takes the keyboard,
// so keys keep going to the remote.
namespace VoxlViewer;

sealed class ScreenTabs : Control
{
    static readonly Color Back = Color.FromArgb(24, 24, 24), Hover = Color.FromArgb(44, 44, 44),
        Lit = Color.FromArgb(58, 58, 58), Ink = Color.FromArgb(236, 236, 236), Faint = Color.FromArgb(150, 150, 150),
        Accent = Color.FromArgb(17, 138, 243);
    const TextFormatFlags OneLine = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter;

    readonly ViewerForm viewer;
    // What a click lands on, laid out at the last paint: a screen's row, or Full (-1) or Sharp (-2).
    readonly List<(Rectangle Box, int What)> hits = new();
    int hover = int.MinValue;
    Font? font;

    public ScreenTabs(ViewerForm viewer)
    {
        this.viewer = viewer;
        Dock = DockStyle.Top;
        BackColor = Back;
        DoubleBuffered = true;
        TabStop = false;
        SetStyle(ControlStyles.Selectable, false);
        Sync();
    }

    // Shown or hidden, at the height for the window's monitor, and drawn again.
    public void Sync()
    {
        var m = viewer.Machine;
        Visible = !viewer.FullScreen && m.Screens.Count > 1;
        Height = viewer.Px(30);
        if (font is null || font.Size != viewer.Px(13))
        {
            font?.Dispose();
            font = new Font("Segoe UI", viewer.Px(13), GraphicsUnit.Pixel);
        }
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var m = viewer.Machine;
        var g = e.Graphics;
        var f = font!;
        int pad = viewer.Px(14), gap = viewer.Px(2), line = Math.Max(2, viewer.Px(2));
        int Width(string s) => TextRenderer.MeasureText(s, f, Size.Empty, OneLine).Width;
        hits.Clear();
        var x = 0;
        for (var i = 0; i < m.Screens.Count; i++)
        {
            var name = viewer.ScreenLabel(i);
            var key = ViewerForm.Shortcut(i);
            var box = new Rectangle(x, 0, Math.Max(viewer.Px(120), Width(name) + Width(key) + pad * 3), Height);
            var on = i == viewer.Row;
            Fill(g, box, on ? Lit : i == hover ? Hover : Back);
            if (on) Fill(g, new Rectangle(box.X, box.Bottom - line, box.Width, line), Accent);
            var inner = Rectangle.Inflate(box, -pad, 0);
            TextRenderer.DrawText(g, name, f, inner, on ? Ink : Faint, OneLine);
            TextRenderer.DrawText(g, key, f, inner, Faint, OneLine | TextFormatFlags.Right);
            hits.Add((box, i));
            x = box.Right + gap;
        }
        if (!m.HasSharp) return;
        // Full | Sharp: two halves at the right, the one in use filled.
        var sharp = Prefs.Sharp;
        var half = Math.Max(Width("Full"), Width("Sharp")) + pad * 2;
        var inset = viewer.Px(4);
        var full = new Rectangle(ClientSize.Width - pad - 2 * half, inset, half, Height - 2 * inset);
        var sharpBox = new Rectangle(full.Right, inset, half, full.Height);
        foreach (var (box, what, chosen, text) in new[] { (full, -1, !sharp, "Full"), (sharpBox, -2, sharp, "Sharp") })
        {
            Fill(g, box, chosen ? Lit : what == hover ? Hover : Back);
            TextRenderer.DrawText(g, text, f, box, chosen ? Ink : Faint, OneLine | TextFormatFlags.HorizontalCenter);
            hits.Add((box, what));
        }
    }

    static void Fill(Graphics g, Rectangle box, Color color)
    {
        using var brush = new SolidBrush(color);
        g.FillRectangle(brush, box);
    }

    int Hit(Point p) => hits.FindIndex(h => h.Box.Contains(p)) is var i and >= 0 ? hits[i].What : int.MinValue;

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var at = Hit(e.Location);
        if (at == hover) return;
        hover = at;
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (hover == int.MinValue) return;
        hover = int.MinValue;
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        var what = Hit(e.Location);
        if (what >= 0) viewer.SwitchTo(what);
        else if (what is -1 or -2) ViewerForm.SetSharp(what == -2);
        viewer.FocusPicture();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) font?.Dispose();
        base.Dispose(disposing);
    }
}
