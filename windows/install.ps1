# Builds voxl viewer into %LOCALAPPDATA%\Programs\voxl viewer and adds it to the Start menu, in a
# "voxl viewer" folder (the app's "Add this machine to the Start menu" puts machines there too).
# Needs the .NET 10 SDK. Run it again to update, with the viewer's windows closed:
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
$ErrorActionPreference = 'Stop'
$app = Join-Path $env:LOCALAPPDATA 'Programs\voxl viewer'
dotnet publish (Join-Path $PSScriptRoot 'VoxlViewer.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $app --nologo
if ($LASTEXITCODE) { exit $LASTEXITCODE }
$exe = Join-Path $app 'VoxlViewer.exe'
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'voxl viewer'
New-Item -ItemType Directory -Force -Path $menu | Out-Null
$link = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $menu 'voxl viewer.lnk'))
$link.TargetPath = $exe
$link.WorkingDirectory = $app
$link.IconLocation = "$exe,0"
$link.Description = 'voxl viewer'
$link.Save()
"Installed $exe"
"Start menu: voxl viewer"
