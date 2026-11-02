# hotspot-hardening.ps1 - 一次性管理员加固：防止灭屏后网卡省电导致移动热点被系统关闭
# 由 screen-off.ps1 首次运行时提权调用；幂等，可重复执行。
$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:LOCALAPPDATA 'ScreenOff'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'screen-off.log'
function Log($m) { Add-Content -LiteralPath $logFile -Value ("{0}  [hardening] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ('start, admin=' + $isAdmin)
if (-not $isAdmin) { Log 'not admin, abort'; exit 1 }

# 1) 关闭真实网卡的"允许计算机关闭此设备以节约电源"（WLAN + 以太网）
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

# 1b) 注册表兜底：PnPCapabilities=24 禁用网卡省电（若上面的 cmdlet 失败，重启系统后生效）
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

# 1c) 关闭 Realtek 有线网卡自带节能：绿色以太网 / 省电模式 / Gigabit Lite
#     Gigabit Lite 空闲时把千兆降到 100Mbps，链路抖动导致上游断开、热点被关（实测元凶）
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

# 2) 无线适配器电源模式 -> 最高性能
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0

# 3) PCIe 链路状态电源管理 -> 关闭（防止有线网卡空闲掉链）
powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0

powercfg /setactive SCHEME_CURRENT
Log 'power plan updated (wireless=max perf, PCIe link pm=off)'

# 4) 热点"无设备连接自动关闭"开关置 0（幂等；Win10/11 对应 PeerlessTimeoutEnabled）
try {
  Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\ICSSVC\Settings' -Name PeerlessTimeoutEnabled -Value 0 -Type DWord -ErrorAction Stop
  Log 'ICSSVC PeerlessTimeoutEnabled=0'
} catch {
  Log ('ICSSVC FAIL :: ' + $_.Exception.Message)
}

Set-Content -LiteralPath (Join-Path $logDir 'hotspot-hardening.v2.done') -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Log 'done'
