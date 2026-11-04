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
            Write-Host "已从 config.example.json 创建 config.json，请修改其中的 printerName 后重新运行（也可以在界面里下拉选择）。" -ForegroundColor Yellow
            throw '配置文件是模板，请先填写打印机名称和 IP。'
        }
        throw "找不到配置文件：$path"
    }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-AppConfig {
    param([Parameter(Mandatory)] $Config)
    $path = Join-Path $PSScriptRoot 'config.json'
    $tmp  = "$path.tmp"
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ------------------------- 打印间隔 -------------------------
# 新配置：intervalValue + intervalUnit（'hours' / 'days'）。
# 旧配置只有 intervalDays，照旧按天处理，不需要手动迁移。
function Get-PrintInterval {
    param([Parameter(Mandatory)] $Config)

    $unit  = if ($Config.intervalUnit -eq 'hours') { 'hours' } else { 'days' }
    $value = if ($null -ne $Config.intervalValue) { [double] $Config.intervalValue }
             elseif ($null -ne $Config.intervalDays) { [double] $Config.intervalDays }
             else { 7 }
    if ($value -le 0) { $value = 1 }

    $span = if ($unit -eq 'hours') { [TimeSpan]::FromHours($value) } else { [TimeSpan]::FromDays($value) }
    [pscustomobject]@{
        Value = $value
        Unit  = $unit
        Span  = $span
        Text  = '{0} {1}' -f $value, $(if ($unit -eq 'hours') { '小时' } else { '天' })
    }
}

function Set-PrintInterval {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [int] $Value,
        [Parameter(Mandatory)] [ValidateSet('hours','days')] [string] $Unit
    )
    $Config | Add-Member -NotePropertyName intervalValue -NotePropertyValue $Value -Force
    $Config | Add-Member -NotePropertyName intervalUnit  -NotePropertyValue $Unit  -Force
    # 去掉旧字段，免得两套设置同时存在让人困惑
    $Config.PSObject.Properties.Remove('intervalDays')
    Save-AppConfig $Config
}

# 判断到期时的容差：间隔的 10%，最多 10 分钟。
# 检查是每小时整点触发的，没有容差的话「上次 10:00:05 打印、这次 10:00:02 检查」
# 会差几秒没到期，把打印推迟整整一小时。
function Get-IntervalTolerance {
    param([Parameter(Mandatory)] [TimeSpan] $Span)
    [TimeSpan]::FromMinutes([math]::Min(10, $Span.TotalMinutes * 0.1))
}

# 按间隔单位格式化时长，如「5.2 小时」「3.40 天」
function Format-Elapsed {
    param([Parameter(Mandatory)] [TimeSpan] $Span, [Parameter(Mandatory)] [string] $Unit)
    if ($Unit -eq 'hours') { '{0:N1} 小时' -f $Span.TotalHours }
    else                   { '{0:N2} 天'   -f $Span.TotalDays }
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

# 从打印队列自身的端口推出打印机当前地址：
#   · 标准 TCP/IP 端口 —— 端口上登记的 IP / 主机名
#   · WSD 端口         —— 即插即用设备的 LocationInfo（http://地址:80/WSD/DEVICE）
#   · USB 等本地端口   —— 没有地址，返回 $null
# WSD 地址会随打印机 IP 变化自动更新，所以不需要在 config.json 里手填 IP。
function Get-PrinterQueueHost {
    param([Parameter(Mandatory)] $Queue)

    $port = Get-CimInstance Win32_TCPIPPrinterPort -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $Queue.PortName } | Select-Object -First 1
    if ($port -and $port.HostAddress) { return $port.HostAddress }

    if ($Queue.PortName -like 'WSD-*') {
        $loc = Get-PnpDevice -PresentOnly -FriendlyName $Queue.Name -ErrorAction SilentlyContinue |
               ForEach-Object {
                   (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' `
                                          -ErrorAction SilentlyContinue).Data
               } |
               Where-Object { $_ -match '^https?://' } | Select-Object -First 1
        # 形如 http://[fe80::1%4]:80/WSD/DEVICE 或 http://192.168.1.5:80/WSD/DEVICE
        if ($loc -match '^https?://\[([^\]]+)\]') { return $Matches[1] }
        if ($loc -match '^https?://([^:/]+)')     { return $Matches[1] }
    }
    $null
}

