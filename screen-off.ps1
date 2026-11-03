# screen-off.ps1 - display off + keep-awake guard; released on genuine user input
# v2: 灭屏期间保住移动热点 —— 一次性网卡省电加固 + 热点看门狗（被关自动重开）
# v3: 根治 —— 灭屏后系统进入 S0 连接待机导致网卡断链/进程冻结/热点被关（Kernel-Power 506 实锤），
#     看门狗升级：取不到 internet profile 时遍历所有连接配置继续拉起热点（不再跳过），
#     且仅在状态变化时记日志，避免日志刷屏。
# v4: 一次性加固合并为单一 hotspot-hardening.ps1（网卡层 + 禁用现代待机，一个 marker 管全部）。
# v5: 尊重手动关闭热点 —— 常驻脚本在"有人操作时热点被关"会记入手动锁存
#     （hotspot-user-off.flag），灭屏看门狗见到锁存文件就不再拉起；
#     每次按一键灭屏 = 重新接管"保热点"，锁存自动解除。
$ErrorActionPreference = 'SilentlyContinue'

$logDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'ScreenOff'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'screen-off.log'
function Log($m) { Add-Content -LiteralPath $logFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

# ---- 手动关闭锁存（v5）：与 always-awake 共用；灭屏守卫只读不写 ----
$hotspotUserOffFlag = Join-Path $logDir 'hotspot-user-off.flag'
function Test-UserOffLatch { return (Test-Path -LiteralPath $hotspotUserOffFlag) }
function Clear-UserOffLatch { Remove-Item -LiteralPath $hotspotUserOffFlag -Force -ErrorAction SilentlyContinue }

Log ('START pid=' + $PID + ' ps=' + $PSVersionTable.PSVersion.ToString())

# ---------------------------------------------------------------- 0) 一次性加固
# 合并版加固（网卡层 + 禁用现代待机；需要管理员一次，首次运行弹 UAC，之后因 marker 文件存在而直接跳过）
$marker = Join-Path $logDir 'hotspot-hardening.done'
$hardener = Join-Path $PSScriptRoot 'hotspot-hardening.ps1'
if (-not (Test-Path $marker) -and (Test-Path $hardener)) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    Log 'hardening: admin session, run inline'
    & $hardener
  } else {
    Log 'hardening: requesting one-time elevation (UAC)...'
    try {
      $hp = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $hardener + '"') -Verb RunAs -PassThru -Wait -ErrorAction Stop
      Log ('hardening: elevated child exit=' + $hp.ExitCode)
    } catch {
      Log ('hardening: elevation cancelled or failed: ' + $_.Exception.Message)
    }
  }
} else {
  Log 'hardening: already applied'
}

# ---------------------------------------------------------------- 显示关闭用的 Win32 API
$src = @(
'using System;',
'using System.Runtime.InteropServices;',
'public static class ScreenOff {',
'  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);',
'  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr res);',
'  [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);',
'  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(IntPtr plii);',
'  public const uint ES_CONTINUOUS = 0x80000000u;',
'  public const uint ES_SYSTEM_REQUIRED = 0x1u;',
'  public static void KeepAwake() { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED); }',
'  public static void Release() { SetThreadExecutionState(ES_CONTINUOUS); }',
'}'
) -join "`r`n"

try {
  Add-Type -TypeDefinition $src
  Log 'Add-Type OK'
} catch {
  Log ('Add-Type FAIL: ' + $_.Exception.Message)
  exit 1
}

# ---------------------------------------------------------------- 热点看门狗（WinRT, 5.1 可用）
$script:hotspotWatch = $false
$script:sawHotspotOn = $false
$script:netState = ''
$script:manualLogged = $false
$script:asTaskOp = $null
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
  $null = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
  $script:asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
  })[0]
  if ($script:asTaskOp) { $script:hotspotWatch = $true; Log 'hotspot watchdog: WinRT loaded' }
} catch {
  Log ('hotspot watchdog: WinRT unavailable, disabled: ' + $_.Exception.Message)
}

function Await-Op($op, [Type]$t, [int]$timeoutMs = 15000) {
  $m = $script:asTaskOp.MakeGenericMethod($t)
  $task = $m.Invoke($null, @($op))
  if (-not $task.Wait($timeoutMs)) { throw 'hotspot operation timeout' }
  return $task.Result
}

