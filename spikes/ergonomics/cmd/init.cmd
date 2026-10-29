@echo off
rem Run once in a cmd window to get hob, the h prefix and plugin shortcuts. Shortcuts are doskey macros, which
rem only apply to what you type at the prompt, so they cannot break scripts that happen to use the same name.
set "PATH=%~dp0;%PATH%"
doskey h="%~dp0hob.cmd" $*
for /f "delims=" %%s in ('call "%~dp0hob.cmd" __shortcuts') do (
    where /q %%s 2>nul && (echo hob: skipped shortcut '%%s' because it would hide an existing command) || doskey %%s="%~dp0hob.cmd" %%s $*
)
echo hob spike loaded ^| prefix alias: h ^| shortcuts as doskey macros
