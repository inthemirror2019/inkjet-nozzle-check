<#
.SYNOPSIS
    喷头养护控制台（WinForms 图形界面）。

.DESCRIPTION
    零依赖，只用 PowerShell 自带的 System.Windows.Forms。
    提供手动立即打印、周期检查、状态查看和实时日志。

    设计要点：所有耗时操作（打印要等作业离开队列，可能几十秒）都放到
    独立的 powershell 子进程里执行，UI 线程只用 Timer 轮询日志文件和
    进程退出码。这样窗口永远不会卡成「未响应」，子进程出问题也不会
    连带崩掉界面。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NozzleCheckUI.ps1
    或直接双击 启动UI.cmd
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# 隐藏本进程自带的控制台窗口，只留 GUI。
# 比依赖启动器传 SW_HIDE 更可预测：无论怎么启动，控制台都会消失，
# 而 WinForms 窗口由 ShowDialog 显式显示，不受影响。
try {
    if (-not ('Win32.ConsoleWin' -as [type])) {
        Add-Type -Namespace Win32 -Name ConsoleWin -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }
    $hConsole = [Win32.ConsoleWin]::GetConsoleWindow()
    if ($hConsole -ne [IntPtr]::Zero) {
        [void] [Win32.ConsoleWin]::ShowWindow($hConsole, 0)   # 0 = SW_HIDE
    }
} catch {
    # 隐藏失败不影响功能，控制台留着就留着
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot 'Common.ps1')

$script:root      = Get-AppRoot
$script:busy      = $false
$script:proc      = $null
$script:logPath   = $null
$script:logOffset = 0
$script:jobLabel  = ''

# ============================ 界面构建 ============================

$font     = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = '喷头养护控制台'
$form.Size            = New-Object System.Drawing.Size(660, 620)
$form.StartPosition   = 'CenterScreen'
$form.Font            = $font
$form.AutoScaleMode   = 'Font'
$form.MinimumSize     = New-Object System.Drawing.Size(620, 540)

# ---- 状态区 ----
$grpState          = New-Object System.Windows.Forms.GroupBox
$grpState.Text     = ' 当前状态 '
$grpState.Location = New-Object System.Drawing.Point(12, 10)
$grpState.Size     = New-Object System.Drawing.Size(620, 148)
$grpState.Anchor   = 'Top,Left,Right'
$form.Controls.Add($grpState)

# 左列标题 + 右列值，成对生成
$labelTexts = @('打印机', '上次打印', '距上次', '下次打印', '计划任务')
$script:valLabels = @{}
$y = 24
foreach ($t in $labelTexts) {
    $lk           = New-Object System.Windows.Forms.Label
    $lk.Text      = "$t ："
    $lk.Location  = New-Object System.Drawing.Point(14, $y)
    $lk.Size      = New-Object System.Drawing.Size(74, 20)
    $lk.TextAlign = 'MiddleRight'
    $grpState.Controls.Add($lk)

    $lv           = New-Object System.Windows.Forms.Label
    $lv.Text      = '读取中…'
    $lv.Location  = New-Object System.Drawing.Point(92, $y)
    $lv.Size      = New-Object System.Drawing.Size(510, 20)
    $lv.TextAlign = 'MiddleLeft'
    $lv.AutoEllipsis = $true
    $grpState.Controls.Add($lv)

    $script:valLabels[$t] = $lv
    $y += 24
}

# ---- 操作区 ----
$grpAct          = New-Object System.Windows.Forms.GroupBox
$grpAct.Text     = ' 操作 '
$grpAct.Location = New-Object System.Drawing.Point(12, 166)
$grpAct.Size     = New-Object System.Drawing.Size(620, 116)
$grpAct.Anchor   = 'Top,Left,Right'
$form.Controls.Add($grpAct)

function New-ActButton {
    param([string] $Text, [int] $X, [int] $Y, [int] $W = 142, [int] $H = 34)
    $b          = New-Object System.Windows.Forms.Button
    $b.Text     = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size     = New-Object System.Drawing.Size($W, $H)
    $grpAct.Controls.Add($b)
    $b
}

# 主按钮：用户要的「立即执行打印检测」
$btnPrint             = New-ActButton -Text '立即打印测试页' -X 14 -Y 26 -W 176 -H 42
$btnPrint.Font        = $fontBold
$btnPrint.BackColor   = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnPrint.ForeColor   = [System.Drawing.Color]::White
$btnPrint.FlatStyle   = 'Flat'