function Start-HotspotIfNeeded($mgr) {
  $st = $mgr.TetheringOperationalState.ToString()
  if ($st -eq 'On') {
    if (-not $script:sawHotspotOn) { $script:sawHotspotOn = $true; Log 'watchdog: hotspot ON' }
    return
  }
  if ($st -eq 'InTransition') { return }
  if (Test-UserOffLatch) {
    if (-not $script:manualLogged) { $script:manualLogged = $true; Log 'watchdog: hotspot off — user manually disabled, leaving it off' }
    return
  }
  Log ('watchdog: hotspot ' + $st + ', forcing back on')
  $res = Await-Op $mgr.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
  Log ('watchdog: restart status=' + $res.Status.ToString() + ' msg=' + $res.AdditionalErrorMessage)
}

function Test-HotspotAlive {
  try {
    $prof = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $prof) {
      # 取不到 internet profile（待机唤醒窗口内 NCSI 尚未完成连通性检测、或上游暂时断开）时，
      # 不要跳过：遍历所有连接配置文件，找到能建 TetheringManager 的就探活/拉起热点。
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
        if (Test-UserOffLatch) {
          if (-not $script:manualLogged) { $script:manualLogged = $true; Log 'watchdog: hotspot off — user manually disabled, leaving it off' }
          return
        }
        Log ('watchdog: hotspot ' + $candidate.TetheringOperationalState.ToString() + ', forcing back on (fallback profile)')
        $res = Await-Op $candidate.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
        Log ('watchdog: restart status=' + $res.Status.ToString() + ' msg=' + $res.AdditionalErrorMessage)
      }
      return
    }
    $script:netState = 'online'
    $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($prof)
    Start-HotspotIfNeeded $mgr
  } catch {
    Log ('watchdog error: ' + $_.Exception.Message)
  }
}

# 1) display off: WM_SYSCOMMAND(0x112) + SC_MONITORPOWER(0xF170) + mode 2 (off)
$null = [ScreenOff]::PostMessage([IntPtr]0xFFFF, 0x112, [IntPtr]0xF170, [IntPtr]2)
$res = [IntPtr]::Zero
$null = [ScreenOff]::SendMessageTimeout([IntPtr]0xFFFF, 0x112, [IntPtr]0xF170, [IntPtr]2, 2, 500, [ref]$res)
Log 'display-off sent'

# 2) hold PowerRequest(SystemRequired): blocks idle sleep while the screen is off
[ScreenOff]::KeepAwake()
Log 'keep-awake armed'

# 2a) 按一键灭屏 = 重新接管"保热点"：解除手动关闭锁存（之后若又手动关热点，锁存会重新建立）
if (Test-UserOffLatch) { Clear-UserOffLatch; Log 'manual-off latch cleared — screen-off re-arm keeps hotspot alive' }

# 2b) 武装时立刻检查一次热点；热点若没在线也会被拉起（保持热点常活）
if ($script:hotspotWatch) { Test-HotspotAlive }

# 3) release on GENUINE user input: an input only counts after a >= 5s silent gap,
#    because display-off itself injects a burst of synthetic mouse input.
$ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(8)
try {
  [System.Runtime.InteropServices.Marshal]::WriteInt32($ptr, 0, 8)    # cbSize = 8
  $null = [ScreenOff]::GetLastInputInfo($ptr)
  $lastInput = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr, 4)
  Log ('armed baseline=' + $lastInput)

  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $gapWatch = [System.Diagnostics.Stopwatch]::StartNew()
  $netWatch = [System.Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    Start-Sleep -Milliseconds 500

    # 热点看门狗：每 20 秒巡检一次，热点不在线就立即拉起
    if ($script:hotspotWatch -and $netWatch.Elapsed.TotalSeconds -ge 20) {
      $netWatch.Restart()
      Test-HotspotAlive
    }

    $ok = [ScreenOff]::GetLastInputInfo($ptr)
    if (-not $ok) { Log 'GetLastInputInfo false'; break }
    $t = [System.Runtime.InteropServices.Marshal]::ReadInt32($ptr, 4)
    if ($t -gt $lastInput) {
      $silentFor = [int]$gapWatch.Elapsed.TotalSeconds
      if ($silentFor -ge 5) {
        Log ('genuine input detected after ' + $silentFor + 's silence, at ' + [int]$clock.Elapsed.TotalSeconds + 's')
        break
      }
      Log ('synthetic burst absorbed (silent ' + $silentFor + 's) at ' + [int]$clock.Elapsed.TotalSeconds + 's')
      $lastInput = $t
      $gapWatch.Restart()
    }
    if ($clock.Elapsed.TotalHours -ge 12) { Log '12h cap reached'; break }
  }
} finally {
  [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
}

# 4) user is back - release the keep-awake request
[ScreenOff]::Release() | Out-Null
Log 'released, exit'
