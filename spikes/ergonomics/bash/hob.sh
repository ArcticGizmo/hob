# Git Bash side of the ergonomics spike, sourced by the generated `hob` script on PATH. Git Bash runs that
# script as a separate process, so it can never change your directory: `hob path` prints a folder for
#   cd "$(hob path git)"
# and everything that would have moved the shell explains that instead. Lookups read the index hob.psm1
# writes, so nothing here reimplements the matching rules. Process launches cost ~70 ms here and MSYS forks
# for $(...) are not free either, which is why this file uses no command substitution.

_hob_src=${BASH_SOURCE[0]}
[[ $_hob_src == /* ]] || _hob_src="$PWD/$_hob_src"
HOB_SPIKE_DIR=${_hob_src%/*}
HOB_SPIKE_DIR=${HOB_SPIKE_DIR%/bash}
unset _hob_src
HOB_INDEX_WIN=${HOB_SPIKE_INDEX:-"$USERPROFILE\\.hob\\index.txt"}
HOB_HISTORY_WIN=${HOB_SPIKE_HISTORY:-"$USERPROFILE\\.hob\\history.tsv"}
HOB_DIRECTIVES_WIN="$LOCALAPPDATA\\Temp\\hob-directives-$$.txt"
# Shell variables a directive must never set: bash runs or re-reads them, which would turn data into code.
_HOB_DENY='^(PROMPT_COMMAND|PS[0-4]|ENV|BASH_ENV|BASH_FUNC_.*|BASHOPTS|SHELLOPTS|IFS)$'

_hob_posix() {
    local p=${1//\\//}
    if [[ $p =~ ^([A-Za-z]):(.*)$ ]]; then p="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"; fi
    printf -v "$2" '%s' "$p"
}

_hob_windows() {
    local p=$1
    if [[ $p =~ ^/([A-Za-z])(/.*)?$ ]]; then p="${BASH_REMATCH[1]^^}:${BASH_REMATCH[2]:-/}"; fi
    printf -v "$2" '%s' "${p//\//\\}"
}

_hob_err() { printf 'hob: %s\n' "$*" >&2; }

_hob_build() {
    local psm1
    _hob_windows "$HOB_SPIKE_DIR/hob.psm1" psm1
    _hob_err 'building the index with PowerShell (only when plugins change)...'
    powershell.exe -NoProfile -Command "Import-Module '$psm1'; [void](& (Get-Module hob) { Get-HobModel })" > /dev/null
    [[ -f $1 ]] || { _hob_err 'could not build the index'; return 1; }
}

# The index lists what it was built from (settings, plugin folders, manifests, the module) as watch lines,
# so plugins added anywhere hob looks are noticed without bash having to read settings.json itself.
_hob_load() {
    local index f
    _hob_posix "$HOB_INDEX_WIN" index
    if [[ ! -f $index ]]; then _hob_build "$index" || return 1; fi
    _hob_read_index "$index"
    for f in "${HOB_WATCH[@]}"; do
        _hob_posix "$f" f
        if [[ -e $f && $f -nt $index ]]; then
            _hob_build "$index" || return 1
            _hob_read_index "$index"
            break
        fi
    done
}

_hob_read_index() {
    local kind key value
    declare -gA HOB_TO=() HOB_TO_AMBIG=() HOB_PLUG=() HOB_PLUG_AMBIG=() HOB_ROOT=() HOB_GO=() HOB_RUN=() HOB_CHILD_AMBIG=() HOB_SUB=()
    HOB_TOP=() HOB_LIST=() HOB_WATCH=()
    while IFS='|' read -r kind key value; do
        case $kind in
            top) HOB_TOP+=("$key") ;;
            to) HOB_TO[$key]=$value ;;
            'to?') HOB_TO_AMBIG[$key]=$value ;;
            plug) HOB_PLUG[$key]=$value ;;
            'plug?') HOB_PLUG_AMBIG[$key]=$value ;;
            root) HOB_ROOT[$key]=$value ;;
            sub) HOB_SUB[$key]+="$value " ;;
            go) HOB_GO[$key]=$value ;;
            run) HOB_RUN[$key]=$value ;;
            'child?') HOB_CHILD_AMBIG[$key]=$value ;;
            list) HOB_LIST+=("$key|$value") ;;
            watch) HOB_WATCH+=("$key") ;;
        esac
    done < "$1"
}

_hob_record() {
    [[ -n $HOB_NO_HISTORY ]] && return 0
    local file micros
    _hob_posix "$HOB_HISTORY_WIN" file
    [[ -d ${file%/*} ]] || return 0
    micros=${EPOCHREALTIME//[.,]/}
    # .NET ticks, to match the lines PowerShell writes: 100 ns units since 0001-01-01.
    printf '%s\t%s\t%s\t%s\t%s\n' "$(( micros * 10 + 621355968000000000 ))" "$2" "$1" "${3:--1}" "${4//[$'\t\r\n']/ }" >> "$file"
}

_hob_cd_hint() {
    _hob_err "Git Bash runs hob as a separate program, so it cannot move your shell. Use:  cd \"\$(hob path $*)\""
    return 2
}

# Commands run as children of this script, so their directives cannot reach your shell either. They are
# still validated, and what they asked for is reported so it can be done by hand.
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

_hob_run() {
    local exe file code
    if [[ ${1,,} == *.ps1 ]]; then _hob_err 'that is a PowerShell command, which runs inside a PowerShell session; use it from PowerShell'; return 1; fi
    _hob_posix "$1" exe
    shift
    _hob_posix "$HOB_DIRECTIVES_WIN" file
    : > "$file" || return 1
    HOB_DIRECTIVES=$HOB_DIRECTIVES_WIN "$exe" "$@"
    code=$?
    _hob_report "$file"
    rm -f -- "$file"
    return $code
}

_hob_list_places() {
    local item
    echo 'Places: cd "$(hob path <name>)", or hob path <plugin> <name> when a name is shared'
    for item in "${HOB_LIST[@]}"; do printf '  %-16s%s\n' "${item%%|*}" "${item#*|}"; done
}

# `select` is bash's built-in numbered menu. It draws on stderr and reads the terminal, so it still works
# inside cd "$(hob path docs)", where stdout is being captured.
_hob_pick() {
    local choice item
    local -a options=()
    if [[ -n $1 ]]; then
        IFS=',' read -ra options <<< "$1"
        options=("${options[@]# }")
    else
        for item in "${HOB_LIST[@]}"; do options+=("${item%%|*}"); done
    fi
    local PS3='which one (number, Ctrl+C to cancel): '
    select choice in "${options[@]}"; do
        if [[ -n $choice ]]; then _HOB_PICKED=$choice; _HOB_PICKED_ROW=$(( REPLY - 1 )); return 0; fi
        _hob_err 'cancelled'
        return 1
    done
    return 1
}

_hob_path() {
    local IFS=' '
    local key=${*,,} target row=-1
    if (( $# == 0 )); then
        [[ -t 0 && -t 2 ]] || { _hob_err 'usage: hob path <place>'; return 1; }
        _hob_pick '' || return 1
        key=${_HOB_PICKED,,}; row=$_HOB_PICKED_ROW
    elif [[ -z ${HOB_TO[$key]+x} && -n ${HOB_TO_AMBIG[$key]+x} ]]; then
        if [[ ! ( -t 0 && -t 2 ) ]]; then
            _hob_err "'$*' could be: ${HOB_TO_AMBIG[$key]}. Be more specific, for example 'hob path ${HOB_TO_AMBIG[$key]%%,*}'."
            return 1
        fi
        _hob_pick "${HOB_TO_AMBIG[$key]}" || return 1
        key=${_HOB_PICKED,,}; row=$_HOB_PICKED_ROW
    fi
    if [[ -z ${HOB_TO[$key]+x} ]]; then _hob_err "no place called '$*'. 'hob to' lists them all."; return 1; fi
    _hob_posix "${HOB_TO[$key]}" target
    printf '%s\n' "$target"
    _hob_record "${HOB_TO[$key]}" path "$row" "$*"
}

_hob_plugin() {
    local w1=${1,,} plugin key
    plugin=${HOB_PLUG[$w1]}
    if [[ -z $plugin ]]; then
        if [[ -n ${HOB_PLUG_AMBIG[$w1]+x} ]]; then _hob_err "'$1' is ambiguous in hob: ${HOB_PLUG_AMBIG[$w1]}"
        elif [[ -n ${HOB_TO[$w1]+x} || -n ${HOB_TO_AMBIG[$w1]+x} ]]; then _hob_cd_hint "$1"; return
        else _hob_err "'$1' is not something hob knows. Try 'hob list'."; fi
        return 1
    fi
    if (( $# == 1 )); then
        if [[ -n ${HOB_ROOT[$plugin]} ]]; then _hob_cd_hint "$plugin"; return; fi
        echo "$plugin: ${HOB_SUB[$plugin]}"
        return
    fi
    key="$plugin ${2,,}"
    if [[ -n ${HOB_GO[$key]+x} ]]; then _hob_cd_hint "$plugin $2"; return; fi
    if [[ -n ${HOB_RUN[$key]+x} ]]; then shift 2; _hob_run "${HOB_RUN[$key]}" "$@"; return; fi
    if [[ -n ${HOB_CHILD_AMBIG[$key]+x} ]]; then _hob_err "'$2' is ambiguous in $plugin: ${HOB_CHILD_AMBIG[$key]}"
    else _hob_err "'$2' is not something $plugin knows. Try 'hob list'."; fi
    return 1
}

hob_main() {
    _hob_load || return 1
    case ${1,,} in
        '' | list)
            local name
            for name in "${HOB_TOP[@]}"; do echo "  $name"; done ;;
        to | cd)
            shift
            if (( $# == 0 )); then _hob_list_places; else _hob_cd_hint "$@"; fi ;;
        path) shift; _hob_path "$@" ;;
        back) _hob_err 'Git Bash runs hob as a separate program, so there is no jump to go back from. Use  cd -  instead.'; return 2 ;;
        recent | naive) _hob_err "'$1' is PowerShell-only in this spike"; return 1 ;;
        update)
            shift
            [[ -f $HOB_SPIKE_DIR/hob-cli.exe ]] || { _hob_err 'this hob runs from a source checkout, so update it with git pull'; return 1; }
            "$HOB_SPIKE_DIR/hob-cli.exe" update "$@" ;;
        *) _hob_plugin "$@" ;;
    esac
}
