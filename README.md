[English](#screenoff) | [中文](#中文说明)

# ScreenOff

Turn off **only the display** on Windows — the system keeps running at full speed, background apps keep working, and the **Mobile Hotspot stays alive**.

One keystroke: screen dark, everything else untouched. No sleep, no standby, no network drops, no frozen background apps.

## Why this exists

On "Modern Standby" (S0 low power idle) Windows machines, turning off the display is **not** just turning off the display: within about 2 minutes the system drifts into Connected Standby. Desktop apps get frozen by the Desktop Activity Moderator, Ethernet/Wi-Fi drop their links, and the Mobile Hotspot is shut down — **even with "Sleep = Never" configured and keep-awake power requests held**.

This project was born from exactly that: a desktop acting as an always-on hotspot server whose hotspot died a few minutes after the screen went dark, every single night. System event logs confirmed `Kernel-Power 506/507` (entering/exiting Connected Standby) cycling all night, with the ICS tethering network stopped by WLAN AutoConfig each cycle.

The definitive fix is to take Modern Standby out of the equation, so screen-off finally means *monitor off, nothing else*.

## Components

| File | What it does |
|---|---|
| `screen-off.ps1` | The one-key screen-off script. Turns the display off (WM_SYSCOMMAND + SC_MONITORPOWER), holds a SystemRequired power request so the system never idles into standby, and releases it automatically on genuine user input (with a 5-second silence filter to ignore the synthetic input burst triggered by display-off). Includes a 20 s hotspot watchdog (WinRT) that revives the Mobile Hotspot whenever Windows turns it off. |
| `hotspot-hardening.ps1` | One-time admin hardening, run automatically on the first screen-off. **Network layer**: disables NIC power management (PnPCapabilities, Realtek Green Ethernet / PowerSavingMode / GigaLite), sets wireless power mode to max performance, disables PCIe link-state power management, and turns off the hotspot's "auto-off when no devices connected" timer. **System layer**: **disables Modern Standby entirely** (`PlatformAoAcOverride=0`, takes effect after one reboot) so the display-off state is purely cosmetic. Revert by deleting the registry value and rebooting. |
| `always-awake.ps1` | Optional resident guard (started from the Startup folder): holds the system awake 24/7 and runs a 60 s hotspot watchdog with the same fallback logic. Single-instance via mutex. |
| `install.ps1` | Copies the scripts to `%APPDATA%\ScreenOff` and creates the desktop shortcut plus (optionally) the Startup entry. |

## Quick start

Run in PowerShell 7 (pwsh):

```powershell
pwsh -ExecutionPolicy Bypass -File .\install.ps1    # add -NoStartup if you don't want the logon autostart
```

Then double-click the desktop shortcut to turn the screen off. Touch the mouse or keyboard to come back.

Notes:

- The first run asks once for admin (UAC) to apply the hardening; afterwards it runs silently.
- **Reboot once** after the hardening so disabling Modern Standby takes effect. Verify with `powercfg /a`: it should no longer list "Standby (S0 Low Power Idle)".
- To remove everything: delete the desktop/Startup shortcuts and the `%APPDATA%\ScreenOff` folder; to restore Modern Standby, delete `HKLM\SYSTEM\CurrentControlSet\Control\Power\PlatformAoAcOverride` and reboot.

## How it works

- Display off: `PostMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` with a `SendMessageTimeout` retry.
- Keep-awake: `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`; released when `GetLastInputInfo` reports new input after a ≥ 5 s silent gap.
- Hotspot watchdog: `NetworkOperatorTetheringManager.TetheringOperationalState`, revived via `StartTetheringAsync`. When no internet connection profile is visible (typical during standby wake windows), it falls back to probing **all** connection profiles instead of skipping — this was the difference between a hotspot dead for 10 hours and one revived within a minute.
- Modern Standby disable: `HKLM\SYSTEM\CurrentControlSet\Control\Power\PlatformAoAcOverride = 0` (DWORD).
- **Manual-off respect (sticky)**: if the hotspot is turned off while someone is using the PC (keyboard/mouse input in the last 90 s), the watchdog treats it as intentional — it records a latch file (`%LOCALAPPDATA%\ScreenOff\hotspot-user-off.flag`) and the hotspot **stays off**: through screen-offs, reboots and everything else. Only turning the hotspot back on manually clears the latch (the watchdog notices the state returning to On and resumes protection). Unattended drops (no user input) are still treated as "Windows killed it" and revived.

## Requirements

- Windows 10 / 11 (tested on Windows 10 19045 desktop with Intel Wi-Fi 6 AX201 + Realtek 2.5GbE, a Modern Standby machine)
- PowerShell 7 (pwsh) — required by the installer and the shortcuts
- For the hotspot watchdog: a Wi-Fi adapter that supports Wi-Fi Direct SoftAP. The watchdog drives the hotspot through the WinRT API, which is only projected in Windows PowerShell 5.1 — under pwsh it disables itself automatically (see logs) and hotspot auto-revive is off. After Modern Standby is disabled this watchdog is pure insurance and normally never fires.

## Logs & troubleshooting

- `%LOCALAPPDATA%\ScreenOff\screen-off.log` — one line per event: hardening, display-off, watchdog state, input release.
- `%LOCALAPPDATA%\ScreenOff\always-awake.log` — hourly heartbeat plus watchdog actions.
- If the hotspot still dies after screen-off, check the log for `no internet profile` / `forcing back on` lines, and confirm `powercfg /a` no longer lists S0 low power idle (i.e. you rebooted after the hardening).

## License

MIT — see [LICENSE](LICENSE).

---

# 中文说明

在 Windows 上**只关闭屏幕**——系统全速运行、后台应用照常工作、**移动热点不掉线**。

一键灭屏：屏幕黑了，其他一切照旧。不睡眠、不待机、不断网、不冻结后台。

## 为什么有这个项目

在开启了"现代待机"（S0 低电量待机）的 Windows 机器上，灭屏**并不只是**灭屏：大约 2 分钟后系统就会滑入"连接待机"。桌面进程被桌面活动中介（DAM）冻结、以太网/Wi-Fi 断链、移动热点被系统关闭——**即使你把"睡眠"设为从不、即使有程序持有防睡眠电源请求**。

本项目正是为此而生：一台 24 小时当热点服务器用的台式机，每晚灭屏几分钟后热点必然掉线。系统事件日志证实整夜都在循环"进入/退出连接待机"（Kernel-Power 506/507），每轮循环里承载网络都被 WLAN 自动配置服务停掉。

根治办法就是彻底禁用现代待机，让"灭屏"变成纯粹的字面意思：**只关显示器，其他什么都不发生**。

## 组成

| 文件 | 作用 |
|---|---|
| `screen-off.ps1` | 一键灭屏主脚本。发送 WM_SYSCOMMAND + SC_MONITORPOWER 关闭显示器；持有 SystemRequired 电源请求，系统不会因空闲进入待机；收到"真实用户输入"后自动释放（内置 5 秒静默期过滤，忽略灭屏瞬间的合成输入抖动）。内置 20 秒一次的热点看门狗（WinRT），热点被系统关掉就立即拉起。 |
| `hotspot-hardening.ps1` | 一次性管理员加固，首次灭屏时自动提权执行。**网卡层**：关闭网卡省电（PnPCapabilities、Realtek 绿色以太网/省电模式/GigaLite）、无线电源模式设为最高性能、关闭 PCIe 链路电源管理、关闭热点"无设备连接自动关闭"计时。**系统层**：**彻底禁用现代待机**（写入 `PlatformAoAcOverride=0`，重启一次后生效），此后灭屏只是黑屏。回退：删除该注册表值并重启。 |
| `always-awake.ps1` | 可选常驻守卫（放在启动文件夹）：全天候持锁防睡眠，每 60 秒巡检一次热点并自动拉起。互斥量保证单实例。 |
| `install.ps1` | 把脚本复制到 `%APPDATA%\ScreenOff`，并创建桌面快捷方式与（可选的）开机自启项。 |

## 快速开始

在 PowerShell 7（pwsh）中运行：

```powershell
pwsh -ExecutionPolicy Bypass -File .\install.ps1    # 不想开机自启就加 -NoStartup
```

然后双击桌面快捷方式灭屏；动一下鼠标或键盘即可回来。

说明：

- 首次运行会请求一次管理员权限（UAC）做加固，之后静默运行。
- 加固写入后**需要重启一次**才能生效。用 `powercfg /a` 验证：输出里不再出现"待机 (S0 低电量待机)"即成功。
- 彻底卸载：删除桌面/启动文件夹里的快捷方式和 `%APPDATA%\ScreenOff` 文件夹；要恢复现代待机，删除注册表值 `HKLM\SYSTEM\CurrentControlSet\Control\Power\PlatformAoAcOverride` 后重启。

## 工作原理

- 灭屏：`PostMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)`，外加 `SendMessageTimeout` 重试。
- 防睡眠：`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)`；`GetLastInputInfo` 报告出现"≥5 秒静默后的新输入"时释放。
- 热点看门狗：`NetworkOperatorTetheringManager.TetheringOperationalState` 探活，`StartTetheringAsync` 拉起。取不到 internet 连接配置文件时（待机唤醒窗口内的典型现象），不跳过，而是遍历**所有**连接配置文件继续探活——这是"热点死了 10 小时没人管"和"一分钟内被拉起"的分水岭。
- 禁用现代待机：`HKLM\SYSTEM\CurrentControlSet\Control\Power\PlatformAoAcOverride = 0`（DWORD）。
- **尊重手动关闭（完全粘滞）**：如果热点是在"有人正在使用电脑"时被关掉的（最近 90 秒内有键鼠输入），看门狗会视为你的主动操作——写入锁存文件（`%LOCALAPPDATA%\ScreenOff\hotspot-user-off.flag`），此后热点**一直保持关闭**：灭屏多少次、重启多少次都不会再自动打开。唯一解除方式是你手动把热点重新打开（看门狗观察到状态变回 On，即恢复自动保护）。"无人操作时热点悄悄死掉"仍会被判定为系统所杀并自动拉起。

## 运行环境

- Windows 10 / 11（实测：Windows 10 19045 台式机，Intel Wi-Fi 6 AX201 + Realtek 2.5GbE，现代待机机型）
- PowerShell 7（pwsh）——安装与快捷方式依赖它
- 热点看门狗需要一块支持 Wi-Fi Direct SoftAP 的无线网卡；看门狗走 WinRT API（仅 Windows PowerShell 5.1 提供投影），在 pwsh 下会自动停用（日志可见），热点自动复活随之关闭。禁用现代待机之后，这个看门狗只是保险，平时不会触发。

## 日志与排查

- `%LOCALAPPDATA%\ScreenOff\screen-off.log`——每个事件一行：加固、灭屏、看门狗状态、输入释放。
- `%LOCALAPPDATA%\ScreenOff\always-awake.log`——每小时心跳 + 看门狗动作。
- 如果灭屏后热点仍然掉线：查日志里的 `no internet profile` / `forcing back on` 行，并确认 `powercfg /a` 已不再列出 S0 低电量待机（即加固后已经重启过）。

## 许可

MIT——见 [LICENSE](LICENSE)。
