# install.ps1 - copy scripts to %APPDATA%\ScreenOff and create shortcuts.
# Works on Windows PowerShell 5.1 and PowerShell 7.
# The scripts keep their UTF-8 BOM so Windows PowerShell 5.1 reads the Chinese comments correctly.
param(
    [switch]$NoStartup,                    # skip the logon autostart entry
    [string]$ShortcutName = 'ScreenOff'    # desktop shortcut name
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dest = Join-Path $env:APPDATA 'ScreenOff'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($f in 'screen-off.ps1', 'always-awake.ps1', 'hotspot-hardening.ps1') {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force
}
Write-Host ('scripts copied to: ' + $dest)

$ws = New-Object -ComObject WScript.Shell
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"'

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = $ps
$lnk.Arguments = ($arg -f (Join-Path $dest 'screen-off.ps1'))
$lnk.Description = 'Turn off the display only; system and Mobile Hotspot keep running.'
$lnk.Save()
Write-Host ('desktop shortcut created: ' + $lnkPath)

if (-not $NoStartup) {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnk2Path = Join-Path $startup 'AlwaysAwake.lnk'
    $lnk2 = $ws.CreateShortcut($lnk2Path)
    $lnk2.TargetPath = $ps
    $lnk2.Arguments = ($arg -f (Join-Path $dest 'always-awake.ps1'))
    $lnk2.Description = 'Keep-awake + Mobile Hotspot watchdog (starts with Windows).'
    $lnk2.Save()
    Write-Host ('startup shortcut created: ' + $lnk2Path)
}

Write-Host ''
Write-Host 'Done. Double-click the desktop shortcut to turn the screen off;'
Write-Host 'touch the mouse/keyboard to come back.'
Write-Host 'The first run asks once for admin (UAC) to apply power hardening.'
Write-Host 'Reboot once afterwards so disabling Modern Standby takes full effect.'
