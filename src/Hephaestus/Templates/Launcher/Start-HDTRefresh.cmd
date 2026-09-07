@echo off
rem Seeded by New-HDTWorkspace from Templates\Launcher. This copy is yours to edit.
rem Start a Refresh: run this AS ADMINISTRATOR on the machine to be replaced.
set HDT_LAUNCHED_BY=refresh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-HDTRefresh.ps1" %*
