# hotspot-hardening-v3.ps1 - 一次性管理员加固（v3）：禁用现代待机，根治灭屏后热点掉线
# 背景（日志+事件日志实锤）：灭屏后约 2 分钟，系统进入 S0 连接待机（Kernel-Power 506/507 循环），
# 期间以太网断链、承载网络被 WLAN 服务停止、所有桌面进程被冻结，看门狗即使短暂拉起热点也会被再次杀死。
# v3 方案：写入 PlatformAoAcOverride=0 禁用现代待机。重启一次后生效：灭屏=仅关闭显示器，系统保持完全运行。
# 回退方法：删除 HKLM\SYSTEM\CurrentControlSet\Control\Power 下的 PlatformAoAcOverride 并重启，即可恢复现代待机。
# 由 screen-off.ps1 首次运行时提权调用；幂等，可重复执行。
$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:LOCALAPPDATA 'ScreenOff'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'screen-off.log'
function Log($m) { Add-Content -LiteralPath $logFile -Value ("{0}  [hardening-v3] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ('start, admin=' + $isAdmin)
if (-not $isAdmin) { Log 'not admin, abort'; exit 1 }

$power = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
try {
  $cur = (Get-ItemProperty -Path $power -Name PlatformAoAcOverride -ErrorAction Stop).PlatformAoAcOverride
} catch { $cur = $null }

if ($cur -eq 0) {
  Log 'PlatformAoAcOverride already 0 (modern standby already disabled)'
} else {
  try {
    New-ItemProperty -Path $power -Name PlatformAoAcOverride -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
    Log 'PlatformAoAcOverride=0 written (reboot once to take effect)'
  } catch {
    Log ('PlatformAoAcOverride FAIL :: ' + $_.Exception.Message)
    exit 1
  }
}

Set-Content -LiteralPath (Join-Path $logDir 'hotspot-hardening.v3.done') -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Log 'done'
