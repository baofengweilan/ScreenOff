# install.ps1 - copy scripts to %APPDATA%\ScreenOff and create shortcuts.
# Runs under Windows PowerShell 5.1 or PowerShell 7 - whichever you start it with.
# Shortcut engine: pwsh 7 when available, Windows PowerShell 5.1 as fallback
# (force 5.1 with -UseWindowsPowerShell for the full hotspot watchdog - WinRT is 5.1-only).
# Shortcuts launch through a windowless VBScript wrapper (wscript.exe) so neither the
# double-click nor the logon ever flashes a console window.
# The scripts keep their UTF-8 BOM so Chinese comments render correctly in every host.
param(
    [switch]$NoStartup,                    # skip the logon autostart entry
    [string]$ShortcutName = 'ScreenOff',   # desktop shortcut name
    [switch]$UseWindowsPowerShell          # force shortcuts to Windows PowerShell 5.1
                                           # (full hotspot watchdog: WinRT tethering is 5.1-only)
)

$ErrorActionPreference = 'Stop'

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$engine = $null
$engineName = ''
if ($UseWindowsPowerShell) {
    $engine = $ps51
    $engineName = 'Windows PowerShell 5.1'
} else {
    try {
        $engine = (Get-Command pwsh -ErrorAction Stop).Source
        $engineName = 'PowerShell 7 (pwsh)'
    } catch {
        $engine = $ps51
        $engineName = 'Windows PowerShell 5.1 (pwsh not found)'
    }
}
Write-Host ('shortcuts will launch with: ' + $engineName)

$src = $PSScriptRoot
$dest = Join-Path $env:APPDATA 'ScreenOff'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($f in 'screen-off.ps1', 'always-awake.ps1', 'hotspot-hardening.ps1') {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $dest $f) -Force
}
Write-Host ('scripts copied to: ' + $dest)

# --- zero-flash VBScript launchers (engine path baked in at install time) ---
$vbsTemplate = @'
' zero-flash launcher: wscript is a GUI-subsystem host, so the PowerShell console
' is created hidden from the very first frame - no terminal flash anywhere.
CreateObject("WScript.Shell").Run """PWSH_PATH"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""SCRIPT_PATH""", 0, False
'@
$ws = New-Object -ComObject WScript.Shell

# desktop shortcut: ScreenOff
$vbsA = $vbsTemplate.Replace('PWSH_PATH', $engine).Replace('SCRIPT_PATH', (Join-Path $dest 'screen-off.ps1'))
$vbsAPath = Join-Path $dest 'launch-screen-off.vbs'
[IO.File]::WriteAllText($vbsAPath, $vbsA)

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '"' + $vbsAPath + '"'
$lnk.WorkingDirectory = $dest
$lnk.IconLocation = $engine + ',0'
$lnk.Description = 'Turn off the display only; system and Mobile Hotspot keep running.'
$lnk.Save()
Write-Host ('desktop shortcut created: ' + $lnkPath)

# startup shortcut: AlwaysAwake
if (-not $NoStartup) {
    $vbsB = $vbsTemplate.Replace('PWSH_PATH', $engine).Replace('SCRIPT_PATH', (Join-Path $dest 'always-awake.ps1'))
    $vbsBPath = Join-Path $dest 'launch-always-awake.vbs'
    [IO.File]::WriteAllText($vbsBPath, $vbsB)

    $startup = [Environment]::GetFolderPath('Startup')
    $lnk2Path = Join-Path $startup 'AlwaysAwake.lnk'
    $lnk2 = $ws.CreateShortcut($lnk2Path)
    $lnk2.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk2.Arguments = '"' + $vbsBPath + '"'
    $lnk2.WorkingDirectory = $dest
    $lnk2.IconLocation = $engine + ',0'
    $lnk2.Description = 'Keep-awake + Mobile Hotspot watchdog (starts with Windows).'
    $lnk2.Save()
    Write-Host ('startup shortcut created: ' + $lnk2Path)
}

Write-Host ''
Write-Host 'Done. Double-click the desktop shortcut to turn the screen off;'
Write-Host 'touch the mouse/keyboard to come back.'
Write-Host 'The first run asks once for admin (UAC) to apply power hardening.'
Write-Host 'Reboot once afterwards so disabling Modern Standby takes full effect.'
Write-Host ('Engine: ' + $engineName + '  (hotspot watchdog full under 5.1, self-disables under pwsh)')
