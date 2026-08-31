# NozzleCheckPage.ps1
# 喷头养护测试页绘图模块。
# 被 Invoke-NozzleCheck.ps1（打印）和 Preview.ps1（导出 PNG）共用，
# 保证预览版式与实际打印完全一致。
#
# 坐标单位统一为 1/100 英寸（GDI+ 的 Display 单位，打印机 Graphics 的默认单位）。
# A4 全幅 827 x 1169，可打印区域约 803 x 1146。

Add-Type -AssemblyName System.Drawing

# ---- 四色原色的 sRGB 近似值 ----
# 用标准 CMYK 原色对应的 sRGB 值，让驱动尽可能只驱动单一色通道出墨，
# 这样某个通道堵了能在对应色块上直接看出来。
function Get-InkColors {
    @{
        K = [System.Drawing.Color]::FromArgb(255,   0,   0,   0)   # 黑
        C = [System.Drawing.Color]::FromArgb(255,   0, 174, 239)   # 青
        M = [System.Drawing.Color]::FromArgb(255, 236,   0, 140)   # 洋红
        Y = [System.Drawing.Color]::FromArgb(255, 255, 241,   0)   # 黄
        R = [System.Drawing.Color]::FromArgb(255, 237,  28,  36)   # 红 = M+Y
        G = [System.Drawing.Color]::FromArgb(255,   0, 166,  81)   # 绿 = C+Y
        B = [System.Drawing.Color]::FromArgb(255,  46,  49, 146)   # 蓝 = C+M
    }
}

function New-Font {
    param([string]$Name = 'Microsoft YaHei', [single]$Size, [string]$Style = 'Regular')
    $s = [System.Drawing.FontStyle]::$Style
    try   { New-Object System.Drawing.Font($Name, $Size, $s, [System.Drawing.GraphicsUnit]::Point) }
    catch { New-Object System.Drawing.Font('Arial', $Size, $s, [System.Drawing.GraphicsUnit]::Point) }
}

<#
.SYNOPSIS
    在指定 Graphics 上绘制一整页喷头养护测试图。
.PARAMETER Graphics
    目标 Graphics，PageUnit 须为 Display（1/100 英寸）。
.PARAMETER Width
    画布可用宽度（1/100 英寸）。
.PARAMETER Height
    画布可用高度（1/100 英寸）。
.PARAMETER Meta
    哈希表，含 PrintTime / LastPrintTime / DaysSince / PrinterName / Trigger。