$btnCycle   = New-ActButton -Text '按周期检查'   -X 200 -Y 26 -W 128 -H 42
$btnDry     = New-ActButton -Text '仅检查不打印' -X 336 -Y 26 -W 128 -H 42
$btnPreview = New-ActButton -Text '生成版式预览' -X 472 -Y 26 -W 130 -H 42

$chkKeep          = New-Object System.Windows.Forms.CheckBox
$chkKeep.Text     = '打印后不重置养护周期（仅测试用）'
$chkKeep.Location = New-Object System.Drawing.Point(16, 76)
$chkKeep.Size     = New-Object System.Drawing.Size(260, 24)
$grpAct.Controls.Add($chkKeep)

$btnLog          = New-Object System.Windows.Forms.Button
$btnLog.Text     = '打开日志文件'
$btnLog.Location = New-Object System.Drawing.Point(336, 74)
$btnLog.Size     = New-Object System.Drawing.Size(128, 28)
$grpAct.Controls.Add($btnLog)

$btnRefresh          = New-Object System.Windows.Forms.Button
$btnRefresh.Text     = '刷新状态'
$btnRefresh.Location = New-Object System.Drawing.Point(472, 74)
$btnRefresh.Size     = New-Object System.Drawing.Size(130, 28)
$grpAct.Controls.Add($btnRefresh)

# ---- 输出区 ----
$grpOut          = New-Object System.Windows.Forms.GroupBox
$grpOut.Text     = ' 输出 '
$grpOut.Location = New-Object System.Drawing.Point(12, 290)
$grpOut.Size     = New-Object System.Drawing.Size(620, 250)
$grpOut.Anchor   = 'Top,Bottom,Left,Right'
$form.Controls.Add($grpOut)

$txtOut            = New-Object System.Windows.Forms.TextBox
$txtOut.Multiline  = $true
$txtOut.ReadOnly   = $true
$txtOut.ScrollBars = 'Vertical'
$txtOut.Location   = New-Object System.Drawing.Point(12, 22)
$txtOut.Size       = New-Object System.Drawing.Size(596, 216)
$txtOut.Anchor     = 'Top,Bottom,Left,Right'
$txtOut.Font       = $fontMono
$txtOut.BackColor  = [System.Drawing.Color]::FromArgb(30, 30, 30)
$txtOut.ForeColor  = [System.Drawing.Color]::FromArgb(220, 220, 220)
$grpOut.Controls.Add($txtOut)

# ---- 状态栏 ----
$statusBar          = New-Object System.Windows.Forms.StatusStrip
$statusLbl          = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Text     = '就绪'
$statusBar.Items.Add($statusLbl) | Out-Null
$form.Controls.Add($statusBar)

# ============================ 逻辑 ============================

function Write-Out {
    param([string] $Text = '', [switch] $NoTime)
    # 允许输出空行（$Text 为空时不加时间戳直接换行）
    if ([string]::IsNullOrEmpty($Text)) { $txtOut.AppendText("`r`n"); return }
    $line = if ($NoTime) { $Text } else { "$(Get-Date -Format 'HH:mm:ss')  $Text" }
    $txtOut.AppendText($line + "`r`n")
}

function Set-Status {
    param([string] $Text)
    $statusLbl.Text = $Text
    $statusBar.Refresh()
}

function Get-CurrentLogPath {
    Join-Path $script:root ('logs\nozzlecheck-{0}.log' -f (Get-Date -Format 'yyyy-MM'))
}

