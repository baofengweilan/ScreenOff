# install.ps1 - copy scripts to %APPDATA%\ScreenOff and create shortcuts.
# Requires PowerShell 7 (pwsh) - all shortcuts target pwsh explicitly (no powershell.exe).
# Shortcuts launch through a windowless VBScript wrapper (wscript) so neither the
# double-click nor the logon ever flashes a console window.
# The scripts keep their UTF-8 BOM so Chinese comments render correctly in every host.
param(
    [switch]$NoStartup,                    # skip the logon autostart entry
    [string]$ShortcutName = 'ScreenOff'    # desktop shortcut name
)

$ErrorActionPreference = 'Stop'

try {
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
} catch {
    Write-Host 'PowerShell 7 (pwsh) is required but was not found in PATH.'
    Write-Host 'Install it first:  winget install --id Microsoft.PowerShell -e'
    exit 1
}

$src = $PSScriptRoot
$dest = Join-Path $env:APPDATA 'ScreenOff'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($f in 'screen-off.ps1', 'always-awake.ps1', 'hotspot-hardening.ps1') {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force
}
Write-Host ('scripts copied to: ' + $dest)

# --- zero-flash VBScript launchers (pwsh path baked in at install time) ---
$vbsTemplate = @'
' zero-flash launcher: wscript is a GUI-subsystem host, so the pwsh console
' is created hidden from the very first frame - no terminal flash anywhere.
CreateObject("WScript.Shell").Run """PWSH_PATH"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""SCRIPT_PATH""", 0, False
'@
$ws = New-Object -ComObject WScript.Shell

# desktop shortcut: ScreenOff
$vbsA = $vbsTemplate.Replace('PWSH_PATH', $pwsh).Replace('SCRIPT_PATH', (Join-Path $dest 'screen-off.ps1'))
$vbsAPath = Join-Path $dest 'launch-screen-off.vbs'
[IO.File]::WriteAllText($vbsAPath, $vbsA)

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '"' + $vbsAPath + '"'
$lnk.WorkingDirectory = $dest
$lnk.IconLocation = $pwsh + ',0'
$lnk.Description = 'Turn off the display only; system and Mobile Hotspot keep running.'
$lnk.Save()
Write-Host ('desktop shortcut created: ' + $lnkPath)

# startup shortcut: AlwaysAwake
if (-not $NoStartup) {
    $vbsB = $vbsTemplate.Replace('PWSH_PATH', $pwsh).Replace('SCRIPT_PATH', (Join-Path $dest 'always-awake.ps1'))
    $vbsBPath = Join-Path $dest 'launch-always-awake.vbs'
    [IO.File]::WriteAllText($vbsBPath, $vbsB)

    $startup = [Environment]::GetFolderPath('Startup')
    $lnk2Path = Join-Path $startup 'AlwaysAwake.lnk'
    $lnk2 = $ws.CreateShortcut($lnk2Path)
    $lnk2.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk2.Arguments = '"' + $vbsBPath + '"'
    $lnk2.WorkingDirectory = $dest
    $lnk2.IconLocation = $pwsh + ',0'
    $lnk2.Description = 'Keep-awake + Mobile Hotspot watchdog (starts with Windows).'
    $lnk2.Save()
    Write-Host ('startup shortcut created: ' + $lnk2Path)
}

Write-Host ''
Write-Host 'Done. Double-click the desktop shortcut to turn the screen off;'
Write-Host 'touch the mouse/keyboard to come back.'
Write-Host 'The first run asks once for admin (UAC) to apply power hardening.'
Write-Host 'Reboot once afterwards so disabling Modern Standby takes full effect.'
