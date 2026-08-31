<#
.SYNOPSIS
    在桌面创建「喷头养护」快捷方式，并生成配套图标。

.DESCRIPTION
    图标是现场用 GDI+ 画的（白纸 + CMYK 四色带），不依赖任何外部素材，
    也不借用系统打印机图标 —— 自己画的能明确表达「彩色测试页」。

    .ico 是手工组装的：GDI+ 不支持直接保存 ico，所以把 16/32/48/64/256
    五个尺寸的 PNG 塞进 ICONDIR 容器（Vista 以后的 ICO 允许 PNG 载荷）。

    快捷方式指向 wscript.exe 并把 .vbs 作为参数传入，而不是直接指向 .vbs。
    这样即使用户把 .vbs 的默认打开方式改成了文本编辑器，双击快捷方式依然
    是运行而不是打开编辑器。

.EXAMPLE
    .\New-Shortcut.ps1
    .\New-Shortcut.ps1 -Remove      # 删除桌面快捷方式
    .\New-Shortcut.ps1 -AlsoStartMenu
#>

[CmdletBinding()]
param(
    # 删除快捷方式而不是创建
    [switch] $Remove,

    # 同时在开始菜单创建一份
    [switch] $AlsoStartMenu
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$root         = $PSScriptRoot
$shortcutName = '喷头养护.lnk'
$iconPath     = Join-Path $root 'icon.ico'
$vbsPath      = Join-Path $root '启动UI.vbs'

$desktop   = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $shortcutName
$deskLnk   = Join-Path $desktop $shortcutName

# ============================ 删除模式 ============================

if ($Remove) {
    $gone = 0
    foreach ($p in @($deskLnk, $startMenu)) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force
            Write-Host "[OK] 已删除：$p" -ForegroundColor Green
            $gone++
        }
    }
    if ($gone -eq 0) { Write-Host '没有找到快捷方式。' -ForegroundColor Yellow }
    exit 0
}

# ============================ 画图标 ============================

function New-IconBitmap {
    param([int] $Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)

    $s = [single] $Size

    $inks = @(
        [System.Drawing.Color]::FromArgb(255,   0,   0,   0)    # K
        [System.Drawing.Color]::FromArgb(255,   0, 174, 239)    # C
        [System.Drawing.Color]::FromArgb(255, 236,   0, 140)    # M
        [System.Drawing.Color]::FromArgb(255, 255, 222,   0)    # Y（略压暗以便在白底上可见）
    )

    # ---------- 小尺寸：极简画法 ----------
    # 16px 这种尺寸下，纸张边框和色带间缝隙都不足 1 像素，抗锯齿会把它们
    # 糊成一片灰（实测整张图变成 182,182,185），白纸感荡然无存。
    # 所以小尺寸改成：白底 + 1px 白边 + 铺满的四色带，全部用整数坐标、
    # 关掉抗锯齿，保证每个色带都是纯色实块。
    if ($Size -lt 24) {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None

        # 白底既是「纸」，也让黑色带在深色任务栏上不至于糊掉
        $whiteAll = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $g.FillRectangle($whiteAll, 0, 0, $Size, $Size)
        $whiteAll.Dispose()

        $m    = 1
        $span = $Size - $m * 2
        for ($i = 0; $i -lt 4; $i++) {
            # 用整数边界逐条计算，避免累积舍入留下 1px 白缝
            $y0 = [int] ($m + $span * $i / 4.0)
            $y1 = [int] ($m + $span * ($i + 1) / 4.0)
            $b  = New-Object System.Drawing.SolidBrush($inks[$i])
            $g.FillRectangle($b, $m, $y0, $span, ($y1 - $y0))
            $b.Dispose()
        }

        $g.Dispose()
        return $bmp
    }

    # ---------- 中大尺寸：完整画法 ----------
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # ---- 纸张 ----
    $mx   = $s * 0.10          # 左右留白（纸是竖向的，所以左右比上下多）
    $my   = $s * 0.04
    $pw   = $s - $mx * 2
    $ph   = $s - $my * 2
    $rect = New-Object System.Drawing.RectangleF($mx, $my, $pw, $ph)

    # 纸张阴影
    if ($Size -ge 48) {
        $shadow = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb(40, 0, 0, 0))
        $sr = New-Object System.Drawing.RectangleF(
                ($mx + $s * 0.02), ($my + $s * 0.02), $pw, $ph)
        $g.FillRectangle($shadow, $sr)
        $shadow.Dispose()
    }

    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillRectangle($white, $rect)
    $white.Dispose()

    $penW = [Math]::Max(1.0, $s * 0.025)
    $edge = New-Object System.Drawing.Pen(
                [System.Drawing.Color]::FromArgb(255, 110, 110, 115), $penW)
    $g.DrawRectangle($edge, $rect.X, $rect.Y, $rect.Width, $rect.Height)
    $edge.Dispose()

    # ---- 顶部标题线（示意文字）----
    $grayBrush = New-Object System.Drawing.SolidBrush(
                    [System.Drawing.Color]::FromArgb(255, 90, 90, 95))
    $lineH = [Math]::Max(1.0, $s * 0.035)
    $g.FillRectangle($grayBrush,
        ($mx + $pw * 0.14), ($my + $ph * 0.10), ($pw * 0.72), $lineH)
    $g.FillRectangle($grayBrush,
        ($mx + $pw * 0.14), ($my + $ph * 0.19), ($pw * 0.45), $lineH)
    $grayBrush.Dispose()

    # ---- CMYK 四色带：图标的主体识别特征 ----
    $barTop  = $my + $ph * 0.32
    $barArea = $ph * 0.58
    $barX    = $mx + $pw * 0.14
    $barW    = $pw * 0.72

    $slot = $barArea / 4.0
    $gap  = if ($Size -ge 48) { $slot * 0.18 } else { 0.0 }
    $barH = $slot - $gap

    for ($i = 0; $i -lt 4; $i++) {
        $b = New-Object System.Drawing.SolidBrush($inks[$i])
        $g.FillRectangle($b, $barX, ($barTop + $slot * $i), $barW, $barH)
        $b.Dispose()
    }

    $g.Dispose()
    return $bmp
}

