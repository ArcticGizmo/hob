@echo off
rem Plugin commands are child processes, so they move the shell by appending a directive for the adapter.
setlocal
set "name=%~nx1"
if "%name%"=="" set "name=scratch-%RANDOM%"
set "dir=%LOCALAPPDATA%\Temp\hob-demo\%name%"
if not exist "%dir%" mkdir "%dir%"
>>"%HOB_DIRECTIVES%" echo cd %dir%
echo made %dir%
