@if /i not "%CLAUDE_PLUGIN_OPTION_PROBE_HOOKS%"=="true" if /i "%~1"=="hook" exit /b 0
@"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\run.ps1" %*
@exit /b %errorlevel%
