# always-awake.ps1 - permanent keep-awake (no auto-sleep) + 60s hotspot watchdog
# Single instance via mutex. Reversible: kill this process and remove the Startup shortcut.
# v3: 看门狗升级 —— 取不到 internet profile 时遍历所有连接配置继续拉起热点（不再跳过）；
#     启动时立即巡检一次（旧版要等 60 秒才第一次检查）；仅在状态变化时记日志。
$ErrorActionPreference = 'SilentlyContinue'

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ScreenOffAlwaysAwake', [ref]$created)
if (-not $created) { exit }

$logDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'ScreenOff'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'always-awake.log'
function Log($m) { Add-Content -LiteralPath $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

Log ('START pid=' + $PID + ' ps=' + $PSVersionTable.PSVersion.ToString())

$src = @(
'using System;',
'using System.Runtime.InteropServices;',
'public static class AlwaysAwake {',
'  [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);',
'  public const uint ES_CONTINUOUS = 0x80000000u;',
'  public const uint ES_SYSTEM_REQUIRED = 0x1u;',
'  public static void Arm() { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED); }',
'}'
) -join "`r`n"
Add-Type -TypeDefinition $src
[AlwaysAwake]::Arm()
Log 'power request armed (system will not auto-sleep)'

# hotspot watchdog via WinRT
$script:asTaskOp = $null
$script:sawHotspotOn = $false
$script:netState = ''
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
  $null = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
  $script:asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]
  if ($script:asTaskOp) { Log 'hotspot watchdog: WinRT loaded' }
} catch { Log ('watchdog disabled: ' + $_.Exception.Message) }

function Await-Op($op, [Type]$t) {
  $m = $script:asTaskOp.MakeGenericMethod($t)
  $task = $m.Invoke($null, @($op))
  if (-not $task.Wait(15000)) { throw 'hotspot operation timeout' }
  return $task.Result
}

function Start-HotspotIfNeeded($mgr) {
  $st = $mgr.TetheringOperationalState.ToString()
  if ($st -eq 'On') {
    if (-not $script:sawHotspotOn) { $script:sawHotspotOn = $true; Log 'watchdog: hotspot ON' }
    return
  }
  if ($st -eq 'InTransition') { return }
  Log ('watchdog: hotspot ' + $st + ', forcing back on')
  $res = Await-Op $mgr.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
  Log ('watchdog: restart status=' + $res.Status.ToString())
}

function Test-HotspotAlive {
  try {
    $prof = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $prof) {
      # 待机唤醒窗口内 NCSI 可能尚未就绪 —— 遍历所有连接配置，能建 TetheringManager 就探活/拉起
      $all = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
      if (-not $all -or @($all).Count -eq 0) {
        if ($script:netState -ne 'offline') { Log 'watchdog: no connection profile at all (system offline)'; $script:netState = 'offline' }
        return
      }
      if ($script:netState -ne 'degraded') { Log ('watchdog: no internet profile, probing ' + @($all).Count + ' profile(s)'); $script:netState = 'degraded' }
      $candidate = $null
      foreach ($p in @($all)) {
        try {
          $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
          $st = $mgr.TetheringOperationalState.ToString()
          if ($st -eq 'On') {
            if (-not $script:sawHotspotOn) { $script:sawHotspotOn = $true; Log 'watchdog: hotspot ON' }
            return
          }
          if ($st -eq 'InTransition') { return }
          if (-not $candidate) { $candidate = $mgr }
        } catch { }
      }
      if ($candidate) {
        Log ('watchdog: hotspot ' + $candidate.TetheringOperationalState.ToString() + ', forcing back on (fallback profile)')
        $res = Await-Op $candidate.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        Log ('watchdog: restart status=' + $res.Status.ToString())
      }
      return
    }
    $script:netState = 'online'
    $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($prof)
    Start-HotspotIfNeeded $mgr
  } catch { Log ('watchdog error: ' + $_.Exception.Message) }
}

# 启动即巡检一次（旧版要等第一个 60 秒睡眠后才检查）
if ($script:asTaskOp) { Test-HotspotAlive }

$ticks = 0
while ($true) {
  Start-Sleep -Seconds 60
  $ticks++
  [AlwaysAwake]::Arm()
  if ($script:asTaskOp) { Test-HotspotAlive }
  if ($ticks % 60 -eq 0) { Log 'alive (hourly heartbeat)' }
}
