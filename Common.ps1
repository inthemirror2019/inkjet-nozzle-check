# Common.ps1
# 公共函数：配置加载、状态持久化、日志、打印机在线检测、实际打印。

Add-Type -AssemblyName System.Drawing

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:AppRoot) { $script:AppRoot = $PSScriptRoot }

function Get-AppRoot { $PSScriptRoot }

function Get-AppConfig {
    $path = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $path)) {
        # 首次从仓库克隆时只有模板文件，自动复制一份，避免用户一上手就撞错误
        $sample = Join-Path $PSScriptRoot 'config.example.json'
        if (Test-Path $sample) {
            Copy-Item -LiteralPath $sample -Destination $path
            Write-Host "已从 config.example.json 创建 config.json，请修改其中的 printerName / printerIP 后重新运行。" -ForegroundColor Yellow
            throw '配置文件是模板，请先填写打印机名称和 IP。'
        }
        throw "找不到配置文件：$path"
    }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ------------------------- 状态持久化 -------------------------
function Get-StatePath { Join-Path $PSScriptRoot 'state.json' }

function Get-AppState {
    $path = Get-StatePath
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{
            lastPrintTime   = $null
            lastAttemptTime = $null
            successCount    = 0
            failCount       = 0
            lastError       = ''
        }
    }
    try {
        Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "state.json 解析失败，按首次运行处理：$($_.Exception.Message)" 'WARN'
        [pscustomobject]@{
            lastPrintTime = $null; lastAttemptTime = $null
            successCount  = 0;     failCount       = 0; lastError = ''
        }
    }
}

function Save-AppState {
    param([Parameter(Mandatory)] $State)
    $path = Get-StatePath
    # 先写临时文件再替换，避免断电时留下半个文件
    $tmp = "$path.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ------------------------- 日志 -------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','OK')] [string] $Level = 'INFO'
    )
    $dir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $file = Join-Path $dir ("nozzlecheck-{0}.log" -f (Get-Date -Format 'yyyy-MM'))
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $file -Value $line -Encoding UTF8

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Remove-OldLogs {
    param([int] $KeepMonths = 6)
    $dir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $dir)) { return }
    $cutoff = (Get-Date).AddMonths(-$KeepMonths)
    Get-ChildItem -LiteralPath $dir -Filter 'nozzlecheck-*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ------------------------- 打印机在线检测 -------------------------
function Test-PrinterOnline {
    param(
        [Parameter(Mandatory)] [string] $PrinterName,
        [string] $PrinterIP
    )

    $queue = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -eq $PrinterName } | Select-Object -First 1
    if (-not $queue) {
        return @{ Online = $false; Reason = "系统中不存在打印机队列「$PrinterName」" }
    }

    # 网络打印机先探测 IP —— 打印机关机时这一步就能判定，比查队列状态可靠
    if ($PrinterIP) {
        $reachable = Test-Connection -ComputerName $PrinterIP -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $reachable) {
            return @{ Online = $false; Reason = "打印机 IP $PrinterIP 无响应（打印机关机或不在同一网络）" }
        }
    }

    if ($queue.WorkOffline) {
        return @{ Online = $false; Reason = "打印机队列处于「脱机使用」状态" }
    }

    # Win32_Printer.PrinterStatus: 3=Idle 4=Printing 5=Warmup 7=Offline
    if ($queue.PrinterStatus -eq 7) {
        return @{ Online = $false; Reason = '打印机状态为 Offline' }
    }

    # DetectedErrorState: 2=Unknown 3=NoError 4=LowPaper 5=NoPaper 6=LowToner 7=NoToner
    #                     8=DoorOpen 9=Jammed 10=ServiceRequested 11=OutputBinFull
    $errState = $queue.DetectedErrorState
    $fatal = @{ 5 = '缺纸'; 8 = '机盖未关'; 9 = '卡纸'; 10 = '需要维修'; 11 = '出纸盒已满' }
    if ($fatal.ContainsKey([int]$errState)) {
        return @{ Online = $false; Reason = "打印机报错：$($fatal[[int]$errState])" }
    }

    @{ Online = $true; Reason = "就绪（状态码 $($queue.PrinterStatus)）" }
}

