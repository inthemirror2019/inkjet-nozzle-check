<#
.SYNOPSIS
    卸载喷头养护的计划任务。

.DESCRIPTION
    需要管理员权限。只删除计划任务，不会删除 state.json 和 logs 目录，
    所以重新安装后周期记录仍然连续。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Task.ps1
#>

[CmdletBinding()]
param(
    # 同时删除状态文件和日志（谨慎使用，会丢失上次打印时间记录）
    [switch] $Purge
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ''
    Write-Host '需要管理员权限来删除计划任务。' -ForegroundColor Red
    Write-Host "请以管理员身份运行： powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Cyan
    Write-Host ''
    exit 1
}

Write-Host ''
Write-Host '=== 卸载喷头养护计划任务 ===' -ForegroundColor Cyan

$removed = 0
foreach ($name in @('InkjetNozzleCheck-Daily', 'InkjetNozzleCheck-Boot')) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "[OK] 已删除：$name" -ForegroundColor Green
        $removed++
    } else {
        Write-Host "[--] 不存在：$name" -ForegroundColor DarkGray
    }
}

if ($Purge) {
    $root      = Get-AppRoot
    $statePath = Get-StatePath
    $logDir    = Join-Path $root 'logs'

    if (Test-Path -LiteralPath $statePath) {
        Remove-Item -LiteralPath $statePath -Force
        Write-Host "[OK] 已删除状态文件：$statePath" -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $logDir) {
        Remove-Item -LiteralPath $logDir -Recurse -Force
        Write-Host "[OK] 已删除日志目录：$logDir" -ForegroundColor Yellow
    }
}

Write-Host ''
if ($removed -gt 0) {
    Write-Host "卸载完成，共删除 $removed 个任务。" -ForegroundColor Green
    if (-not $Purge) {
        Write-Host '状态文件和日志已保留，重新安装后周期记录继续有效。' -ForegroundColor DarkGray
    }
} else {
    Write-Host '没有找到需要删除的任务。' -ForegroundColor Yellow
}
Write-Host ''