# 探测主机是否在线，返回探测方式（如 'ping'、'TCP 9100'），全部失败返回 $null。
# 不能只靠 ping：不少打印机屏蔽 ICMP 或休眠时不回 ping，但打印端口照常响应。
function Test-HostReachable {
    param([Parameter(Mandatory)] [string] $HostName)

    # 不用 Test-Connection：不通时要等好几秒，UI 线程会卡住。Ping 类可以指定超时。
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt 2; $i++) {
            try {
                if ($ping.Send($HostName, 1000).Status -eq 'Success') { return 'ping' }
            } catch { break }   # 主机名解析失败等，直接改试端口
        }
    } finally { $ping.Dispose() }

    # 9100=RAW 631=IPP 80=WSD/网页
    foreach ($p in 9100, 631, 80) {
        $client = $null
        try {
            $addr = $null
            if ([System.Net.IPAddress]::TryParse($HostName, [ref] $addr)) {
                # 默认构造的 TcpClient 只支持 IPv4，IPv6 地址要显式指定地址族
                $client = New-Object System.Net.Sockets.TcpClient($addr.AddressFamily)
                $task   = $client.ConnectAsync($addr, $p)
            } else {
                $client = New-Object System.Net.Sockets.TcpClient
                $task   = $client.ConnectAsync($HostName, $p)
            }
            if ($task.Wait(600) -and $client.Connected) { return "TCP $p" }
        } catch {
            # 连接被拒绝 / 超时都算这个端口不通，继续下一个
        } finally {
            if ($client) { $client.Dispose() }
        }
    }
    $null
}

# 地址一律从队列端口自动获取，不读 config.json 里的固定 IP ——
# 打印机 IP 由路由器 DHCP 分配，随时可能变，手填的 IP 迟早失效。
function Test-PrinterOnline {
    param([Parameter(Mandatory)] [string] $PrinterName)

    $queue = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -eq $PrinterName } | Select-Object -First 1
    if (-not $queue) {
        return @{ Online = $false; Reason = "系统中不存在打印机队列「$PrinterName」" }
    }

    # 先探测网络 —— 打印机关机时这一步就能判定，比查队列状态可靠
    $queueHost = Get-PrinterQueueHost -Queue $queue
    $via       = $null
    if ($queueHost) {
        $method = Test-HostReachable -HostName $queueHost
        if (-not $method) {
            $hint = if ($queue.PortName -like 'WSD-*') { '' }
                    else { '；该队列端口是固定 IP，打印机换过 IP 的话请改选 WSD 类型的队列' }
            return @{ Online = $false; Reason = "打印机地址 $queueHost 无响应（打印机关机或不在同一网络$hint）" }
        }
        $via = "$method $queueHost"
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

    $reason = "就绪（状态码 $($queue.PrinterStatus)）"
    if ($via) { $reason += "，$via 可达" }
    @{ Online = $true; Reason = $reason }
}

# 列出系统里的打印机队列，过滤掉 PDF / XPS / OneNote / 传真等虚拟打印机，供 UI 下拉选择
function Get-PhysicalPrinters {
    $virtual = 'PDF|XPS|OneNote|Fax|传真|WPS|PORTPROMPT|^FILE:|^nul:|pdfcmon|Kingsoft'
    Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $virtual -and $_.PortName -notmatch $virtual -and $_.DriverName -notmatch $virtual } |
        ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; IsWsd = ($_.PortName -like 'WSD-*') }
        }
}

# 返回第一个可用的打印机名；主队列不可用时回退到备用队列
function Resolve-Printer {
    param([Parameter(Mandatory)] $Config)

    $candidates = @()
    if ($Config.printerName) { $candidates += $Config.printerName }
    if ($Config.fallbackPrinterName -and $Config.fallbackPrinterName -ne $Config.printerName) {
        $candidates += $Config.fallbackPrinterName
    }

    foreach ($name in $candidates) {
        $r = Test-PrinterOnline -PrinterName $name
        if ($r.Online) {
            Write-Log "打印机可用：$name — $($r.Reason)"
            return $name
        }
        Write-Log "打印机不可用：$name — $($r.Reason)" 'WARN'
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
