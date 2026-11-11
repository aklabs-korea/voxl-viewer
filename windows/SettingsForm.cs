// A machine's settings, from its window (Settings in the window menu or the switcher's panel): its
// name, the Mac and decode options and its screens in order, and the switcher's edge for every
// window. Each change is saved at once. The window reconnects only when the screen on show changed
// its address (or its video decode, which WebView2 only takes when it starts).
using System.Net;
using WinScreen = System.Windows.Forms.Screen;

namespace VoxlViewer;

sealed class SettingsForm : Form
{
    const int MaxScreens = 9; // one for each of F1..F9

    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(3), MaxResponseContentBufferSize = 1 << 20 };

    static readonly (Side Side, string Note)[] Edges =
    {
        (Side.Top, "Shares the edge with the Mac's menu bar."),
        (Side.Left, "Won't stop the pointer if another monitor sits on that side."),
        (Side.Bottom, "Shares the edge with the Dock and, in a window, the Windows taskbar."),
        (Side.Right, "Won't stop the pointer if another monitor sits on that side. voxl's files panel is there too."),
    };

    readonly ViewerForm viewer;
    readonly List<Screen> screens;
    readonly TextBox name = new() { Width = 260 };
    readonly CheckBox isMac = new() { Text = "This is a Mac (the Win key works as the Mac's Control key)", AutoSize = true };
    readonly CheckBox cpu = new() { Text = "Decode video on the CPU (for a GPU that can't decode the remote's screen size; Sharp uses the GPU)", AutoSize = true };
    readonly DataGridView grid = new()
    {
        Size = new Size(760, 190),
        AllowUserToAddRows = false,
        AllowUserToDeleteRows = false,
        AllowUserToResizeRows = false,
        RowHeadersVisible = false,
        MultiSelect = false,
        SelectionMode = DataGridViewSelectionMode.FullRowSelect,
        EditMode = DataGridViewEditMode.EditOnKeystrokeOrF2,
        AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill,
        BackgroundColor = SystemColors.Window,
    };
    readonly TextBox link = new() { Width = 360, PlaceholderText = "Paste a voxl link to add a screen" };
    readonly Button add = new() { Text = "Add screen", AutoSize = true };
    bool filling; // the grid is being refilled: its events aren't edits

    public SettingsForm(ViewerForm viewer)
    {
        this.viewer = viewer;
        var machine = viewer.Machine;
        screens = machine.Screens.ToList();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = machine.Name + " settings";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowIcon = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        var root = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Padding = new Padding(10) };
        Controls.Add(root);
        void Put(Control control, int above = 3)
        {
            control.Margin = new Padding(3, above, 3, 3);
            root.Controls.Add(control);
        }

        name.Text = machine.Name;
        isMac.Checked = machine.IsMac;
        cpu.Checked = machine.CpuDecode;
        var nameRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        nameRow.Controls.Add(new Label { Text = "Name", AutoSize = true, Margin = new Padding(0, 6, 8, 0) });
        nameRow.Controls.Add(name);
        Put(nameRow);
        Put(isMac);
        Put(cpu);

        Put(Heading("Screens"), 14);
        foreach (var (title, weight) in new[] { ("", 14f), ("Name", 20f), ("voxl URL", 33f), ("Sharp URL (optional)", 33f) })
        {
            grid.Columns.Add(new DataGridViewTextBoxColumn
            {
                HeaderText = title,
                FillWeight = weight,
                ReadOnly = title.Length == 0,
                SortMode = DataGridViewColumnSortMode.NotSortable,
            });
        }
        Fill();
        Put(grid);
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        buttons.Controls.Add(link);
        buttons.Controls.Add(add);
        buttons.Controls.Add(NewButton("Remove", RemoveScreen));
        buttons.Controls.Add(NewButton("Move up", () => MoveScreen(-1)));
        buttons.Controls.Add(NewButton("Move down", () => MoveScreen(1)));
        Put(buttons);
        Put(new Label { Text = "1 opens with the window. F1, F2 … go to 1, 2 …", AutoSize = true });

        Put(Heading("Tab at the window's edge, for every window"), 14);
        var sides = new TableLayoutPanel { AutoSize = true, ColumnCount = 2 };
        foreach (var (side, note) in Edges)
        {
            var radio = new RadioButton { Text = side.ToString(), AutoSize = true, Checked = Prefs.Edge == side };
            radio.CheckedChanged += (_, _) =>
            {
                if (radio.Checked) Prefs.SetEdge(side);
            };
            sides.Controls.Add(radio);
            sides.Controls.Add(new Label { Text = note, AutoSize = true, ForeColor = SystemColors.GrayText, Anchor = AnchorStyles.Left });
        }
        Put(sides);

        var close = NewButton("Close", Close);
        CancelButton = close;
        var bottom = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        bottom.Controls.Add(close);
        Put(bottom, 12);

        name.Leave += (_, _) => CommitName();
        name.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            e.SuppressKeyPress = true;
            CommitName();
        };
        isMac.CheckedChanged += (_, _) => Save(viewer.Row);
        cpu.CheckedChanged += (_, _) => Save(viewer.Row);
        grid.CellEndEdit += (_, e) => CommitCell(e.RowIndex, e.ColumnIndex);
        grid.CellDoubleClick += (_, e) =>
        {
            if (e.RowIndex >= 0 && e.ColumnIndex > 0) grid.BeginEdit(true);
        };
        link.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            e.SuppressKeyPress = true;
            AddScreen();
        };
        add.Click += (_, _) => AddScreen();
    }

    static Label Heading(string text) =>
        new() { Text = text, AutoSize = true, Font = new Font(Control.DefaultFont, FontStyle.Bold) };

    static Button NewButton(string text, Action click)
    {
        var button = new Button { Text = text, AutoSize = true };
        button.Click += (_, _) => click();
        return button;
    }

    static string RowLabel(int i) => i switch { 0 => "1 Default", 1 => "2 Secondary", _ => (i + 1).ToString() };

    static string Cell(Screen s, int column) => column switch { 1 => s.Name, 2 => s.Url, 3 => s.Sharp ?? "", _ => "" };

    void Fill()
    {
        filling = true;
        grid.Rows.Clear();
        for (var i = 0; i < screens.Count; i++) grid.Rows.Add(RowLabel(i), Cell(screens[i], 1), Cell(screens[i], 2), Cell(screens[i], 3));
        filling = false;
    }

    int SelectedRow => grid.CurrentCell?.RowIndex ?? -1;

    void SelectRow(int i)
    {
        if (i >= 0 && i < grid.Rows.Count) grid.CurrentCell = grid[1, i];
    }

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        // A machine opened by its URL alone isn't saved yet: opening its settings saves it.
        if (Settings.Load().Find(viewer.Machine.Name) is null) Save(viewer.Row);
        // Over the middle of its machine's window, on screen.
        var area = WinScreen.FromControl(viewer).WorkingArea;
        var x = viewer.Left + (viewer.Width - Width) / 2;
        var y = viewer.Top + (viewer.Height - Height) / 2;
        Location = new Point(Math.Clamp(x, area.Left, Math.Max(area.Left, area.Right - Width)),
            Math.Clamp(y, area.Top, Math.Max(area.Top, area.Bottom - Height)));
    }

    // An edit still open counts once the window is left or closed.
    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        CommitPending();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        CommitPending();
        base.OnFormClosing(e);
    }

    void CommitPending()
    {
        if (grid.IsCurrentCellInEditMode) grid.EndEdit();
        CommitName();
    }

    void Complain(string message) =>
        MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);

    // The machine as this window shows it, saved in place of its old self (or added, if it wasn't
    // saved yet) and handed to its window. `row`: where the screen on show is now.
    void Save(int row, string? rename = null)
    {
        var old = viewer.Machine;
        var now = new Machine(rename ?? old.Name, screens.ToList(), isMac.Checked, cpu.Checked);
        Settings.Change(s =>
        {
            var i = s.Machines.FindIndex(m => m.Name == old.Name);
            if (i >= 0) s.Machines[i] = now;
            else s.Machines.Add(now);
            if (now.Name == old.Name) return;
            if (s.Windows.Remove(old.Name, out var place)) s.Windows[now.Name] = place;
            if (s.Last == old.Name) s.Last = now.Name;
        });
        // Its Start-menu entry, if it has one, follows its name and first screen.
        if (now.Name != old.Name || now.Screens[0].Url != old.Screens[0].Url) StartMenu.Try(this, () => StartMenu.Update(old, now));
        viewer.Apply(now, row);
        Text = now.Name + " settings";
    }

    void CommitName()
    {
        var old = viewer.Machine.Name;
        // Quotes would break the Start-menu shortcut's arguments.
        var text = name.Text.Trim().Replace('"', '\'');
        if (text.Length == 0 || text == old)
        {
            name.Text = old;
            return;
        }
        if (Program.TakenName(text, old) is { } same)
        {
            name.Text = old;
            Complain($"\"{same}\" is already the name of another machine. Pick another name.");
            return;
        }
        Save(viewer.Row, text);
    }

    // Who already has this address: another screen here, or another machine.
    string? Taken(string url, int except)
    {
        var i = screens.FindIndex(s => s.Url == url);
        if (i >= 0 && i != except) return $"screen {i + 1} here";
        var other = Settings.Load().Machines.Find(m => m.Name != viewer.Machine.Name && m.Owns(url));
        return other is null ? null : $"a screen of \"{other.Name}\"";
    }

    // An edited cell: a screen's name, URL or Sharp URL. A bad address goes back to what it was.
    void CommitCell(int r, int c)
    {
        if (filling || r < 0 || r >= screens.Count || c < 1) return;
        var s = screens[r];
        var text = (grid[c, r].Value as string ?? "").Trim();
        var now = s;
        string? problem = null;
        if (c == 1)
        {
            now = s with { Name = Settings.NameOr(text, s.Url) };
        }
        else if (c == 2)
        {
            if (Settings.NormalizeUrl(text) is not { } url) problem = "Enter the address of the screen's voxl page, like https://my-mac.example.ts.net:6901/";
            else if (url != s.Url && Taken(url, r) is { } owner) problem = $"That address is already {owner}.";
            else now = s with { Url = url };
        }
        else if (text.Length == 0)
        {
            now = s with { Sharp = null };
        }
        else if (Settings.NormalizeUrl(text) is { } sharp)
        {
            now = s with { Sharp = sharp };
        }
        else
        {
            problem = "Enter the address of the screen's Sharp voxl page, or leave it empty.";
        }
        grid[c, r].Value = Cell(now, c);
        if (problem is not null)
        {
            BeginInvoke(() => Complain(problem));
            return;
        }
        if (now == s) return;
        screens[r] = now;
        Save(viewer.Row);
    }

    // Pasted link -> a new last row, named after voxl's page title (its --title) when the page
    // answers, otherwise its host and port.
    async void AddScreen()
    {
        if (Settings.NormalizeUrl(link.Text) is not { } url)
        {
            Complain("Paste the address of a voxl page, like https://my-mac.example.ts.net:6902/");
            return;
        }
        if (screens.Count >= MaxScreens)
        {
            Complain($"A machine has up to {MaxScreens} screens, one for each of F1 to F{MaxScreens}.");
            return;
        }
        if (Taken(url, -1) is { } owner)
        {
            Complain($"That address is already {owner}.");
            return;
        }
        add.Enabled = false;
        var title = await PageTitle(url);
        if (IsDisposed) return;
        add.Enabled = true;
        if (screens.Count >= MaxScreens || Taken(url, -1) is not null) return; // changed while voxl was asked
        screens.Add(new Screen(title ?? new Uri(url).Authority, url));
        link.Text = "";
        Save(viewer.Row);
        Fill();
        SelectRow(screens.Count - 1);
    }

    // The page's <title>, or null when it doesn't answer in time or has voxl's default one, the
    // same for every screen.
    static async Task<string?> PageTitle(string url)
    {
        try
        {
            var page = await http.GetStringAsync(url);
            var start = page.IndexOf("<title>", StringComparison.OrdinalIgnoreCase);
            var end = start < 0 ? -1 : page.IndexOf("</title>", start, StringComparison.OrdinalIgnoreCase);
            if (end < 0) return null;
            var title = WebUtility.HtmlDecode(page[(start + "<title>".Length)..end]).Trim();
            return title.Length == 0 || title == "Voxl Computer Stream" ? null : title;
        }
        catch (Exception)
        {
            return null;
        }
    }

    void RemoveScreen()
    {
        var r = SelectedRow;
        if (r < 0) return;
        if (screens.Count == 1)
        {
            Complain("A machine needs a screen. To remove the whole machine, use Remove this machine in its window menu.");
            return;
        }
        screens.RemoveAt(r);
        var shown = viewer.Row;
        // The screen on show gone, the window goes to the first.
        Save(shown == r ? 0 : shown > r ? shown - 1 : shown);
        Fill();
        SelectRow(Math.Min(r, screens.Count - 1));
    }

    void MoveScreen(int by)
    {
        var r = SelectedRow;
        var to = r + by;
        if (r < 0 || to < 0 || to >= screens.Count) return;
        (screens[r], screens[to]) = (screens[to], screens[r]);
        var shown = viewer.Row;
        Save(shown == r ? to : shown == to ? r : shown);
        Fill();
        SelectRow(to);
    }
}