# 以共享方式读取日志新增部分 —— 子进程正在写同一个文件，必须允许 ReadWrite 共享
function Read-LogTail {
    $path = Get-CurrentLogPath
    if ($path -ne $script:logPath) {
        $script:logPath   = $path
        $script:logOffset = 0
    }
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $fs = New-Object System.IO.FileStream($path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
        try {
            if ($script:logOffset -gt $fs.Length) { $script:logOffset = 0 }
            $fs.Seek($script:logOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $sr   = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $script:logOffset = $fs.Position
            return $text
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Update-StateDisplay {
    $cfg   = Get-AppConfig
    $state = Get-AppState

    # 打印机队列名（在线检测另开，因为要 ping，慢）
    $script:valLabels['打印机'].Text = $cfg.printerName

    if ($state.lastPrintTime) {
        try {
            $last = [datetime]::Parse($state.lastPrintTime,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind)
            $days = ((Get-Date) - $last).TotalDays
            $script:valLabels['上次打印'].Text = $last.ToString('yyyy-MM-dd HH:mm')
            $script:valLabels['距上次'].Text   = ('{0:N2} 天' -f $days)

            $next = $last.AddDays([double] $cfg.intervalDays)
            $left = ($next - (Get-Date)).TotalDays
            if ($left -le 0.1) {
                $script:valLabels['下次打印'].Text      = '已到期，下次检查时会打印'
                $script:valLabels['下次打印'].ForeColor = [System.Drawing.Color]::FromArgb(200, 90, 0)
            } else {
                $script:valLabels['下次打印'].Text      = ('{0}（还有 {1:N1} 天）' -f $next.ToString('yyyy-MM-dd HH:mm'), $left)
                $script:valLabels['下次打印'].ForeColor = [System.Drawing.SystemColors]::ControlText
            }
        } catch {
            $script:valLabels['上次打印'].Text = "解析失败：$($state.lastPrintTime)"
            $script:valLabels['距上次'].Text   = '—'
            $script:valLabels['下次打印'].Text = '—'
        }
    } else {
        $script:valLabels['上次打印'].Text      = '无记录'
        $script:valLabels['距上次'].Text        = '—'
        $script:valLabels['下次打印'].Text      = '下次检查时会立即打印一张作为基准'
        $script:valLabels['下次打印'].ForeColor = [System.Drawing.Color]::FromArgb(200, 90, 0)
    }

    # 计划任务
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'InkjetNozzleCheck-*' -ErrorAction SilentlyContinue)
        if ($tasks.Count -eq 0) {
            $script:valLabels['计划任务'].Text      = '未安装（以管理员运行 Install-Task.ps1）'
            $script:valLabels['计划任务'].ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0)
        } else {
            $parts = foreach ($t in $tasks) {
                $short = $t.TaskName -replace '^InkjetNozzleCheck-', ''
                $next  = (Get-ScheduledTaskInfo -TaskName $t.TaskName -ErrorAction SilentlyContinue).NextRunTime
                if ($next) { "$short=$($t.State) @$($next.ToString('MM-dd HH:mm'))" }
                else       { "$short=$($t.State)" }
            }
            $script:valLabels['计划任务'].Text      = ($parts -join '   ')
            $script:valLabels['计划任务'].ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
        }
    } catch {
        $script:valLabels['计划任务'].Text = '查询失败'
    }
}

function Update-PrinterDisplay {
    $cfg = Get-AppConfig
    $lbl = $script:valLabels['打印机']
    $lbl.Text      = "$($cfg.printerName)  — 检测中…"
    $lbl.ForeColor = [System.Drawing.SystemColors]::GrayText
    $form.Refresh()

    $r = Test-PrinterOnline -PrinterName $cfg.printerName -PrinterIP $cfg.printerIP
    if ($r.Online) {
        $lbl.Text      = "$($cfg.printerName)  — 在线，$($r.Reason)"
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 0)
    } else {
        $lbl.Text      = "$($cfg.printerName)  — 不可用：$($r.Reason)"
        $lbl.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0)
    }
}

function Set-Busy {
    param([bool] $On, [string] $What = '')
    $script:busy = $On
    foreach ($b in @($btnPrint, $btnCycle, $btnDry, $btnPreview, $btnRefresh)) {
        $b.Enabled = -not $On
    }
    $chkKeep.Enabled = -not $On
    if ($On) {
        $form.Cursor = [System.Windows.Forms.Cursors]::AppStarting
        Set-Status "正在执行：$What …（可能需要几十秒，请勿关闭窗口）"
    } else {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        Set-Status '就绪'
    }
}

