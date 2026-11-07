// The two small dialogs: a new machine and a voxl password. A machine's own settings, its screens
// among them, are in SettingsForm.cs.
namespace VoxlViewer;

class SmallDialog : Form
{
    readonly TableLayoutPanel grid = new()
    {
        AutoSize = true,
        AutoSizeMode = AutoSizeMode.GrowAndShrink,
        ColumnCount = 2,
        Padding = new Padding(10),
    };

    protected SmallDialog(string title)
    {
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowIcon = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Controls.Add(grid);
    }

    // A labelled row, or with no label a row across both columns.
    protected void Row(string? label, Control control)
    {
        control.Margin = new Padding(3, 4, 3, 4);
        if (label is null)
        {
            grid.Controls.Add(control);
            grid.SetColumnSpan(control, 2);
            return;
        }
        grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left });
        grid.Controls.Add(control);
    }

    // OK closes the dialog only when accept says the fields are fine.
    protected void Buttons(Func<bool> accept)
    {
        var ok = new Button { Text = "OK", AutoSize = true };
        var cancel = new Button { Text = "Cancel", AutoSize = true, DialogResult = DialogResult.Cancel };
        ok.Click += (_, _) =>
        {
            if (accept()) DialogResult = DialogResult.OK;
        };
        AcceptButton = ok;
        CancelButton = cancel;
        var row = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        row.Controls.Add(cancel);
        row.Controls.Add(ok);
        Row(null, row);
    }

    protected void Complain(string message) =>
        MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
}

// A new machine with its first screen. Its other screens are added in its Settings.
sealed class AddMachineDialog : SmallDialog
{
    readonly TextBox name = new() { Width = 340 };
    readonly TextBox url = new() { Width = 340, PlaceholderText = "https://my-mac.example.ts.net:6901/" };
    readonly CheckBox isMac = new() { Text = "This is a Mac (the Win key works as the Mac's Control key)", AutoSize = true };
    readonly CheckBox cpu = new() { Text = "Decode video on the CPU (for a GPU that can't decode the remote's screen size)", AutoSize = true };
    Machine? result;

    public Machine Result => result!;

    public AddMachineDialog() : base("Add machine")
    {
        Row("Name", name);
        Row("voxl URL", url);
        Row(null, isMac);
        Row(null, cpu);
        Row(null, new Label { Text = "More screens of the same machine can be added in its Settings.", AutoSize = true });
        Buttons(Accept);
        ActiveControl = name;
    }

    bool Accept()
    {
        if (Settings.NormalizeUrl(url.Text) is not { } address)
        {
            Complain("Enter the address of the machine's voxl page, like https://my-mac.example.ts.net:6901/");
            return false;
        }
        var saved = Settings.Load();
        if (saved.FindByUrl(address) is { } other)
        {
            Complain($"That address is already a screen of \"{other.Name}\".");
            return false;
        }
        // Quotes would break the Start-menu shortcut's arguments.
        var label = name.Text.Trim().Replace('"', '\'');
        if (label.Length == 0) label = new Uri(address).Host;
        if (Program.TakenName(label) is { } same)
        {
            Complain($"\"{same}\" is already the name of another machine. Pick another name.");
            return false;
        }
        result = Machine.One(label, address, isMac.Checked, cpu.Checked);
        return true;
    }
}

sealed class PasswordDialog : SmallDialog
{
    readonly TextBox user = new() { Width = 260 };
    readonly TextBox password = new() { Width = 260, UseSystemPasswordChar = true };
    readonly CheckBox remember = new() { Text = "Remember it in Windows Credential Manager", AutoSize = true, Checked = true };

    public string User => user.Text;
    public string Password => password.Text;
    public bool Remember => remember.Checked;

    public PasswordDialog(string host, string? userName, bool failed) : base("voxl password")
    {
        user.Text = userName ?? "";
        var note = failed ? $"That didn't work. voxl on {host} asks for its password again." : $"voxl on {host} asks for its password.";
        Row(null, new Label { Text = note, AutoSize = true });
        Row("User name (optional)", user);
        Row("Password", password);
        Row(null, remember);
        Buttons(() => password.Text.Length > 0);
        ActiveControl = password;
    }
}
