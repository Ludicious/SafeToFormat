@echo off
REM ============================================================
REM  Run SafeToFormat by double-clicking this file.
REM  It launches SafeToFormat.ps1 from the same folder, so keep
REM  the two files together.
REM
REM  FIRST TIME ONLY: right-click this .bat AND SafeToFormat.ps1
REM  -> Properties -> tick "Unblock" at the bottom -> OK.
REM  (Windows blocks downloaded files until you do this.)
REM
REM  Advanced: you can pass options too, e.g. from a terminal:
REM     "Run SafeToFormat.bat" -Verify
REM ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SafeToFormat.ps1" %*
echo.
pause
