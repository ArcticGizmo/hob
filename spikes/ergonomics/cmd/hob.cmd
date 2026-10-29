@echo off
rem cmd adapter for the ergonomics spike. A batch file runs inside the calling cmd.exe, so it can move it,
rem but endlocal would undo that. Everything is decided under setlocal and only validated actions are
rem written to a file, which is applied after endlocal through FOR variables: cmd never re-parses those
rem for & | > or %%, so a path or value cannot turn into a command.
setlocal EnableExtensions DisableDelayedExpansion
set "spike=%~dp0.."
set "index=%HOB_SPIKE_INDEX%"
if not defined index set "index=%LOCALAPPDATA%\hob-spike\index.txt"
set "apply=%LOCALAPPDATA%\Temp\hob-apply-%RANDOM%%RANDOM%.txt"
set "code=0"
type nul > "%apply%"

if /i "%~1"=="reindex" (
    call :build
    goto finish
)
if not exist "%index%" call :build
if not exist "%index%" (
    set "code=1"
    goto finish
)

set "w1=%~1"
set "w2=%~2"
set "w3=%~3"
if not defined w1 goto list
if /i "%w1%"=="list" goto list
set "mode=jump"
if /i "%w1%"=="to" goto to
if /i "%w1%"=="cd" goto to
if /i "%w1%"=="path" (
    set "mode=path"
    goto to
)
if /i "%w1%"=="__shortcuts" goto shortcuts
if /i "%w1%"=="back" (
    >>"%apply%" echo back
    goto finish
)
if /i "%w1%"=="recent" goto pwshonly
if /i "%w1%"=="naive" goto pwshonly
goto plugin

:to
if not defined w2 (
    if "%mode%"=="path" (
        1>&2 echo hob: usage: hob path ^<place^>
        set "code=1"
        goto finish
    )
    goto listplaces
)
set "key=%w2%"
if defined w3 set "key=%w2% %w3%"
call :lookup to "%key%"
if defined found goto placefound
call :lookup to? "%key%"
if not defined found goto noplace
for /f "tokens=1 delims=," %%f in ("%found%") do set "first=%%f"
1>&2 echo hob: '%key%' could be: %found%. Be more specific, for example 'hob to %first%'.
set "code=1"
goto finish
:noplace
1>&2 echo hob: no place called '%key%'. 'hob to' lists them all.
set "code=1"
goto finish

:placefound
if not "%mode%"=="path" goto jumpfound
setlocal EnableDelayedExpansion
echo(!found!
endlocal
goto finish

:plugin
call :lookup plug "%w1%"
if defined found goto pluginfound
call :lookup plug? "%w1%"
if defined found (
    1>&2 echo hob: '%w1%' is ambiguous in hob: %found%
    set "code=1"
    goto finish
)
call :lookup to "%w1%"
if not defined found call :lookup to? "%w1%"
if defined found (
    1>&2 echo hob: '%w1%' is a place. Did you mean 'hob to %w1%'?
) else (
    1>&2 echo hob: '%w1%' is not something hob knows. Try 'hob list'.
)
set "code=1"
goto finish

:pluginfound
set "plugin=%found%"
if defined w2 goto pluginchild
call :lookup root "%plugin%"
if defined found goto jumpfound
echo %plugin%:
for /f "usebackq tokens=1,2,* delims=|" %%a in ("%index%") do if "%%a|%%b"=="sub|%plugin%" echo   %%c
goto finish

:pluginchild
call :lookup go "%plugin% %w2%"
if defined found goto jumpfound
call :lookup run "%plugin% %w2%"
if defined found goto run
call :lookup child? "%plugin% %w2%"
if defined found (
    1>&2 echo hob: '%w2%' is ambiguous in %plugin%: %found%
) else (
    1>&2 echo hob: '%w2%' is not something %plugin% knows. Try 'hob list'.
)
set "code=1"
goto finish

:jumpfound
setlocal EnableDelayedExpansion
>>"!apply!" echo(cd !found!
endlocal
goto finish

:run
set "exe=%found%"
if /i "%exe:~-4%"==".ps1" (
    1>&2 echo hob: that is a PowerShell command, which runs inside a PowerShell session; use it from PowerShell
    set "code=1"
    goto finish
)
set "rest="
shift
shift
:collect
if "%~1"=="" goto runit
set rest=%rest% %1
shift
goto collect
:runit
set "HOB_DIRECTIVES=%LOCALAPPDATA%\Temp\hob-directives-%RANDOM%%RANDOM%.txt"
type nul > "%HOB_DIRECTIVES%"
call "%exe%" %rest%
set "code=%errorlevel%"
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

:list
for /f "usebackq tokens=1,2,* delims=|" %%a in ("%index%") do if "%%a"=="top" echo   %%b
goto finish

:listplaces
echo Places: hob to ^<name^>, or hob to ^<plugin^> ^<name^> when a name is shared
for /f "usebackq tokens=1,2,* delims=|" %%a in ("%index%") do if "%%a"=="list" echo   %%b  -  %%c
goto finish

:shortcuts
for /f "usebackq tokens=1,2 delims=|" %%a in ("%index%") do if "%%a"=="short" echo %%b
goto finish

:pwshonly
1>&2 echo hob: '%w1%' is PowerShell-only in this spike
set "code=1"
goto finish

:build
1>&2 echo hob: building the index with PowerShell (only when plugins change)...
powershell.exe -NoProfile -Command "Import-Module '%spike%\hob.psm1'; [void](& (Get-Module hob) { Get-HobModel })" >nul
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
