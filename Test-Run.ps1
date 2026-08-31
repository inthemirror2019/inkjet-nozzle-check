<#
.SYNOPSIS
    立即实打一张喷头养护测试页（忽略 7 天间隔），用于验证。

.DESCRIPTION
    这会真的走纸、真的耗墨。
    默认需要确认；加 -Yes 可跳过确认（用于自动化）。

    注意：验证打印会把 lastPrintTime 更新为当前时间，
    也就是周期从这一刻重新开始计算。如果不想影响周期，加 -KeepSchedule。

.EXAMPLE
    .\Test-Run.ps1
    .\Test-Run.ps1 -Yes
    .\Test-Run.ps1 -KeepSchedule      # 打印但不影响原有周期
#>

[CmdletBinding()]
param(
    # 跳过交互确认
    [switch] $Yes,

    # 打印后恢复原来的 lastPrintTime，不影响既有周期节奏
    [switch] $KeepSchedule
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$cfg  = Get-AppConfig
$root = Get-AppRoot

Write-Host ''
Write-Host '=== 喷头养护测试页 - 实打验证 ===' -ForegroundColor Cyan
Write-Host ''

# ---- 打印机状态 ----
$printer = Resolve-Printer -Config $cfg
if (-not $printer) {
    Write-Host '打印机不可用，无法打印。请检查：' -ForegroundColor Red
    Write-Host '  1. 打印机是否开机'
    Write-Host '  2. 是否与电脑在同一网络'
    Write-Host "  3. IP 是否仍是 $($cfg.printerIP)"
    Write-Host '  4. 是否缺纸 / 卡纸 / 机盖未关'
    exit 1
}

Write-Host "打印机   : $printer" -ForegroundColor Green
Write-Host "纸张     : $($cfg.paperSize)  彩色: $(if ($cfg.colorMode) { '是' } else { '否' })"

$state    = Get-AppState
$oldStamp = $state.lastPrintTime
if ($oldStamp) {
    Write-Host "上次打印 : $oldStamp"
} else {
    Write-Host '上次打印 : 无记录'
}
Write-Host ''

# ---- 确认 ----
if (-not $Yes) {
    Write-Host '即将打印 1 张 A4 彩色测试页（会消耗纸张和墨水）。' -ForegroundColor Yellow
    $answer = Read-Host '继续？输入 y 确认，其它任意键取消'
    if ($answer -notmatch '^[yY]') {
        Write-Host '已取消。' -ForegroundColor DarkGray
        exit 0
    }
    Write-Host ''
}

# ---- 打印 ----
Write-Log -Message '手动验证打印开始' -Level INFO

$meta = @{
    Trigger   = 'Manual-Test'
    DaysSince = if ($oldStamp) {
        try {
            $last = [datetime]::Parse($oldStamp, [System.Globalization.CultureInfo]::InvariantCulture,
                                      [System.Globalization.DateTimeStyles]::RoundtripKind)
            [math]::Round(((Get-Date) - $last).TotalDays, 2)
        } catch { $null }
    } else { $null }
    LastPrint = $oldStamp
}

try {
    Invoke-PrintNozzlePage `
        -PrinterName          $printer `
        -ColorMode            ([bool] $cfg.colorMode) `
        -PaperSize            $cfg.paperSize `
        -WaitJobTimeoutSeconds ([int] $cfg.waitJobTimeoutSeconds) `
        -Meta                 $meta

    $now = Get-Date

    if ($KeepSchedule) {
        Write-Host ''
        Write-Host '[OK] 打印成功。已保留原有周期（lastPrintTime 未改动）。' -ForegroundColor Green
        Write-Log -Message '手动验证打印成功（未更新周期）' -Level OK
    } else {
        $state.lastPrintTime = $now.ToString('o')
        if (-not $state.successCount) { $state.successCount = 0 }
        $state.successCount = [int] $state.successCount + 1
        $state.lastError    = $null
        Save-AppState -State $state

        Write-Host ''
        Write-Host '[OK] 打印成功。' -ForegroundColor Green
        Write-Host "周期已重置，下次自动打印约在：$($now.AddDays($cfg.intervalDays).ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
        Write-Log -Message '手动验证打印成功，周期已重置' -Level OK
    }

    Write-Host ''
    Write-Host '请检查打印出来的纸张：' -ForegroundColor Cyan
    Write-Host '  - 四个纯色块（黑/青/洋红/黄）是否均匀无白条'
    Write-Host '  - 细线网格是否连续，有断线说明对应颜色喷头堵塞'
    Write-Host '  - 渐变条是否平滑过渡'
    Write-Host '  - 有问题就在打印机维护里执行「喷头清洗」'
    Write-Host ''
    exit 0

} catch {
    Write-Host ''
    Write-Host "[ERROR] 打印失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Log -Message "手动验证打印失败：$($_.Exception.Message)" -Level ERROR
    exit 1
}
