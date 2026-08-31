' Launcher for the nozzle-maintenance UI. Double-click to start.
' NOTE: keep this file pure ASCII -- VBScript parses .vbs as ANSI, so
' UTF-8 Chinese comments would be mis-decoded and break the script.
' The PowerShell script hides its own console window, so no flash here.
Option Explicit

Dim shell, fso, scriptDir, target, cmd

Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
target    = scriptDir & "\NozzleCheckUI.ps1"

If Not fso.FileExists(target) Then
    MsgBox "Script not found:" & vbCrLf & target, 16, "Nozzle Check UI"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & target & """"

' 1 = normal window (the PS script hides its own console), False = don't wait
shell.Run cmd, 1, False
