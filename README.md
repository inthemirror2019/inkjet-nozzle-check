# 喷墨打印机喷头养护 / Inkjet Nozzle Check

[简体中文](#简体中文) · [English](#english)

零依赖的 Windows 定时养护工具：每周自动打印一张四色测试页，防止喷墨打印机长期闲置导致喷头堵塞。整机不需要 24 小时开机——脚本记录上次成功打印时间，开机后发现超期就立刻补打。

A zero-dependency Windows utility that prints one four-colour test page per week to keep inkjet nozzles from clogging. The machine does **not** need to stay powered on: the script remembers the last successful print and catches up as soon as the PC comes back online.

---

## 简体中文

### 为什么需要它

喷墨打印机长期不用，墨水会在喷嘴处干涸结块，轻则断线偏色，重则需要反复清洗甚至更换打印头。厂商给出的建议是**定期少量打印**——每周一张覆盖全部墨水通道的页面，比堵塞后猛洗几次要划算得多。

难点在于：家用电脑不是服务器，不会一直开着。固定"每周三 10 点打印"这种计划任务，一旦那天没开机就整周跳过。所以本工具的调度逻辑是**按间隔而非按日期**：

- 每天检查一次 + 每次登录后检查一次
- 距上次**成功**打印满 7 天才打印，未满则跳过（不重复打印）
- 电脑关机错过的检查，会在下次开机时补上（超期立刻打印）
- 打印失败（缺纸、卡纸、打印机离线）**不会**推进计时，下次触发继续尝试

### 特性

- **零依赖**：只用 Windows 自带的 PowerShell 5.1 + .NET GDI+，不需要 Python / Pillow / 浏览器 / Office
- **覆盖全部墨水通道**：单页含纯 K/C/M/Y 色块、复合 R/G/B、四条渐变条、细线断线检测栅格、黑色文字样张
- **真正确认打印完成**：不只是提交任务，而是轮询打印队列直到作业离开队列，遇到 `Error / Blocked / Offline / PaperOut` 直接报错
- **打印机在线检测**：先 ping IP（能识别整机断电），再查 `WorkOffline` / `PrinterStatus` / `DetectedErrorState`（缺纸、卡纸、机盖未关等）
- **图形界面**：查看状态、手动立即打印、生成预览、查看日志，长任务在子进程里跑，界面不会卡死
- **桌面快捷方式**：带手绘的四色墨条图标（16/32/48/64/128 五种尺寸）
- **幂等**：重复安装计划任务、重复触发都安全

### 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10 / 11 |
| PowerShell | 5.1（系统自带即可） |
| 打印机 | 任意已安装驱动的彩色喷墨打印机 |
| 权限 | 仅注册/卸载计划任务需要管理员 |
| 纸张 | A4（可在配置里改） |

开发验证机型为 EPSON L4160（网络连接），但脚本不含任何厂商专有逻辑，任何 Windows 打印队列都能用。

### 快速开始

**1. 克隆并复制配置**

```powershell
git clone https://github.com/inthemirror2019/inkjet-nozzle-check.git
cd inkjet-nozzle-check
Copy-Item config.example.json config.json
```

**2. 查找你的打印机队列名**

```powershell
Get-Printer | Select-Object Name, PortName, PrinterStatus
```

把输出里的 `Name` 原样填进 `config.json` 的 `printerName`。

**3. 填写配置**

```jsonc
{
  "printerName": "EPSON XXXX Series",   // 必填：上一步查到的队列名
  "printerIP": "192.168.1.100",         // 网络打印机填 IP，USB 打印机留空字符串
  "intervalDays": 7,
  "dailyCheckTime": "10:00"
}
```

**4. 先预览，别急着打印**

```powershell
powershell -ExecutionPolicy Bypass -File .\Preview.ps1
```

生成 `preview.png`，确认版式正常再往下走。

**5. 试打一张**

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Run.ps1
```

加 `-KeepSchedule` 可以打印但不推进计时（不消耗本周的养护周期）。

**6. 注册计划任务（需要管理员）**

在管理员 PowerShell 里执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

会注册两个任务：每天定时检查一次，以及每次登录后延迟几分钟检查一次。

**7. 创建桌面快捷方式（可选）**

```powershell
powershell -ExecutionPolicy Bypass -File .\New-Shortcut.ps1
```

桌面会出现「喷头养护」图标，双击打开图形界面。加 `-AlsoStartMenu` 同时写入开始菜单，加 `-Remove` 删除。

### 图形界面

双击桌面快捷方式，或直接运行 `启动UI.vbs`：

```
┌─ 喷头养护控制台 ─────────────────────────┐
│  打印机 : EPSON XXXX Series      ● 在线   │
│  上次打印: 2026-08-31 23:08              │
│  距今    : 0.0 天 / 间隔 7 天            │
│  下次到期: 2026-09-07                    │
├──────────────────────────────────────────┤
│ [立即打印测试页] [检查一次] [生成预览]    │
│ [打开日志] [打开目录] [刷新]              │
├──────────────────────────────────────────┤
│ 输出:                                     │
│ 23:08:15  正在解析打印机...               │
│ 23:08:17  打印作业已完成并离开队列        │
└──────────────────────────────────────────┘
```

所有耗时操作都在独立子进程里执行，界面通过轮询日志文件显示进度，因此**不会假死**，而且窗口里看到的输出和日志文件完全一致。

### 测试页内容

单页 A4，自上而下六个区域，垂直覆盖约 98%：

| 区域 | 内容 | 检测目标 |
|---|---|---|
| 标题 | 打印时间、打印机名、周期信息 | 存档追溯 |
| ① | 纯 K / C / M / Y 色块 | 单通道是否出墨 |
| ② | 复合 R / G / B | 双通道混色是否正常 |
| ③ | 四条 20 级渐变条 | 淡墨区域断墨、阶调跳变 |
| ④ | 细线断线检测栅格 | 单个喷嘴堵塞（断线） |
| ⑤ | 黑色文字样张 | 文字边缘、K 通道锐度 |

### 文件说明

| 文件 | 作用 |
|---|---|
| `config.example.json` | 配置模板，复制为 `config.json` 后修改 |
| `Common.ps1` | 公共函数：配置、状态、日志、在线检测、实际打印 |
| `NozzleCheckPage.ps1` | 测试页绘制（预览与打印共用同一套绘图代码） |
| `Invoke-NozzleCheck.ps1` | 主入口，计划任务调用它；`-Force` / `-DryRun` / `-Trigger` |
| `Preview.ps1` | 生成 `preview.png` |
| `Test-Run.ps1` | 手动试打；`-Yes` 跳过确认，`-KeepSchedule` 不推进计时 |
| `Install-Task.ps1` | 注册两个计划任务（需管理员） |
| `Uninstall-Task.ps1` | 卸载计划任务；`-Purge` 同时清除状态与日志 |
| `NozzleCheckUI.ps1` | WinForms 图形界面 |
| `New-Shortcut.ps1` | 生成图标与桌面快捷方式；`-Remove` / `-AlsoStartMenu` |
| `启动UI.vbs` | 无闪窗启动界面（快捷方式的实际目标） |
| `启动UI.cmd` | 备用启动器（会闪一下控制台） |
| `state.json` | 运行时生成：上次打印时间、成功/失败计数 |
| `logs/` | 按月分文件的日志，默认保留 6 个月 |

### 配置项

| 键 | 默认值 | 说明 |
|---|---|---|
| `printerName` | — | 打印机队列名，必填 |
| `fallbackPrinterName` | `""` | 备用队列名，主队列找不到时尝试 |
| `printerIP` | `""` | 网络打印机 IP，用于 ping 检测；USB 留空 |
| `intervalDays` | `7` | 打印间隔天数 |
| `dailyCheckTime` | `"10:00"` | 每日检查时刻 |
| `bootDelayMinutes` | `3` | 登录后延迟几分钟再检查（等网络就绪） |
| `retryCount` | `3` | 单次检查内的重试次数 |
| `retryIntervalMinutes` | `5` | 重试间隔 |
| `colorMode` | `true` | 彩色打印 |
| `paperSize` | `"A4"` | 纸张 |
| `waitJobTimeoutSeconds` | `180` | 等待打印作业离开队列的超时 |
| `logKeepMonths` | `6` | 日志保留月数 |

### 调度机制

```
每日触发 (10:00) ─┐
                  ├→ Invoke-NozzleCheck.ps1 ─→ 读 state.json
登录触发 (+3min) ─┘                              │
                                                 ↓
                                    距上次成功打印 ≥ 7 天？
                                       ├─ 否 → 跳过，退出
                                       └─ 是 → 检测打印机在线
                                                 ├─ 离线 → 记日志，不推进计时
                                                 └─ 在线 → 打印 → 确认离开队列
                                                              ├─ 失败 → 重试，不推进计时
                                                              └─ 成功 → 更新 lastPrintTime
```

两个关键设计：

- **只有成功打印才推进 `lastPrintTime`**。缺纸、卡纸、打印机断电这些失败都不消耗养护周期，下次触发自然重试。
- **0.1 天容差**：判断条件是 `daysSince >= intervalDays - 0.1`。否则"上次 10:07 打印，今天 10:07 检查 = 6.9999 天"会把打印推到第 8 天。

### 常见问题

| 现象 | 原因与处理 |
|---|---|
| 提示"配置文件是模板" | 复制了 `config.example.json` 但还没填 `printerName` |
| 找不到打印机 | 用 `Get-Printer` 核对队列名，注意空格和括号要完全一致 |
| 一直报离线 | 检查 `printerIP`；USB 打印机应把该项留空，否则 ping 永远失败 |
| 中文变成乱码 | `.ps1` 文件丢了 UTF-8 BOM，见下方「编码注意」 |
| 双击 `.vbs` 没反应 | `.vbs` 被改成非 ASCII 内容了，见下方「编码注意」 |
| 计划任务不执行 | 任务计划程序里确认任务存在且"运行账户"是当前用户；`Install-Task.ps1` 必须用管理员运行 |
| 打印了但没记录 | 作业未在超时内离开队列，调大 `waitJobTimeoutSeconds` |
| 想立刻打印一次 | `Test-Run.ps1`，或界面上的「立即打印测试页」 |

### 编码注意（改代码前必读）

这两条踩过坑，改文件时务必注意：

- **`.ps1` 必须带 UTF-8 BOM**。PowerShell 5.1 读到无 BOM 的 UTF-8 会按 GBK 解码，所有中文变乱码。多数编辑器保存时会保留 BOM，但某些工具（包括一些自动化写文件的工具）会丢掉，改完记得确认前三字节是 `EF BB BF`。
- **`.vbs` 内容必须是纯 ASCII**。VBScript 把 `.vbs` 按 ANSI/GBK 解析，UTF-8 中文（**哪怕只在注释里**）会被错误解码、破坏行结构，脚本静默失败——双击毫无反应、无报错。文件名可以是中文，内容不行。

### 卸载

```powershell
# 管理员权限，删除计划任务，保留状态和日志
powershell -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1

# 同时清除 state.json 和 logs/
powershell -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1 -Purge

# 删除桌面快捷方式
powershell -ExecutionPolicy Bypass -File .\New-Shortcut.ps1 -Remove
```

---

## English

### Why

An idle inkjet printer dries ink inside the nozzles. Mild clogging shows up as banding and colour shifts; severe clogging means repeated head-cleaning cycles (which waste far more ink than printing would) or a replacement print head. The standard advice is to **print a little, regularly** — one page covering every ink channel per week.

The catch: a home PC isn't a server. A plain "print every Wednesday at 10:00" scheduled task silently skips the entire week if the machine happens to be off that day. So this tool schedules by **elapsed interval, not by date**:

- Checks once a day, plus once shortly after every logon
- Prints only when 7 days have passed since the last **successful** print
- Missed checks are caught up on the next boot — overdue means print now
- Failures (out of paper, jam, printer offline) do **not** advance the clock, so the next trigger retries

### Features

- **Zero dependencies** — Windows' built-in PowerShell 5.1 + .NET GDI+ only. No Python, no Pillow, no browser, no Office.
- **Covers every ink channel** — one page with pure K/C/M/Y patches, composite R/G/B, four gradient ramps, a fine-line nozzle-break grid, and black text samples.
- **Confirms the print actually completed** — not just "submitted": polls the print queue until the job leaves it, and throws on `Error / Blocked / Offline / PaperOut`.
- **Printer readiness detection** — pings the IP first (catches a powered-off printer), then checks `WorkOffline`, `PrinterStatus`, and `DetectedErrorState` (out of paper, jam, cover open…).
- **GUI** — view status, print now, generate a preview, open logs. Long operations run in child processes, so the window never freezes.
- **Desktop shortcut** — with a hand-drawn four-ink-bar icon (16/32/48/64/128 px).
- **Idempotent** — re-installing the tasks or double-triggering is harmless.

### Requirements

| Item | Requirement |
|---|---|
| OS | Windows 10 / 11 |
| PowerShell | 5.1 (ships with Windows) |
| Printer | Any colour inkjet with a working driver |
| Privileges | Administrator only for installing/removing the scheduled tasks |
| Paper | A4 (configurable) |

Developed against an EPSON L4160 over the network, but there is no vendor-specific logic — any Windows print queue works.

### Quick start

**1. Clone and create your config**

```powershell
git clone https://github.com/inthemirror2019/inkjet-nozzle-check.git
cd inkjet-nozzle-check
Copy-Item config.example.json config.json
```

**2. Find your printer's queue name**

```powershell
Get-Printer | Select-Object Name, PortName, PrinterStatus
```

Copy the `Name` value verbatim into `printerName` in `config.json`.

**3. Fill in the config**

```jsonc
{
  "printerName": "EPSON XXXX Series",   // required: the queue name from step 2
  "printerIP": "192.168.1.100",         // network printers: the IP. USB: leave empty
  "intervalDays": 7,
  "dailyCheckTime": "10:00"
}
```

**4. Preview before printing**

```powershell
powershell -ExecutionPolicy Bypass -File .\Preview.ps1
```

Writes `preview.png`. Check the layout before spending ink.

**5. Print one test page**

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Run.ps1
```

Add `-KeepSchedule` to print without advancing the clock (doesn't consume this week's cycle).

**6. Install the scheduled tasks (needs Administrator)**

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

Registers two tasks: a daily check, and a check a few minutes after each logon.

**7. Create a desktop shortcut (optional)**

```powershell
powershell -ExecutionPolicy Bypass -File .\New-Shortcut.ps1
```

Use `-AlsoStartMenu` to add a Start Menu entry, `-Remove` to delete both.

### The test page

One A4 page, six bands top to bottom, ~98% vertical coverage:

| Band | Content | What it reveals |
|---|---|---|
| Header | Timestamp, printer name, cycle info | Traceability |
| ① | Pure K / C / M / Y patches | Whether each channel fires at all |
| ② | Composite R / G / B | Two-channel mixing |
| ③ | Four 20-step gradient ramps | Dropout in light tones, tonal jumps |
| ④ | Fine-line nozzle-break grid | Individual clogged nozzles |
| ⑤ | Black text samples | Edge quality, K-channel sharpness |

### Files

| File | Purpose |
|---|---|
| `config.example.json` | Config template — copy to `config.json` and edit |
| `Common.ps1` | Shared helpers: config, state, logging, readiness, printing |
| `NozzleCheckPage.ps1` | Page drawing (shared by preview and print) |
| `Invoke-NozzleCheck.ps1` | Main entry point used by the scheduled tasks; `-Force` / `-DryRun` / `-Trigger` |
| `Preview.ps1` | Writes `preview.png` |
| `Test-Run.ps1` | Manual test print; `-Yes`, `-KeepSchedule` |
| `Install-Task.ps1` | Registers the two scheduled tasks (Administrator) |
| `Uninstall-Task.ps1` | Removes them; `-Purge` also clears state and logs |
| `NozzleCheckUI.ps1` | WinForms GUI |
| `New-Shortcut.ps1` | Builds the icon and shortcut; `-Remove`, `-AlsoStartMenu` |
| `启动UI.vbs` | Flash-free launcher (the shortcut's real target) |
| `启动UI.cmd` | Fallback launcher (briefly flashes a console) |
| `state.json` | Generated: last print time, success/failure counts |
| `logs/` | Monthly log files, kept 6 months by default |

### Configuration

| Key | Default | Meaning |
|---|---|---|
| `printerName` | — | Print queue name. Required. |
| `fallbackPrinterName` | `""` | Alternate queue, tried if the primary is missing |
| `printerIP` | `""` | Network printer IP, used for the ping check. Empty for USB. |
| `intervalDays` | `7` | Days between prints |
| `dailyCheckTime` | `"10:00"` | Daily check time |
| `bootDelayMinutes` | `3` | Delay after logon before checking (lets the network settle) |
| `retryCount` | `3` | Retries within one check |
| `retryIntervalMinutes` | `5` | Delay between retries |
| `colorMode` | `true` | Print in colour |
| `paperSize` | `"A4"` | Paper size |
| `waitJobTimeoutSeconds` | `180` | Timeout waiting for the job to leave the queue |
| `logKeepMonths` | `6` | Months of logs to keep |

### How scheduling works

```
Daily trigger (10:00) ─┐
                       ├→ Invoke-NozzleCheck.ps1 ─→ read state.json
Logon trigger (+3min) ─┘                              │
                                                      ↓
                                    ≥ 7 days since last success?
                                       ├─ no  → skip, exit
                                       └─ yes → check printer readiness
                                                 ├─ offline → log, clock NOT advanced
                                                 └─ ready   → print → confirm queue drained
                                                                ├─ failed  → retry, clock NOT advanced
                                                                └─ success → update lastPrintTime
```

Two deliberate choices:

- **Only a successful print advances `lastPrintTime`.** Out of paper, a jam, or a powered-off printer never consumes a maintenance cycle — the next trigger just retries.
- **0.1-day tolerance**: the test is `daysSince >= intervalDays - 0.1`. Without it, "printed at 10:07, checked today at 10:07 = 6.9999 days" would push the print to day 8.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "config is still a template" | You copied `config.example.json` but haven't set `printerName` |
| Printer not found | Verify with `Get-Printer`; spaces and parentheses must match exactly |
| Always reports offline | Check `printerIP`; for USB printers leave it empty or the ping always fails |
| Chinese text is mojibake | A `.ps1` lost its UTF-8 BOM — see Encoding notes |
| Double-clicking the `.vbs` does nothing | The `.vbs` contains non-ASCII bytes — see Encoding notes |
| Tasks never run | Check Task Scheduler: task exists and runs as the current user; `Install-Task.ps1` must run as Administrator |
| Printed but not recorded | The job didn't leave the queue within the timeout — raise `waitJobTimeoutSeconds` |
| Want to print right now | `Test-Run.ps1`, or the "print now" button in the GUI |

### Encoding notes (read before editing)

Two hard-won constraints:

- **`.ps1` files need a UTF-8 BOM.** PowerShell 5.1 decodes BOM-less UTF-8 as the system ANSI codepage, turning all non-ASCII text into mojibake. Most editors preserve the BOM, but some automated file writers strip it — verify the first three bytes are `EF BB BF`.
- **`.vbs` content must be pure ASCII.** VBScript parses `.vbs` as ANSI, so UTF-8 non-ASCII characters — **even inside comments** — get mis-decoded, break the line structure, and make the script fail *silently*: double-click does nothing, no error. The filename may be non-ASCII; the contents may not.

### Uninstall

```powershell
# As Administrator. Removes the tasks, keeps state and logs.
powershell -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1

# Also delete state.json and logs/
powershell -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1 -Purge

# Remove the desktop shortcut
powershell -ExecutionPolicy Bypass -File .\New-Shortcut.ps1 -Remove
```

---

## License

MIT — see [LICENSE](LICENSE).