# 把耗时任务交给独立子进程，UI 只监控
function Start-Child {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [string[]] $Arguments = @(),
        [Parameter(Mandatory)] [string] $Label
    )
    if ($script:busy) { return }

    $target = Join-Path $script:root $ScriptName
    if (-not (Test-Path -LiteralPath $target)) {
        [System.Windows.Forms.MessageBox]::Show("找不到脚本：$target", '错误',
            'OK', 'Error') | Out-Null
        return
    }

    # 从当前日志末尾开始跟踪，只显示这次产生的内容
    $script:logPath   = Get-CurrentLogPath
    $script:logOffset = if (Test-Path -LiteralPath $script:logPath) {
        (Get-Item -LiteralPath $script:logPath).Length
    } else { 0 }

    Write-Out ''  -NoTime
    Write-Out ('─' * 60) -NoTime
    Write-Out "▶ $Label"

    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$target`""
    ) + $Arguments

    $script:jobLabel = $Label
    $script:proc = Start-Process -FilePath 'powershell.exe' `
                                 -ArgumentList $argList `
                                 -WorkingDirectory $script:root `
                                 -WindowStyle Hidden `
                                 -PassThru

    Set-Busy -On $true -What $Label
    $timer.Start()
}

# 轮询：拉日志 + 检查子进程是否结束
$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 600
$timer.Add_Tick({
    $tail = Read-LogTail
    if ($tail) {
        foreach ($line in ($tail -split "`r?`n")) {
            if ($line.Trim()) { Write-Out $line -NoTime }
        }
    }

    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        $code = $script:proc.ExitCode

        # 收尾再拉一次，避免最后几行日志漏掉
        Start-Sleep -Milliseconds 200
        $tail = Read-LogTail
        if ($tail) {
            foreach ($line in ($tail -split "`r?`n")) {
                if ($line.Trim()) { Write-Out $line -NoTime }
            }
        }

        if ($code -eq 0) {
            Write-Out "✔ $($script:jobLabel) 完成（退出码 0）"
        } else {
            Write-Out "✘ $($script:jobLabel) 失败（退出码 $code）—— 详见上面的日志"
        }

        $script:proc = $null
        Set-Busy -On $false
        Update-StateDisplay
    }
})

# ---- 事件绑定 ----

$btnPrint.Add_Click({
    $cfg = Get-AppConfig
    $keep = $chkKeep.Checked
    $msg  = "即将立即打印 1 张 A4 彩色测试页，会消耗纸张和墨水。`n`n打印机：$($cfg.printerName)"
    $msg += if ($keep) { "`n养护周期：保持不变" } else { "`n养护周期：重置，从现在起重新计算 $($cfg.intervalDays) 天" }
    $msg += "`n`n继续？"

    $r = [System.Windows.Forms.MessageBox]::Show($msg, '确认打印',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # 注意：不能用 $args 做变量名，它是 PowerShell 在 scriptblock 里的自动变量
    $childArgs = @('-Yes')
    if ($keep) { $childArgs += '-KeepSchedule' }
    Start-Child -ScriptName 'Test-Run.ps1' -Arguments $childArgs -Label '立即打印测试页'
})

$btnCycle.Add_Click({
    Start-Child -ScriptName 'Invoke-NozzleCheck.ps1' `
                -Arguments @('-Trigger', 'Manual') `
                -Label '按周期检查（满 7 天才打印）'
})

$btnDry.Add_Click({
    Start-Child -ScriptName 'Invoke-NozzleCheck.ps1' `
                -Arguments @('-DryRun', '-Trigger', 'Manual') `
                -Label '仅检查不打印'
})

$btnPreview.Add_Click({
    Start-Child -ScriptName 'Preview.ps1' -Arguments @('-Open') -Label '生成版式预览'
})

$btnLog.Add_Click({
    $path = Get-CurrentLogPath
    if (Test-Path -LiteralPath $path) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$path`""
    } else {
        [System.Windows.Forms.MessageBox]::Show("本月还没有日志文件：`n$path", '提示',
            'OK', 'Information') | Out-Null
    }
})

$btnRefresh.Add_Click({
    Set-Status '刷新中…'
    Update-StateDisplay
    Update-PrinterDisplay
    Write-Out '状态已刷新'
    Set-Status '就绪'
})

$form.Add_FormClosing({
    if ($script:busy) {
        $r = [System.Windows.Forms.MessageBox]::Show(
                "「$($script:jobLabel)」还在执行中。`n`n关闭窗口不会中断它（它在独立进程里运行，会正常跑完）。`n`n确定关闭？",
                '任务进行中',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
    }
    $timer.Stop()
})

# 窗口显示后再做慢操作（ping 打印机要 1～2 秒），避免启动时白屏
$form.Add_Shown({
    Write-Out '喷头养护控制台已就绪。' -NoTime
    Write-Out ('工作目录：' + $script:root) -NoTime
    Write-Out '' -NoTime
    Update-StateDisplay
    Update-PrinterDisplay
})

[void] $form.ShowDialog()
$form.Dispose()
