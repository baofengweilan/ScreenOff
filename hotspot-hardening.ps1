# hotspot-hardening.ps1 - 一次性管理员加固（合并版，v2 网卡层 + v3 系统层）
# 由 screen-off.ps1 首次运行时提权调用；幂等，可重复执行。
#
# 两层防护：
#   [A] 网卡/驱动层 —— 防止网卡省电导致链路抖动、上游断开、热点被关：
#       关闭真实网卡省电（PnPCapabilities）、Realtek 绿色以太网/省电模式/GigaLite、
#       无线电源模式=最高性能、PCIe 链路电源管理=关闭、热点"无设备连接自动关闭"计时=关
#       （GigaLite 空闲时把千兆降到 100Mbps 引起断链，曾是实测元凶）
#   [B] 系统电源层 —— 彻底禁用 S0 现代待机（Modern Standby / 连接待机），
#       根治"灭屏约 2 分钟后系统进入连接待机：进程被冻结、网络断链、承载网络被停"（Kernel-Power 506 实锤）
#
# 回退 [B]：删除 HKLM\SYSTEM\CurrentControlSet\Control\Power 下的 PlatformAoAcOverride 并重启。
$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:LOCALAPPDATA 'ScreenOff'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'screen-off.log'
function Log($m) { Add-Content -LiteralPath $logFile -Value ("{0}  [hardening] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ('start, admin=' + $isAdmin)
if (-not $isAdmin) { Log 'not admin, abort'; exit 1 }

# 老版本标记兼容：旧版分文件时代（v2.done + v3.done）的加固都已应用过 → 直接落新标记，免一次无谓 UAC
$v2done = Test-Path (Join-Path $logDir 'hotspot-hardening.v2.done')
$v3done = Test-Path (Join-Path $logDir 'hotspot-hardening.v3.done')
if ($v2done -and $v3done) {
  Log 'legacy v2+v3 markers found, hardening already applied previously'
  Set-Content -LiteralPath (Join-Path $logDir 'hotspot-hardening.done') -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Log 'done'
  exit 0
}

# ================================================================ [A] 网卡/驱动层

# A1) 关闭真实网卡的"允许计算机关闭此设备以节约电源"（WLAN + 以太网）
Get-NetAdapter -ErrorAction SilentlyContinue |
  Where-Object { $_.InterfaceDescription -match 'Intel\(R\) Wi-Fi|Realtek' } |
  ForEach-Object {
    $nic = $_
    try {
      Set-NetAdapterPowerManagement -Name $nic.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
      Log ('power-mgmt disabled: ' + $nic.Name + ' (' + $nic.InterfaceDescription + ')')
    } catch {
      Log ('power-mgmt FAIL: ' + $nic.Name + ' :: ' + $_.Exception.Message)
    }
  }

# A2) 注册表兜底：PnPCapabilities=24 禁用网卡省电（若上面的 cmdlet 失败，重启系统后生效）
$netClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}'
Get-ChildItem $netClass -ErrorAction SilentlyContinue | ForEach-Object {
  $prop = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
  if ($prop.DriverDesc -match 'Intel\(R\) Wi-Fi|Realtek') {
    try {
      New-ItemProperty -Path $_.PSPath -Name PnPCapabilities -PropertyType DWord -Value 24 -Force -ErrorAction Stop | Out-Null
      Log ('PnPCapabilities=24 -> ' + $prop.DriverDesc)
    } catch {
      Log ('PnPCapabilities FAIL ' + $prop.DriverDesc + ' :: ' + $_.Exception.Message)
    }
  }
}

# A3) 关闭 Realtek 有线网卡自带节能：绿色以太网 / 省电模式 / Gigabit Lite
foreach ($nic in (Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Realtek' })) {
  foreach ($kw in @('EnableGreenEthernet', 'PowerSavingMode', 'GigaLite')) {
    try {
      Set-NetAdapterAdvancedProperty -Name $nic.Name -RegistryKeyword $kw -RegistryValue '0' -ErrorAction Stop
      Log ('adv-prop ' + $kw + '=0 -> ' + $nic.Name)
    } catch {
      Log ('adv-prop ' + $kw + ' FAIL on ' + $nic.Name + ' :: ' + $_.Exception.Message)
    }
  }
}

# A4) 无线适配器电源模式 -> 最高性能
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0

# A5) PCIe 链路状态电源管理 -> 关闭（防止有线网卡空闲掉链）
powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0

powercfg /setactive SCHEME_CURRENT
Log 'power plan updated (wireless=max perf, PCIe link pm=off)'

# A6) 热点"无设备连接自动关闭"开关置 0（Win10/11 对应 PeerlessTimeoutEnabled）
try {
  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\ICSSVC\Settings' -Name PeerlessTimeoutEnabled -Value 0 -ErrorAction Stop
  Log 'ICSSVC PeerlessTimeoutEnabled=0'
} catch {
  Log ('ICSSVC FAIL :: ' + $_.Exception.Message)
}

# ================================================================ [B] 系统电源层

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
  }
}

Set-Content -LiteralPath (Join-Path $logDir 'hotspot-hardening.done') -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Log 'done'