# 返回第一个可用的打印机名；主队列不可用时回退到备用队列
function Resolve-Printer {
    param([Parameter(Mandatory)] $Config)

    $candidates = @()
    if ($Config.printerName)         { $candidates += @{ Name = $Config.printerName;         IP = $Config.printerIP } }
    if ($Config.fallbackPrinterName) { $candidates += @{ Name = $Config.fallbackPrinterName; IP = $null } }

    foreach ($c in $candidates) {
        $r = Test-PrinterOnline -PrinterName $c.Name -PrinterIP $c.IP
        if ($r.Online) {
            Write-Log "打印机可用：$($c.Name) — $($r.Reason)"
            return $c.Name
        }
        Write-Log "打印机不可用：$($c.Name) — $($r.Reason)" 'WARN'
    }
    return $null
}

# ------------------------- 打印 -------------------------
function Invoke-PrintNozzlePage {
    param(
        [Parameter(Mandatory)] [string] $PrinterName,
        [Parameter(Mandatory)] [hashtable] $Meta,
        [bool] $ColorMode = $true,
        [string] $PaperSize = 'A4',
        [int] $WaitJobTimeoutSeconds = 180
    )

    . (Join-Path $PSScriptRoot 'NozzleCheckPage.ps1')

    $doc = New-Object System.Drawing.Printing.PrintDocument
    $doc.PrinterSettings.PrinterName = $PrinterName
    if (-not $doc.PrinterSettings.IsValid) {
        throw "打印机设置无效：$PrinterName"
    }
    $doc.DocumentName            = '喷头养护测试页'
    $doc.PrinterSettings.Copies  = 1
    # 原点落在可打印区域左上角，绘图坐标从 (0,0) 开始
    $doc.OriginAtMargins         = $false

    $target = $doc.PrinterSettings.PaperSizes | Where-Object { $_.Kind -eq $PaperSize } | Select-Object -First 1
    if ($target) { $doc.DefaultPageSettings.PaperSize = $target }
    $doc.DefaultPageSettings.Landscape = $false
    if ($doc.PrinterSettings.SupportsColor) {
        $doc.DefaultPageSettings.Color = $ColorMode
    }

    $script:printError = $null
    $handler = {
        param($sender, $e)
        try {
            $area = $e.PageSettings.PrintableArea
            Draw-NozzleCheckPage -Graphics $e.Graphics `
                                 -Width  $area.Width `
                                 -Height $area.Height `
                                 -Meta   $Meta
            $e.HasMorePages = $false
        } catch {
            $script:printError = $_
            $e.HasMorePages = $false
        }
    }
    $doc.add_PrintPage($handler)

    # 记录打印前已有的作业，便于识别本次新提交的作业
    $before = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })

    try {
        $doc.Print()
    } finally {
        $doc.remove_PrintPage($handler)
        $doc.Dispose()
    }

    if ($script:printError) {
        throw "绘制页面时出错：$($script:printError.Exception.Message)"
    }

    # 等作业真正离开队列 —— 避免「提交成功但打印机没吐纸」被误判为成功
    $deadline = (Get-Date).AddSeconds($WaitJobTimeoutSeconds)
    $sawJob   = $false
    while ((Get-Date) -lt $deadline) {
        $jobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
                  Where-Object { $before -notcontains $_.Id })
        if ($jobs.Count -eq 0) {
            if ($sawJob) { Write-Log '打印作业已完成并离开队列' }
            else         { Write-Log '打印作业已提交（队列中未观察到滞留作业）' }
            # 不返回值：成功即正常返回，失败一律 throw。
            # 返回 $true 会泄漏到调用者的输出流，在控制台上多打一行 "True"。
            return
        }
        $sawJob = $true
        $stuck = $jobs | Where-Object { $_.JobStatus -match 'Error|Blocked|Offline|PaperOut' }
        if ($stuck) {
            throw "打印作业异常：$($stuck[0].JobStatus)"
        }
        Start-Sleep -Seconds 3
    }
    throw "打印作业在 $WaitJobTimeoutSeconds 秒内未完成，可能卡在队列中"
}