#>
function Draw-NozzleCheckPage {
    param(
        [Parameter(Mandatory)] [System.Drawing.Graphics] $Graphics,
        [Parameter(Mandatory)] [single] $Width,
        [Parameter(Mandatory)] [single] $Height,
        [hashtable] $Meta = @{}
    )

    $g   = $Graphics
    $ink = Get-InkColors

    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    # ---- 通用画笔 / 字体 ----
    $black      = New-Object System.Drawing.SolidBrush($ink.K)
    $penFrame   = New-Object System.Drawing.Pen($ink.K, 2)
    $penRule    = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,120,120,120), 1)
    $fTitle     = New-Font -Size 15 -Style Bold
    $fMeta      = New-Font -Size 8
    $fSection   = New-Font -Size 10 -Style Bold
    $fLabel     = New-Font -Size 8 -Style Bold
    $fSmall     = New-Font -Size 7
    $fBody      = New-Font -Size 10
    $fMono      = New-Font -Name 'Consolas' -Size 9

    $center = New-Object System.Drawing.StringFormat
    $center.Alignment     = [System.Drawing.StringAlignment]::Center
    $center.LineAlignment = [System.Drawing.StringAlignment]::Center

    $pad = 24.0
    $x0  = $pad
    $x1  = $Width - $pad
    $innerW = $x1 - $x0

    # 外框
    $g.DrawRectangle($penFrame, $x0, $pad, $innerW, $Height - 2 * $pad)

    $x0 += 14; $x1 -= 14; $innerW = $x1 - $x0
    $y = $pad + 16

    # ======================= 标题区 =======================
    $g.DrawString('喷墨打印机 喷头养护测试页', $fTitle, $black, $x0, $y)
    $y += 30

    $printTime = if ($Meta.PrintTime)     { $Meta.PrintTime }     else { (Get-Date) }
    $lastText  = if ($Meta.LastPrintTime) { $Meta.LastPrintTime } else { '（首次打印）' }
    $daysText  = if ($null -ne $Meta.DaysSince) { "$($Meta.DaysSince) 天" } else { '—' }

    $metaLines = @(
        "打印时间：$printTime      距上次打印：$daysText      上次打印：$lastText",
        "打印机：$($Meta.PrinterName)      触发方式：$($Meta.Trigger)"
    )
    foreach ($line in $metaLines) {
        $g.DrawString($line, $fMeta, $black, $x0, $y)
        $y += 15
    }
    $y += 6
    $g.DrawLine($penRule, $x0, $y, $x1, $y)
    $y += 14

    # ======================= ① 纯色块 =======================
    $g.DrawString('① 纯色块 — 单通道出墨检测（任一色块发白/缺失即该通道堵塞）', $fSection, $black, $x0, $y)
    $y += 22

    $pureKeys = @('K','C','M','Y')
    $pureName = @{ K = 'K 黑'; C = 'C 青'; M = 'M 洋红'; Y = 'Y 黄' }
    $gap      = 12.0
    $bw       = ($innerW - $gap * ($pureKeys.Count - 1)) / $pureKeys.Count
    $bh       = 104.0

    for ($i = 0; $i -lt $pureKeys.Count; $i++) {
        $k  = $pureKeys[$i]
        $bx = $x0 + $i * ($bw + $gap)
        $br = New-Object System.Drawing.SolidBrush($ink[$k])
        $g.FillRectangle($br, $bx, $y, $bw, $bh)
        $br.Dispose()
        $g.DrawRectangle($penRule, $bx, $y, $bw, $bh)
        $rect = New-Object System.Drawing.RectangleF($bx, ($y + $bh + 2), $bw, 16)
        $g.DrawString($pureName[$k], $fLabel, $black, $rect, $center)
    }
    $y += $bh + 26

    # ======================= ② 复合色块 =======================
    $g.DrawString('② 复合色块 — 混色检测（明显偏色说明某个色通道出墨不足）', $fSection, $black, $x0, $y)
    $y += 22

    $mixKeys = @('R','G','B')
    $mixName = @{ R = 'R 红 (M+Y)'; G = 'G 绿 (C+Y)'; B = 'B 蓝 (C+M)' }
    $bw = ($innerW - $gap * ($mixKeys.Count - 1)) / $mixKeys.Count
    $bh = 84.0

    for ($i = 0; $i -lt $mixKeys.Count; $i++) {
        $k  = $mixKeys[$i]
        $bx = $x0 + $i * ($bw + $gap)
        $br = New-Object System.Drawing.SolidBrush($ink[$k])
        $g.FillRectangle($br, $bx, $y, $bw, $bh)
        $br.Dispose()
        $g.DrawRectangle($penRule, $bx, $y, $bw, $bh)
        $rect = New-Object System.Drawing.RectangleF($bx, ($y + $bh + 2), $bw, 16)
        $g.DrawString($mixName[$k], $fLabel, $black, $rect, $center)
    }
    $y += $bh + 26

    # ======================= ③ 浓度渐变条 =======================
    $g.DrawString('③ 浓度渐变条 100%→5% — 让每个喷嘴在全浓度范围工作', $fSection, $black, $x0, $y)
    $y += 22

    $steps    = 20
    $barH     = 40.0
    $barGap   = 7.0
    $labelW   = 26.0
    $barW     = $innerW - $labelW
    $stepW    = $barW / $steps

    foreach ($k in $pureKeys) {
        $rect = New-Object System.Drawing.RectangleF($x0, $y, $labelW, $barH)
        $g.DrawString($k, $fLabel, $black, $rect, $center)

        for ($s = 0; $s -lt $steps; $s++) {
            # 浓度从 100% 递减到 5%
            $ratio = 1.0 - ($s / [single]$steps) * 0.95
            $c  = $ink[$k]
            # 在白纸上按浓度插值：值越低越接近白
            $r  = [int](255 - (255 - $c.R) * $ratio)
            $gr = [int](255 - (255 - $c.G) * $ratio)
            $b  = [int](255 - (255 - $c.B) * $ratio)
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $r, $gr, $b))
            $g.FillRectangle($br, ($x0 + $labelW + $s * $stepW), $y, ($stepW + 0.6), $barH)
            $br.Dispose()
        }
        $g.DrawRectangle($penRule, ($x0 + $labelW), $y, $barW, $barH)
        $y += $barH + $barGap
    }
    $y += 12

    # ======================= ④ 细线断墨检测栅格 =======================
    $g.DrawString('④ 细线栅格 — 断墨最灵敏的指示（出现白色条纹即有喷嘴堵塞）', $fSection, $black, $x0, $y)
    $y += 22

    $cellGap = 14.0
    $cellW   = ($innerW - $cellGap) / 2
    $cellH   = 112.0
    $lineGap = 6.0      # 线间距 0.06 英寸
    $topY    = $y

    for ($i = 0; $i -lt $pureKeys.Count; $i++) {
        $k    = $pureKeys[$i]
        $col  = $i % 2
        $row  = [int][math]::Floor($i / 2)
        $cx   = $x0 + $col * ($cellW + $cellGap)
        $cy   = $topY + $row * ($cellH + 20)

        $g.DrawString($k, $fLabel, $black, $cx, $cy)
        $bodyY = $cy + 14
        $bodyH = $cellH - 14
        $pen   = New-Object System.Drawing.Pen($ink[$k], 1)

        # 左半：竖线组（检测横向断墨）
        $halfW = ($cellW - 10) / 2
        for ($vx = $cx; $vx -lt ($cx + $halfW); $vx += $lineGap) {
            $g.DrawLine($pen, $vx, $bodyY, $vx, ($bodyY + $bodyH))
        }
        # 右半：横线组（检测纵向断墨）
        $rx = $cx + $halfW + 10
        for ($hy = $bodyY; $hy -lt ($bodyY + $bodyH); $hy += $lineGap) {
            $g.DrawLine($pen, $rx, $hy, ($rx + $halfW), $hy)
        }
        $pen.Dispose()
        $g.DrawRectangle($penRule, $cx, $bodyY, $cellW, $bodyH)
    }
    $y = $topY + 2 * ($cellH + 20) + 4

    # ======================= ⑤ 黑色文字样本 =======================
    $g.DrawString('⑤ 黑色文字样本 — 确保 K 通道走文字渲染路径', $fSection, $black, $x0, $y)
    $y += 22

    $g.DrawString('喷墨打印机喷头养护测试 —— 每周自动打印以防止墨水干涸堵塞。', $fBody, $black, $x0, $y)
    $y += 18
    $g.DrawString('ABCDEFGHIJKLMNOPQRSTUVWXYZ  abcdefghijklmnopqrstuvwxyz', $fMono, $black, $x0, $y)
    $y += 15
    $g.DrawString('0123456789  !@#$%^&*()-=+[]{}<>/?  的一是了我不人在有他这为之', $fMono, $black, $x0, $y)
    $y += 15
    $g.DrawString('细号字测试：0123456789 ABCDEFG 中文小字体渲染检测 喷头养护', $fSmall, $black, $x0, $y)

    # ======================= 页脚 =======================
    $footY = $Height - $pad - 22
    $g.DrawLine($penRule, $x0, ($footY - 6), $x1, ($footY - 6))
    $g.DrawString('本页由 autoprintercheck 自动生成 — 若发现某色块或细线区域有白条，请执行打印机的「喷头清洗」', `
                  $fSmall, $black, $x0, $footY)

    # ---- 释放资源 ----
    foreach ($d in @($black, $penFrame, $penRule, $fTitle, $fMeta, $fSection,
                     $fLabel, $fSmall, $fBody, $fMono, $center)) {
        if ($d) { $d.Dispose() }
    }
}
