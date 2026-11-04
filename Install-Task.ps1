<#
.SYNOPSIS
    注册喷头养护的两个计划任务（每天检查 + 开机检查）。

.DESCRIPTION
    需要管理员权限运行。会注册：
      InkjetNozzleCheck-Daily  每小时检查一次（错过则开机后补跑）
      InkjetNozzleCheck-Boot   登录后延迟若干分钟检查

    两个任务都只是「检查」，脚本内部再判断是否真的达到设定的打印间隔。
    重复触发是无害的。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

# ---- 权限检查 ----
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '需要管理员权限来注册计划任务。' -ForegroundColor Red
    Write-Host '请以管理员身份打开 PowerShell，然后重新运行：' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Cyan
    Write-Host ''
    exit 1
}

$cfg        = Get-AppConfig
$root       = Get-AppRoot
$mainScript = Join-Path $root 'Invoke-NozzleCheck.ps1'

if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "找不到主脚本：$mainScript"
}

$userId   = $identity.Name   # 形如 COMPUTERNAME\username
$interval = Get-PrintInterval -Config $cfg

Write-Host ''
Write-Host '=== 注册喷头养护计划任务 ===' -ForegroundColor Cyan
Write-Host "  主脚本   : $mainScript"
Write-Host "  运行账户 : $userId"
Write-Host "  定时检查 : 每小时一次（从每天 $($cfg.dailyCheckTime) 起算）"
Write-Host "  开机延迟 : $($cfg.bootDelayMinutes) 分钟"
Write-Host "  打印间隔 : $($interval.Text)（可在控制台修改，无需重装任务）"
Write-Host ''

# ---- 公共设置 ----
# StartWhenAvailable：关机错过了每天的触发时刻，开机后尽快补跑（这是「机器不常开机」的关键）
# DontStopIfGoingOnBatteries + AllowStartIfOnBatteries：笔记本电池状态下也能跑
# IgnoreNew：上一次还在跑就跳过本次，避免并发重复打印
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 10)

# 用当前用户 + Interactive 运行：能访问该用户安装的打印机队列
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited

function New-CheckAction {
    param([string] $TriggerName)
    New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$mainScript`" -Trigger $TriggerName" `
        -WorkingDirectory $root
}

# ---- 任务一：每小时检查 ----
# 每天从 dailyCheckTime 起、每小时重复一次。只是检查，未到间隔就记一行日志退出，几乎没有开销。
# 这样间隔改成按小时也能及时打印，而且在界面里改间隔无需重新注册任务。
# （任务名保留 Daily，重装时能直接覆盖旧任务。）
$dailyName    = 'InkjetNozzleCheck-Daily'
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $cfg.dailyCheckTime
$dailyTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At $cfg.dailyCheckTime `
                                -RepetitionInterval (New-TimeSpan -Hours 1) `
                                -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
# 默认为 true：每天重复周期结束时会强杀正在运行的实例，可能正好打断打印
$dailyTrigger.Repetition.StopAtDurationEnd = $false

Unregister-ScheduledTask -TaskName $dailyName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

Register-ScheduledTask `
    -TaskName    $dailyName `
    -Description "喷墨打印机喷头养护：每小时检查一次，距上次打印达到设定间隔（$($interval.Text)，可在控制台修改）则自动打印一张测试页。关机错过时开机后补跑。" `
    -Action      (New-CheckAction -TriggerName 'Daily') `
    -Trigger     $dailyTrigger `
    -Settings    $settings `
    -Principal   $taskPrincipal | Out-Null

Write-Host "[OK] 已注册：$dailyName" -ForegroundColor Green

# ---- 任务二：登录后检查 ----
# 单独一个开机任务，是为了应对「关机好几天，开机后想尽快养护」的场景，
# 不完全依赖每天触发的补跑机制。
$bootName = 'InkjetNozzleCheck-Boot'
$delay    = "PT$($cfg.bootDelayMinutes)M"   # ISO 8601 时长，如 PT3M

Unregister-ScheduledTask -TaskName $bootName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$bootTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$bootTrigger.Delay = $delay

Register-ScheduledTask `
    -TaskName    $bootName `
    -Description "喷墨打印机喷头养护：登录后延迟 $($cfg.bootDelayMinutes) 分钟检查（等网络和打印机就绪），距上次打印达到设定间隔则自动打印。" `
    -Action      (New-CheckAction -TriggerName 'Boot') `
    -Trigger     $bootTrigger `
    -Settings    $settings `
    -Principal   $taskPrincipal | Out-Null

Write-Host "[OK] 已注册：$bootName" -ForegroundColor Green

# ---- 汇总 ----
Write-Host ''
Write-Host '=== 当前状态 ===' -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'InkjetNozzleCheck-*' |
    Select-Object TaskName, State, @{
        N = 'NextRunTime'
        E = { (Get-ScheduledTaskInfo -TaskName $_.TaskName).NextRunTime }
    } | Format-Table -AutoSize

$state = Get-AppState
if ($state.lastPrintTime) {
    Write-Host "上次打印时间：$($state.lastPrintTime)"
} else {
    Write-Host '尚无打印记录：下一次触发时会立即打印一张，作为周期基准。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '安装完成。可用命令：' -ForegroundColor Green
Write-Host '  .\Invoke-NozzleCheck.ps1 -DryRun    # 只看判断结果，不打印'
Write-Host '  .\Test-Run.ps1                      # 立即实打一张验证'
Write-Host '  .\Uninstall-Task.ps1                # 卸载计划任务'
Write-Host ''

Write-Log -Message "计划任务已注册（每小时检查，起始 $($cfg.dailyCheckTime) / Boot 延迟 $($cfg.bootDelayMinutes) 分钟）" -Level OK