function Get-IcoDibBytes {
    <#
        把 Bitmap 转成 ICO 内部使用的 DIB 载荷。

        不用 PNG 载荷：虽然 Vista+ 的 shell 支持，但 .NET Framework 的
        System.Drawing.Icon 无法解码 PNG-based ICO（ToBitmap 会抛
        ArgumentOutOfRangeException），兼容性不可靠。传统 DIB 所有消费者都认。

        格式要点：
          - BITMAPINFOHEADER 的 biHeight 要写「实际高度 x 2」，
            因为 DIB 载荷在图像数据之后还跟着一张 AND mask
          - 像素自底向上存放
          - 32bppArgb 的内存布局就是 BGRA，正好是 ICO 要的字节序
    #>
    param([System.Drawing.Bitmap] $Bitmap)

    $w = $Bitmap.Width
    $h = $Bitmap.Height

    # LockBits 一次性取出整块像素，比逐个 GetPixel 快几个数量级
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $bits = $Bitmap.LockBits($rect,
                [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $bits.Stride
        $buf    = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($bits.Scan0, $buf, 0, $buf.Length)
    } finally {
        $Bitmap.UnlockBits($bits)
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # BITMAPINFOHEADER (40 字节)
    $bw.Write([uint32] 40)
    $bw.Write([int32]  $w)
    $bw.Write([int32]  ($h * 2))        # 图像 + mask
    $bw.Write([uint16] 1)               # 平面数
    $bw.Write([uint16] 32)              # 位深
    $bw.Write([uint32] 0)               # BI_RGB，不压缩
    $bw.Write([uint32] ($w * $h * 4))
    $bw.Write([int32]  0)
    $bw.Write([int32]  0)
    $bw.Write([uint32] 0)
    $bw.Write([uint32] 0)

    # 像素数据：自底向上
    for ($y = $h - 1; $y -ge 0; $y--) {
        $bw.Write($buf, ($y * $stride), ($w * 4))
    }

    # AND mask：1bpp、每行 4 字节对齐。透明度由 alpha 通道决定，
    # 这里全写 0 即可，但字段必须存在，否则尺寸校验失败。
    $maskStride = [int] ([Math]::Floor(($w + 31) / 32) * 4)
    $zeros      = New-Object byte[] ($maskStride * $h)
    $bw.Write($zeros, 0, $zeros.Length)

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose()
    $ms.Dispose()

    # -NoEnumerate：普通 return 会把 byte[] 展开，类型退化成 Object[]，
    # 之后 BinaryWriter.Write 匹配不到 Write(byte[]) 重载，载荷会被静默丢弃。
    Write-Output -NoEnumerate $bytes
}

function Save-IcoFile {
    param(
        [Parameter(Mandatory)] [hashtable] $DibBySize,
        [Parameter(Mandatory)] [string]    $Path
    )

    $sizes = @($DibBySize.Keys | Sort-Object)
    $count = $sizes.Count

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # ICONDIR
    $bw.Write([uint16] 0)       # 保留
    $bw.Write([uint16] 1)       # 类型 1 = 图标
    $bw.Write([uint16] $count)  # 图像数量

    # ICONDIRENTRY x N，每项 16 字节
    $offset = 6 + 16 * $count
    foreach ($sz in $sizes) {
        $data = [byte[]] $DibBySize[$sz]      # 显式强转，防类型退化
        # 256 在这里必须写 0 —— 字段只有 1 字节
        $dim = if ($sz -ge 256) { 0 } else { $sz }
        $bw.Write([byte]   $dim)          # 宽
        $bw.Write([byte]   $dim)          # 高
        $bw.Write([byte]   0)             # 调色板颜色数
        $bw.Write([byte]   0)             # 保留
        $bw.Write([uint16] 1)             # 颜色平面
        $bw.Write([uint16] 32)            # 位深
        $bw.Write([uint32] $data.Length)  # 数据长度
        $bw.Write([uint32] $offset)       # 数据偏移
        $offset += $data.Length
    }

    # 载荷
    foreach ($sz in $sizes) {
        $bw.Write([byte[]] $DibBySize[$sz])
    }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
}

Write-Host ''
Write-Host '=== 创建桌面快捷方式 ===' -ForegroundColor Cyan
Write-Host ''
Write-Host '生成图标…'

# 不含 256：DIB 是未压缩的，256x256 单独就要 256 KB，不值得
$dibs = @{}
foreach ($sz in @(16, 32, 48, 64, 128)) {
    $bmp = New-IconBitmap -Size $sz
    $dibs[$sz] = Get-IcoDibBytes -Bitmap $bmp
    $bmp.Dispose()
}
Save-IcoFile -DibBySize $dibs -Path $iconPath

$icoSize = (Get-Item -LiteralPath $iconPath).Length
Write-Host "[OK] 图标：$iconPath（$([math]::Round($icoSize/1024,1)) KB，$($dibs.Count) 个尺寸）" -ForegroundColor Green

# 验证：不仅要能构造，还要能真正解码出位图
try {
    foreach ($sz in @(16, 32, 48, 64, 128)) {
        $testIcon = New-Object System.Drawing.Icon($iconPath, $sz, $sz)
        $testBmp  = $testIcon.ToBitmap()
        if ($testBmp.Width -ne $sz) {
            throw "请求 ${sz}x${sz} 实际得到 $($testBmp.Width)x$($testBmp.Height)"
        }
        $testBmp.Dispose()
        $testIcon.Dispose()
    }
    Write-Host '[OK] 图标全部尺寸均可解码' -ForegroundColor Green
} catch {
    throw "生成的 .ico 无法被正确解码：$($_.Exception.Message)"
}

# ============================ 创建快捷方式 ============================

if (-not (Test-Path -LiteralPath $vbsPath)) {
    throw "找不到启动器：$vbsPath"
}

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscript)) {
    throw "找不到 wscript.exe：$wscript"
}

