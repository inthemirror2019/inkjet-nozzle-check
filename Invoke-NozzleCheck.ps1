<#
.SYNOPSIS
    喷墨打印机喷头养护 —— 周期检查并打印测试页。

.DESCRIPTION
    每次运行都会先判断距上次成功打印是否已满 config.json 里设置的打印间隔
    （intervalValue + intervalUnit，可按小时或按天）：
      · 未满   —— 记日志后退出，不打印。
      · 已满   —— 检测打印机在线后打印，成功才写入 lastPrintTime。
    只有打印成功才更新 lastPrintTime，因此打印机关机、缺纸、卡纸等失败
    都会在下一次触发（次日或下次开机）自动重试，不会漏掉一个养护周期。

.PARAMETER Force
    忽略周期判断，立即打印一次。

.PARAMETER DryRun
    只做周期判断和打印机检测，不实际打印，也不修改 state.json。

.PARAMETER Trigger
    触发来源标记，写入日志与测试页。由计划任务传入。

.EXAMPLE
    .\Invoke-NozzleCheck.ps1 -DryRun
    .\Invoke-NozzleCheck.ps1 -Force -Trigger Manual
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $DryRun,
    [ValidateSet('Daily','Boot','Manual')]
    [string] $Trigger = 'Manual'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

try {
    $cfg = Get-AppConfig
} catch {
    Write-Log "加载配置失败：$($_.Exception.Message)" 'ERROR'
    exit 1
}

Remove-OldLogs -KeepMonths $cfg.logKeepMonths

Write-Log ('=' * 62)
Write-Log "开始检查（触发方式：$Trigger$(if ($DryRun) { '，DryRun' })$(if ($Force) { '，Force' })）"

$state = Get-AppState
$now   = Get-Date

# ---------------- 周期判断 ----------------
$lastPrint = $null
if ($state.lastPrintTime) {
    try {
        $lastPrint = [datetime]::Parse(
            $state.lastPrintTime,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        Write-Log "lastPrintTime 无法解析（$($state.lastPrintTime)），按首次打印处理" 'WARN'
    }
}

$interval  = Get-PrintInterval -Config $cfg
$daysSince = $null
if ($lastPrint) {
    $elapsed   = New-TimeSpan -Start $lastPrint -End $now
    $daysSince = [math]::Round($elapsed.TotalDays, 2)
}

if (-not $lastPrint) {
    $due    = $true
    $reason = '尚无打印记录，作为基准立即打印一次'
} else {
    # 留一点容差（见 Get-IntervalTolerance），避免整点检查时差几秒就推迟一个检查周期
    $due       = $elapsed -ge ($interval.Span - (Get-IntervalTolerance -Span $interval.Span))
    $sinceText = Format-Elapsed -Span $elapsed -Unit $interval.Unit
    $reason = if ($due) { "距上次打印已 $sinceText，达到 $($interval.Text)周期" }
              else      { "距上次打印仅 $sinceText，未达 $($interval.Text)周期" }
}

Write-Log "上次打印：$(if ($lastPrint) { $lastPrint.ToString('yyyy-MM-dd HH:mm:ss') } else { '无' })"
Write-Log $reason

if ($Force -and -not $due) {
    Write-Log '已指定 -Force，忽略周期限制' 'WARN'
    $due = $true
}

if (-not $due) {
    Write-Log '本次无需打印，退出。' 'OK'
    exit 0
}

# ---------------- 打印（带重试） ----------------
$attempts = [math]::Max(1, [int]$cfg.retryCount)
$success  = $false
$lastErr  = ''

for ($i = 1; $i -le $attempts; $i++) {
    Write-Log "第 $i/$attempts 次尝试"

    $printer = Resolve-Printer -Config $cfg
    if (-not $printer) {
        $lastErr = '没有可用的打印机（打印机可能未开机）'
        Write-Log $lastErr 'WARN'
    }
    else {
        $meta = @{
            PrintTime     = $now.ToString('yyyy-MM-dd HH:mm:ss')
            LastPrintTime = if ($lastPrint) { $lastPrint.ToString('yyyy-MM-dd HH:mm') } else { '（首次打印）' }
            DaysSince     = $daysSince
            PrinterName   = $printer
            Trigger       = switch ($Trigger) {
                                'Daily'  { '定时检查（每小时）' }
                                'Boot'   { '开机后补打检查' }
                                default  { '手动执行' }
                            }
        }

        if ($DryRun) {
            Write-Log "[DryRun] 检测通过，本应打印到「$printer」，实际未发送。" 'OK'
            Write-Log '[DryRun] state.json 未被修改。' 'OK'
            exit 0
        }

        try {
            Invoke-PrintNozzlePage -PrinterName $printer `
                                   -Meta $meta `
                                   -ColorMode ([bool]$cfg.colorMode) `
                                   -PaperSize $cfg.paperSize `
                                   -WaitJobTimeoutSeconds ([int]$cfg.waitJobTimeoutSeconds)
            $success = $true
            break
        } catch {
            $lastErr = $_.Exception.Message
            Write-Log "打印失败：$lastErr" 'ERROR'
        }
    }

    if ($i -lt $attempts) {
        $wait = [int]$cfg.retryIntervalMinutes
        Write-Log "等待 $wait 分钟后重试…"
        Start-Sleep -Seconds ($wait * 60)
    }
}

# ---------------- 更新状态 ----------------
$state.lastAttemptTime = $now.ToString('o')

if ($success) {
    # 关键：只有打印成功才推进 lastPrintTime
    $state.lastPrintTime = $now.ToString('o')
    $state.successCount  = [int]$state.successCount + 1
    $state.lastError     = ''
    Save-AppState $state
    Write-Log "打印成功，下次养护打印时间：$($now.Add($interval.Span).ToString('yyyy-MM-dd HH:mm')) 之后" 'OK'
    exit 0
} else {
    $state.failCount = [int]$state.failCount + 1
    $state.lastError = $lastErr
    Save-AppState $state
    Write-Log "本次未能完成打印（lastPrintTime 未推进，下次触发会自动重试）：$lastErr" 'ERROR'
    exit 1
}
