@echo off
rem Builds this checkout and runs it as `hob <words>` against a scratch data folder, so an installed hob, its PATH
rem entry and %USERPROFILE%\.hob are never touched. The demo plugin in examples\plugins is loaded.
rem   build\try.cmd to
rem   build\try.cmd --reset            deletes the scratch folder
setlocal EnableExtensions DisableDelayedExpansion
set "HOB_HOME=%LOCALAPPDATA%\Temp\hob-try"
set "HOB_PATH_KEY=Software\hob-test"
for %%I in ("%~dp0..") do set "root=%%~fI"

if /i "%~1"=="--reset" (
    if exist "%HOB_HOME%" rmdir /s /q "%HOB_HOME%"
    echo removed %HOB_HOME%
    exit /b 0
)

powershell.exe -NoProfile -File "%root%\build\dev.ps1" >nul
if errorlevel 1 (
    echo build failed 1>&2
    exit /b 1
)

if not exist "%HOB_HOME%" mkdir "%HOB_HOME%"
set "plugins=%root:\=/%/examples/plugins"
rem No short name or shortcuts: an installed hob already has them on PATH, so they would only warn.
> "%HOB_HOME%\settings.json" echo { "pluginPaths": ["%plugins%"], "alias": "", "shortcuts": false }

echo [scratch hob: %HOB_HOME%]
"%root%\artifacts\dev\hob-cli.exe" hob %*
set "code=%ERRORLEVEL%"
endlocal & exit /b %code%