function New-AppShortcut {
    param([Parameter(Mandatory)] [string] $LnkPath)

    $shell = New-Object -ComObject WScript.Shell
    $lnk   = $shell.CreateShortcut($LnkPath)

    $lnk.TargetPath       = $wscript
    $lnk.Arguments        = '"' + $vbsPath + '"'
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation     = $iconPath + ',0'
    $lnk.Description      = '喷墨打印机喷头养护控制台 —— 查看状态、手动打印测试页'
    $lnk.WindowStyle      = 1
    $lnk.Save()

    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

New-AppShortcut -LnkPath $deskLnk
Write-Host "[OK] 桌面快捷方式：$deskLnk" -ForegroundColor Green

if ($AlsoStartMenu) {
    New-AppShortcut -LnkPath $startMenu
    Write-Host "[OK] 开始菜单：$startMenu" -ForegroundColor Green
}

# ============================ 回读验证 ============================

Write-Host ''
Write-Host '=== 验证 ===' -ForegroundColor Cyan
$shell = New-Object -ComObject WScript.Shell
$check = $shell.CreateShortcut($deskLnk)
Write-Host "  TargetPath  : $($check.TargetPath)"
Write-Host "  Arguments   : $($check.Arguments)"
Write-Host "  WorkingDir  : $($check.WorkingDirectory)"
Write-Host "  IconLocation: $($check.IconLocation)"
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null

Write-Host ''
Write-Host '完成。双击桌面上的「喷头养护」即可打开控制台。' -ForegroundColor Green
Write-Host '要删除快捷方式：.\New-Shortcut.ps1 -Remove' -ForegroundColor DarkGray
Write-Host ''
