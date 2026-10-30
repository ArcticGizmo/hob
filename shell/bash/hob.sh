# Git Bash wrapper, sourced by the generated `hob` script on PATH. Git Bash runs that script as a separate
# process, so it can never change your directory: `hob path` prints a folder for
#   cd "$(hob path git)"
# and everything that would have moved the shell explains that instead. Jumps and plugin commands are looked up
# in the index hob-cli.exe writes; everything else is handed to the exe. Process launches cost ~70 ms here and
# MSYS forks for $(...) are not free either, which is why the lookup path uses no command substitution.

_hob_src=${BASH_SOURCE[0]}
[[ $_hob_src == /* ]] || _hob_src="$PWD/$_hob_src"
HOB_APP_DIR=${_hob_src%/*}
HOB_APP_DIR=${HOB_APP_DIR%/bash}
unset _hob_src
HOB_DATA_WIN=${HOB_HOME:-"$USERPROFILE\\.hob"}
HOB_DIRECTIVES_WIN="$LOCALAPPDATA\\Temp\\hob-directives-$$.txt"
# Shell variables a directive must never set: bash runs or re-reads them, which would turn data into code.
_HOB_DENY='^(PROMPT_COMMAND|PS[0-4]|ENV|BASH_ENV|BASH_FUNC_.*|BASHOPTS|SHELLOPTS|IFS)$'

_hob_posix() {
    local p=${1//\\//}
    if [[ $p =~ ^([A-Za-z]):(.*)$ ]]; then p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"; fi
    printf -v "$2" '%s' "$p"
}

_hob_err() { printf 'hob: %s\n' "$*" >&2; }

# Stale when it is missing, in an older format, or anything it lists as a source is newer: the same rule the
# exe and PowerShell apply.
_hob_load() {
    local index first f
    _hob_posix "$HOB_DATA_WIN\\index.txt" index
    for _ in 1 2; do
        if [[ -f $index ]]; then
            IFS= read -r first < "$index"
            if [[ $first == '# hob index 2 '* ]]; then
                _hob_read_index "$index"
                local stale=
                for f in "${HOB_WATCH[@]}"; do
                    _hob_posix "$f" f
                    if [[ -e $f && $f -nt $index ]]; then stale=1; break; fi
                done
                [[ -z $stale ]] && return 0
            fi
        fi
        "$HOB_APP_DIR/hob-cli.exe" index
    done
    return 1
}

_hob_read_index() {
    local kind key value extra
    declare -gA HOB_TO=() HOB_GO=() HOB_RUN=() HOB_RUN_DIR=()
    HOB_WATCH=()
    while IFS='|' read -r kind key value extra; do
        case $kind in
            to) HOB_TO[$key]=$value ;;
            go) HOB_GO[$key]=$value ;;
            run) HOB_RUN[$key]=$value; HOB_RUN_DIR[$key]=$extra ;;
            watch) HOB_WATCH+=("$key") ;;
        esac
    done < "$1"
}

_hob_record() {
    [[ -n $HOB_NO_HISTORY ]] && return 0
    local file micros
    _hob_posix "$HOB_DATA_WIN\\history.tsv" file
    [[ -d ${file%/*} ]] || return 0
    micros=${EPOCHREALTIME//[.,]/}
    # .NET ticks, to match the lines the exe and PowerShell write: 100 ns units since 0001-01-01.
    printf '%s\t%s\t%s\t-1\t\n' "$(( micros * 10 + 621355968000000000 ))" "$2" "$1" >> "$file"
}

_hob_cd_hint() {
    _hob_err "Git Bash runs hob as a separate program, so it cannot move your shell. Use:  cd \"\$(hob path $*)\""
    return 2
}

# Programs run as children of this script, so their directives cannot reach your shell either. They are still
# validated, and what they asked for is reported so it can be done by hand.
_hob_report() {
    local line verb value name target
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z ${line//[[:space:]]/} ]] && continue
        verb=${line%% *}
        value=
        [[ $line == *' '* ]] && value=${line#* }
        case $verb in
            cd)
                _hob_posix "$value" target
                if [[ $target == /* && -d $target ]]; then _hob_err "this command wanted to move your shell to $value. In Git Bash:  cd \"$target\""
                else _hob_err "ignored cd to a missing or invalid path: $value"; fi ;;
            back) [[ $line == back ]] || _hob_err "ignored malformed directive: $line" ;;
            env)
                name=${value%%=*}
                if [[ $value == *=* && $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! ${name^^} =~ $_HOB_DENY ]]; then _hob_err "this command wanted to set $name in your shell; Git Bash cannot pass that back"
                else _hob_err "ignored invalid env directive: $line"; fi ;;
            unset)
                if [[ ! ( $value =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! ${value^^} =~ $_HOB_DENY ) ]]; then _hob_err "ignored invalid unset directive: $line"; fi ;;
            *) _hob_err "ignored unknown directive: $line" ;;
        esac
    done < "$1"
}

# Runs a program with a fresh directives file and reports what it asked for.
_hob_with_directives() {
    local file code
    _hob_posix "$HOB_DIRECTIVES_WIN" file
    : > "$file" || return 1
    HOB_DIRECTIVES=$HOB_DIRECTIVES_WIN HOB_SHELL=bash "$@"
    code=$?
    _hob_report "$file"
    rm -f -- "$file"
    return $code
}

_hob_run() {
    local exe dir=$2
    _hob_posix "$1" exe
    shift 2
    if [[ ${exe,,} == *.ps1 ]]; then
        HOB_PLUGIN_DIR=$dir _hob_with_directives powershell.exe -NoProfile -File "$exe" "$@"
    else
        HOB_PLUGIN_DIR=$dir _hob_with_directives "$exe" "$@"
    fi
}

hob_main() {
    local IFS=' ' key target
    if ! _hob_load; then _hob_err 'could not build the index'; return 1; fi
    case ${1,,} in
        back)
            if (( $# == 1 )); then
                _hob_err 'Git Bash runs hob as a separate program, so there is no jump to go back from. Use  cd -  instead.'
                return 2
            fi ;;
        to | cd | path)
            if (( $# == 2 || $# == 3 )) && [[ $2 != -* ]]; then
                key=${*:2}
                key=${key,,}
                if [[ -n ${HOB_TO[$key]+x} ]]; then
                    if [[ ${1,,} != path ]]; then _hob_cd_hint "${@:2}"; return; fi
                    _hob_posix "${HOB_TO[$key]}" target
                    if [[ -d $target ]]; then
                        printf '%s\n' "$target"
                        _hob_record "${HOB_TO[$key]}" path
                        return 0
                    fi
                fi
            fi ;;
        '') ;;
        *)
            key=${*:1:2}
            key=${key,,}
            if (( $# <= 2 )) && [[ -n ${HOB_GO[$key]+x} ]]; then _hob_cd_hint "$@"; return; fi
            if (( $# >= 2 )) && [[ -n ${HOB_RUN[$key]+x} ]]; then _hob_run "${HOB_RUN[$key]}" "${HOB_RUN_DIR[$key]}" "${@:3}"; return; fi ;;
    esac
    _hob_with_directives "$HOB_APP_DIR/hob-cli.exe" hob "$@"
}
