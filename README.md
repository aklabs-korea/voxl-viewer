# voxl viewer

Small native apps for Mac and Windows that show a [voxl](https://github.com/tembo/voxl)
remote desktop in its own window.

voxl, by Tembo, streams a machine's screen to a web page. These apps load that same page in the
system's web view (WebKit on the Mac, WebView2 on Windows) and add what a browser tab can't do.

This is an unofficial, independent project. It is not made or supported by Tembo.

## Why not a browser tab

- **Shortcuts reach the remote machine.** A browser keeps Cmd+W, Ctrl+T, Ctrl+R, F5 and others
  for itself. Here they go to the remote.
- **The Win key for Mac remotes.** On Windows, the Win key can go to a Mac as its Control key
  instead of opening the Start menu.
- **A window per machine.** Each machine gets its own window, its own Dock or Start-menu entry,
  and its window size and position remembered.
- **A machine's screens in one window.** Each display of a machine is its own voxl page. Its
  window shows one at a time and switches with a key or a tab at its edge, without moving,
  resizing or rescaling anything.
- **Sound follows you.** It plays only while the window is in front and you used this machine's
  own keyboard or mouse in the last 5 minutes.
- **Clipboard both ways**, uploads and downloads through voxl's Files panel, full screen, and
  automatic retry while the remote is offline or voxl restarts.

With a voxl host that excludes the viewer's sound from capture, two machines can view each other
without sending that sound round in a loop. Use the viewer on both. A browser tab on a machine
that is also being viewed is a bad idea: the host doesn't exclude its sound, and the tab has no
gate for the window in front or recent local input.

## Install

Download the latest build from
[Releases](https://github.com/danyeoakl/voxl-viewer/releases/latest).

### Mac

macOS 14 or later, Apple Silicon or Intel.

1. Download `voxl-viewer-mac.zip` and unzip it.
2. Move `voxl viewer.app` to Applications and open it.

If the release notes say the Mac app isn't notarized, macOS blocks it the first time. Open
System Settings > Privacy & Security, scroll down and click **Open Anyway**.

### Windows

Windows 10 or 11, x64.

1. Download `voxl-viewer-windows-x64.zip` and unzip it into a folder you keep, such as
   `%LOCALAPPDATA%\Programs\voxl viewer`.
2. Run `VoxlViewer.exe`.

The app isn't code-signed, so SmartScreen may say "Windows protected your PC". Click
**More info**, then **Run anyway**.

The app needs the Microsoft Edge WebView2 Runtime. Windows 11 includes it. On Windows 10, install
the [Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) if it's missing.

## Before you start

You need a voxl URL that already works in a browser. Browsers, and these apps, only play voxl's
stream over HTTPS or on `localhost`. To reach another machine, put voxl behind TLS (for example
`tailscale serve`) and name the host with voxl's `--allowed-hosts`. See
[voxl's README](https://github.com/tembo/voxl#faq).

## Use

### Add a machine

On first launch the app asks for a machine:

- **Name**: the window's title, such as `My Mac`.
- **voxl URL**: its first screen, such as `https://my-mac.example.ts.net:6901/` or
  `http://localhost:6901/`.

The Windows app has two more options:

- **This is a Mac**: send the Win key to the Mac as its Control key (see [Keys](#keys)).
  Off by default.
- **Decode video on the CPU**: for graphics cards that can't decode the remote's screen size.
  Many decode H.264 only up to 4096 pixels wide, so a wider screen needs this.

Each machine opens in its own window. The app remembers each window's size and position.

### Screens

voxl streams one display per port, so a machine with two displays runs two voxls. Add the
others in the machine's **Settings**: paste a screen's voxl link and click **Add screen**
(Windows) or **Add Screen…** (Mac). The screen is named after voxl's `--title`, or its host and
port; rename it in the list.

The order is yours, whatever the remote machine calls its main display. Screen 1 opens with the
window and the keys go by number. Change the order with **Move up** and **Move down**.

To switch screens:

- **Keys**: Control+Option+1 to 9 on the Mac, Win+Alt+1 to 9 on Windows. 1 and 2 always switch
  screens; 3 to 9 only on a machine with that many, otherwise they go to the remote.
- **The tab**: rest the pointer for a moment in the middle of the window's top edge, and a tab
  slides in with the screen's name. Click it for the panel: the machine's screens, Full | Sharp,
  Full screen and Settings. Clicking the screen on show connects it again.

The tab never takes the keyboard, so typing keeps going to the remote. It doesn't come while a
mouse button is held, and after a click at the edge, or once it has been left alone, it waits
until the pointer leaves the edge. Pick its edge (Top, Left, Bottom or Right) in Settings; it's
one choice for every window.

A switch shows black and the screen's name until its picture arrives. Keys typed meanwhile go
nowhere, so nothing lands on a screen you haven't seen yet. A screen that doesn't answer stays
black with a note, and the app tries it again every 3 seconds. It never switches to another
screen on its own.

### Full and Sharp

A screen can also have a **Sharp URL**: a second voxl of the same display at a smaller size (for
example with voxl's `--capture-scale 0.8`). When every screen of a machine has one, the panel
offers **Full | Sharp**. It's one choice for every window. On Windows, Sharp always decodes on
the graphics card, even when the machine decodes Full on the CPU.

### Sound

Sound plays only once the page has loaded, while its window is in front and you have used this
machine's own keyboard or mouse in the last 5 minutes. Input sent by a voxl host doesn't keep
sound on. Bringing the window forward remotely isn't enough after those 5 minutes: use the
local keyboard or mouse. Minimizing the window mutes it; on the Mac, leaving the app, locking
the screen or putting the display to sleep also mutes it. On Windows, this window's Settings
and its dialogs still count as in front.

A new WebView2 browser process on Windows, or a newly launched Mac app, stays muted for its first
2 seconds so a local voxl host has time to exclude its sound from capture. On Windows, all
windows share one browser process; CPU decode and Full | Sharp changes navigate the same view.

### Menus

Mac: the **Machines** menu lists your machines, with **Add Machine…** and **Settings…** for the
machine in front: its name, screens and Sharp URLs, the tab's edge, and **Remove Machine…**. The
**View** menu has Reload, voxl's stats overlay and full screen.

Windows: click the icon at the top left of the window, or right-click the title bar. That menu
lists your machines and has **Add machine...**, **Settings...** (the name, the two options above,
the screens and the tab's edge), **Remove this machine...**, **Add this machine to the Start
menu**, Full screen, Reload and voxl's stats overlay.

### A launcher per machine

Mac: from a copy of this repository, make an app for a machine, with its own Dock icon and window
memory:

```sh
mac/make-shortcut.sh "My Mac" https://my-mac.example.ts.net:6901/
```

This copies `build/voxl viewer.app` (or the one in Applications) to
`~/Applications/voxl viewer/My Mac.app`.

Windows: open the machine, then choose **Add this machine to the Start menu** from the window
menu. It goes in a "voxl viewer" folder in the Start menu.

You can also open a URL directly:

```sh
open -n -a "voxl viewer" --args https://my-mac.example.ts.net:6901/ "My Mac"
```

```powershell
VoxlViewer.exe https://my-pc.example.ts.net:6901/ "My PC"
```

A launcher or a URL opens the saved machine that has a screen at that URL, at its screen 1. A URL
that no machine has opens as a machine of its own.

## Keys

voxl maps keys between Mac and PC on its own. For example, Cmd on a Mac is Ctrl on a Windows
remote, and Ctrl on a PC is Cmd on a Mac remote. These apps make sure the keys get to voxl.

### Mac app

| Keys | What happens |
| --- | --- |
| Cmd+Q | Quits the app |
| Ctrl+Cmd+F | Full screen on or off |
| Control+Option+1 to 9 | Screen 1 to 9 (3 to 9 when the machine has them) |
| Cmd+V | Pastes your Mac's clipboard on the remote |
| Other Cmd shortcuts (Cmd+W, Cmd+T, Cmd+R, ...) | Go to the remote |
| Cmd+Tab, Cmd+Space | Stay with macOS, as in any app |

### Windows app

| Keys | What happens |
| --- | --- |
| Ctrl+W, Ctrl+T, Ctrl+R, F5 and other browser shortcuts | Go to the remote |
| F11 | Full screen on or off. On keyboards whose F keys are media keys, Fn+F11. The tab's panel also has **Leave full screen**. |
| Win+Alt+1 to 9 | Screen 1 to 9 (3 to 9 when the machine has them) |
| Win, alone or with other keys | With **This is a Mac**: go to the Mac as Control. Otherwise Windows keeps them. |
| Alt on its own | Goes to the remote (Option on a Mac) instead of opening the window menu |
| Win+L, Ctrl+Alt+Del | Always stay with Windows |

### Keys typed by other programs

Two viewers can show each other: a Mac's window on a PC, and that PC's window on the Mac. A key
typed into one would then go round and round. So while a viewer window is in front, the Windows
app ignores keys that other programs type, and the Mac app ignores keys that voxl types on that
Mac. On Windows that also stops the on-screen keyboard, password-manager auto-type and key
remappers from reaching the remote; type with the keyboard instead.

## voxl passwords

voxl asks for a password unless it runs with `--enable-basic-auth=false`.

The app asks for a user name (optional) and the password, and can remember them for that host:

- **Mac**: tick **Save in Keychain**. To forget it, delete "voxl viewer (host:port)" in
  Keychain Access. Each launcher, and each new unsigned build, is a new app to macOS: the first
  time it uses a saved password, macOS asks for your Mac's login password. Click **Always Allow**.
- **Windows**: tick **Remember it in Windows Credential Manager**. To forget it, remove
  "voxl viewer: https://host:port" under Windows Credentials in Credential Manager.

These passwords stay out of the apps' settings files.

A `?token=` link also works, such as `https://my-mac.example.ts.net:6901/?token=...`. The token
is then part of the URL, so it is saved wherever the URL is: the app's settings, any launcher
you make, and the web view's cache. Removing the machine doesn't erase all of those, so change
voxl's password if a token link gets out.

## Settings files

For scripts that set up machines:

- **Windows**: `%LOCALAPPDATA%\voxl-viewer\settings.json`. The comment at the top of
  [windows/Settings.cs](windows/Settings.cs) shows its shape.
- **Mac**: the defaults domain `io.github.danyeoakl.voxl-viewer`, key `machineList`. The comment
  near the top of [mac/VoxlViewer.swift](mac/VoxlViewer.swift) shows its shape and a
  `defaults write` example.

Settings from earlier versions, with one URL per machine, load as machines with one screen.

## Privacy

No telemetry. The apps only connect to the voxl URLs you add.

## Build from source

### Mac

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
mac/build.sh                 # makes build/voxl viewer.app, ad-hoc signed
mac/build.sh --universal     # Apple Silicon and Intel in one app
mac/build.sh --universal --sign "Developer ID Application: Your Name (TEAMID)"
```

### Windows

Needs the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```powershell
dotnet publish windows/VoxlViewer.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o out/win-x64
```

This makes `out/win-x64/VoxlViewer.exe`. Or install it in one step: this builds the app into
`%LOCALAPPDATA%\Programs\voxl viewer` and adds it to the Start menu.

```powershell
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

### Releases

Pushing a tag such as `v1.0.0` builds both apps and attaches them to a GitHub release. To sign
and notarize the Mac app, set these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Your Developer ID Application certificate and key as a .p12 file, base64-encoded |
| `MACOS_CERT_PASSWORD` | The .p12 file's password |
| `NOTARY_KEY_ID` | An App Store Connect API key's ID |
| `NOTARY_ISSUER_ID` | That key's issuer ID |
| `NOTARY_KEY_P8` | That key's .p8 file, as text |

Without them, the Mac app has an ad-hoc signature and the release notes say so.

## Credits

[voxl](https://github.com/tembo/voxl) is by Tembo, under the MIT license. The app icon is voxl's
favicon, used under that license. See [CREDITS.md](CREDITS.md).

## License

MIT. See [LICENSE](LICENSE).
