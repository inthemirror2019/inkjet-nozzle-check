<#
.SYNOPSIS
    把喷头养护测试页导出为 PNG 图片，用于在实打之前确认版式。

.DESCRIPTION
    与实际打印调用同一个 Draw-NozzleCheckPage 函数，并复用真实打印机
    上报的可打印区域尺寸，因此预览即所打。不会向打印机发送任何作业。

.PARAMETER Dpi
    输出图片的分辨率，默认 200。

.PARAMETER OutFile
    输出路径，默认脚本目录下的 preview.png。

.PARAMETER Open
    生成后用系统默认程序打开图片。
#>
[CmdletBinding()]
param(
    [int]    $Dpi = 200,
    [string] $OutFile,
    [switch] $Open
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'NozzleCheckPage.ps1')

$cfg = Get-AppConfig
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'preview.png' }

# ---- 取真实打印机的可打印区域，取不到就用 A4 默认值 ----
$w100 = 803.0; $h100 = 1146.0; $areaFrom = 'A4 默认值'
try {
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $doc.PrinterSettings.PrinterName = $cfg.printerName
    if ($doc.PrinterSettings.IsValid) {
        $a4 = $doc.PrinterSettings.PaperSizes | Where-Object { $_.Kind -eq $cfg.paperSize } | Select-Object -First 1
        if ($a4) { $doc.DefaultPageSettings.PaperSize = $a4 }
        $area = $doc.DefaultPageSettings.PrintableArea
        if ($area.Width -gt 0 -and $area.Height -gt 0) {
            $w100 = $area.Width; $h100 = $area.Height
            $areaFrom = "打印机 $($cfg.printerName) 上报值"
        }
    }
    $doc.Dispose()
} catch {
    Write-Host "读取打印机可打印区域失败，改用 A4 默认值：$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "可打印区域：$([math]::Round($w100/100,2)) x $([math]::Round($h100/100,2)) 英寸（来源：$areaFrom）"

$pxW = [int][math]::Round($w100 * $Dpi / 100.0)
$pxH = [int][math]::Round($h100 * $Dpi / 100.0)

$bmp = New-Object System.Drawing.Bitmap($pxW, $pxH)
# 关键：把位图分辨率设为 100，让 1 个绘图单位 = 1/100 英寸，
# 同时使 Point 单位的字体按与打印机一致的比例渲染。
$bmp.SetResolution(100, 100)

$g = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.Clear([System.Drawing.Color]::White)
    $g.ScaleTransform($Dpi / 100.0, $Dpi / 100.0)

    $state     = Get-AppState
    $lastPrint = if ($state.lastPrintTime) {
                     try { [datetime]::Parse($state.lastPrintTime,
                           [System.Globalization.CultureInfo]::InvariantCulture,
                           [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $null }
                 } else { $null }

    $meta = @{
        PrintTime     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        LastPrintTime = if ($lastPrint) { $lastPrint.ToString('yyyy-MM-dd HH:mm') } else { '（首次打印）' }
        DaysSince     = if ($lastPrint) { [math]::Round((New-TimeSpan -Start $lastPrint -End (Get-Date)).TotalDays, 2) } else { $null }
        PrinterName   = $cfg.printerName
        Trigger       = '预览（未打印）'
    }

    Draw-NozzleCheckPage -Graphics $g -Width $w100 -Height $h100 -Meta $meta
} finally {
    $g.Dispose()
}

# 写入正确的 DPI 元数据，方便看图软件按实际尺寸显示
$bmp.SetResolution($Dpi, $Dpi)
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

Write-Host "预览已生成：$OutFile （${pxW}x${pxH} px @ ${Dpi}dpi）" -ForegroundColor Green
if ($Open) { Start-Process $OutFile }
