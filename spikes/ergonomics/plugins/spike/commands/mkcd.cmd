@echo off
rem Plugin commands are child processes, so they move the shell by appending a directive for the adapter.
setlocal
set "name=%~nx1"
if "%name%"=="" set "name=scratch-%RANDOM%"
set "dir=%LOCALAPPDATA%\Temp\hob-spike\%name%"
if not exist "%dir%" mkdir "%dir%"
set "json=%dir:\=\\%"
>>"%HOB_DIRECTIVES%" echo {"cd":"%json%"}
echo made %dir%
