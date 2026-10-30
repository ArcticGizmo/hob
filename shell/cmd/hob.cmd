@echo off
rem cmd wrapper. A batch file runs inside the calling cmd.exe, so it can move it, but endlocal would undo that.
rem Jumps and plugin commands are looked up in the index hob-cli.exe writes; everything else is handed to the
rem exe. Either way only validated actions are written to a file, which is applied after endlocal through FOR
rem variables: cmd never re-parses those for & | > or %%, so a path or value cannot turn into a command.
setlocal EnableExtensions DisableDelayedExpansion
set "exe=%~dp0..\hob-cli.exe"
set "data=%HOB_HOME%"
if not defined data set "data=%USERPROFILE%\.hob"
set "index=%data%\index.txt"
set "apply=%LOCALAPPDATA%\Temp\hob-apply-%RANDOM%%RANDOM%.txt"
set "code=0"
type nul > "%apply%"

rem cmd cannot cheaply compare timestamps, so it only rebuilds a missing or old-format index. The exe refreshes
rem it whenever it runs, and `hob reindex` does it by hand.
set "first=none"
if exist "%index%" set /p first=<"%index%"
if not "%first:~0,14%"=="# hob index 2 " "%exe%" index

set "w1=%~1"
set "w2=%~2"
set "w3=%~3"
set "w4=%~4"
if not defined w1 goto exe
if /i "%w1%"=="back" if not defined w2 (
    >>"%apply%" echo back
    goto finish
)
if /i "%w1%"=="to" goto to
if /i "%w1%"=="cd" goto to
if /i "%w1%"=="path" goto to

set "key=%w1%"
if defined w2 set "key=%w1% %w2%"
if defined w3 goto runlookup
call :lookup go "%key%"
if defined found if exist "%found%\" goto jumpfound
:runlookup
if not defined w2 goto exe
set "found="
for /f "usebackq tokens=1,2,3,4 delims=|" %%a in ("%index%") do (
    if "%%a"=="run" if /i "%%b"=="%w1% %w2%" (
        set "found=%%c"
        set "HOB_PLUGIN_DIR=%%d"
    )
)
if defined found goto run
goto exe

:to
if not defined w2 goto exe
if "%w2:~0,1%"=="-" goto exe
if defined w4 goto exe
set "key=%w2%"
if defined w3 set "key=%w2% %w3%"
call :lookup to "%key%"
if not defined found goto exe
if not exist "%found%\" goto exe
if /i not "%w1%"=="path" goto jumpfound
setlocal EnableDelayedExpansion
echo(!found!
endlocal
goto finish

:jumpfound
setlocal EnableDelayedExpansion
>>"!apply!" echo(cd !found!
endlocal
goto finish

:run
set "prog=%found%"
set "rest="
shift
shift
:collect
if "%~1"=="" goto runit
set rest=%rest% %1
shift
goto collect
:runit
call :directives
if /i "%prog:~-4%"==".ps1" (
    powershell.exe -NoProfile -File "%prog%" %rest%
) else (
    call "%prog%" %rest%
)
set "code=%errorlevel%"
goto applydirectives

:exe
call :directives
set "HOB_SHELL=cmd"
"%exe%" hob %*
set "code=%errorlevel%"
goto applydirectives

:directives
set "HOB_DIRECTIVES=%LOCALAPPDATA%\Temp\hob-directives-%RANDOM%%RANDOM%.txt"
type nul > "%HOB_DIRECTIVES%"
exit /b

:applydirectives
rem Split here, while delayed expansion is off: with it on, cmd would process ! and ^ inside FOR variables.
for /f "usebackq delims=" %%L in ("%HOB_DIRECTIVES%") do (
    set "line=%%L"
    set "name="
    set "value="
    for /f "tokens=2 delims== " %%n in ("%%L") do set "name=%%n"
    for /f "tokens=1,* delims==" %%x in ("%%L") do set "value=%%y"
    call :check
)
del "%HOB_DIRECTIVES%" 2>nul
goto finish

rem Validates one directive held in %line%, with %name% and %value% already split out. Delayed expansion
rem keeps the text inert while it is inspected, and rebuilding the line from its parts proves its shape.
rem Lines with double quotes are refused outright because nothing legitimate needs them.
:check
setlocal EnableDelayedExpansion
set "ok="
rem A quote inside an IF unbalances cmd's quote tracking; SET only looks at the last quote on the line.
set "unquoted=!line:"=!"
if not "!unquoted!"=="!line!" goto checked
if "!line!"=="back" (
    set "ok=1"
    goto checked
)
if "!line:~0,3!"=="cd " goto checkcd
if "!line:~0,4!"=="env " goto checkenv
if "!line:~0,6!"=="unset " goto checkunset
goto checked
:checkcd
set "target=!line:~3!"
if "!target:~1,2!"==":\" if exist "!target!\" set "ok=1"
goto checked
:checkenv
if not "env !name!=!value!"=="!line!" goto checked
call :validname
if not errorlevel 1 set "ok=1"
goto checked
:checkunset
if not "unset !name!"=="!line!" goto checked
call :validname
if not errorlevel 1 set "ok=1"
:checked
if defined ok (
    >>"!apply!" echo(!line!
) else (
    1>&2 echo(hob: ignored directive: !line!
)
endlocal
exit /b

rem Succeeds when %name% looks like NAME or _NAME1 and is not one bash would execute. Removing every allowed
rem character and checking nothing is left avoids FOR /F, whose end-of-line handling skips lines starting with ;.
rem The # sentinel keeps the variable defined: substitution on an undefined variable returns the pattern text.
:validname
setlocal EnableDelayedExpansion
if not defined name exit /b 1
set "rest=#!name!"
for %%c in (a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9 _) do set "rest=!rest:%%c=!"
if not "!rest!"=="#" exit /b 1
for %%d in (0 1 2 3 4 5 6 7 8 9) do if "!name:~0,1!"=="%%d" exit /b 1
for %%r in (PROMPT_COMMAND PS0 PS1 PS2 PS3 PS4 ENV BASH_ENV BASHOPTS SHELLOPTS IFS) do if /i "!name!"=="%%r" exit /b 1
if /i "!name:~0,10!"=="BASH_FUNC_" exit /b 1
exit /b 0

:lookup
set "found="
for /f "usebackq tokens=1,2,* delims=|" %%a in ("%index%") do (
    if "%%a"=="%~1" if /i "%%b"=="%~2" set "found=%%c"
)
exit /b

:finish
endlocal & set "HOB_APPLY=%apply%" & set "HOB_CODE=%code%"
for /f "usebackq tokens=1,* delims= " %%a in ("%HOB_APPLY%") do (
    if "%%a"=="cd" pushd "%%b"
    if "%%a"=="back" popd
    if "%%a"=="env" set "%%b"
    if "%%a"=="unset" set "%%b="
)
del "%HOB_APPLY%" 2>nul
set "HOB_APPLY=" & set "HOB_CODE=" & exit /b %HOB_CODE%
