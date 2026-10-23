@echo off
rem Launcher for adb-qr-pair.ps1. Bypasses the PowerShell script policy for this run only.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0adb-qr-pair.ps1" %*
exit /b %ERRORLEVEL%
