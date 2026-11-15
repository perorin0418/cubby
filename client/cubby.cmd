@echo off
rem cubby.cmd : run client/cubby from cmd.exe (calls cubby.ps1). Keep this file ASCII-only with CRLF.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cubby.ps1" %*
exit /b %ERRORLEVEL%
