# Git Bash adapter for the ergonomics spike. Source it:  source spikes/ergonomics/bash/hob.sh
# Every jump is a lookup in the index the PowerShell module writes, held in associative arrays, so the hot
# path starts no process. Process launches cost ~70 ms here, and MSYS forks for $(...) are not free either,
# which is why this file uses no command substitution at all.
# Options, set before sourcing: HOB_ALIAS (default h, empty for none), HOB_NO_SHORTCUTS=1.

_hob_src=${BASH_SOURCE[0]}
[[ $_hob_src == /* ]] || _hob_src="$PWD/$_hob_src"
HOB_SPIKE_DIR=${_hob_src%/*}
HOB_SPIKE_DIR=${HOB_SPIKE_DIR%/bash}
unset _hob_src
HOB_INDEX_WIN=${HOB_SPIKE_INDEX:-"$LOCALAPPDATA\\hob-spike\\index.txt"}
HOB_HISTORY_WIN=${HOB_SPIKE_HISTORY:-"$LOCALAPPDATA\\hob-spike\\history.tsv"}
HOB_DIRECTIVES_WIN="$LOCALAPPDATA\\Temp\\hob-directives-$$.txt"
_HOB_STAMP=
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

# Exists as something other than an alias. Builtins only: $(...) forks, which is slow under Git Bash.
_hob_taken() { type -t "$1" > /dev/null && ! alias "$1" > /dev/null 2>&1; }

_hob_load() {
    local index stale= f first kind key value
    _hob_posix "$HOB_INDEX_WIN" index
    if [[ ! -f $index ]]; then stale=1
    else
        for f in "$HOB_SPIKE_DIR"/plugins/*/plugin.json "$HOB_SPIKE_DIR/roots.local.json" "$HOB_SPIKE_DIR/hob.psm1"; do
            [[ -f $f && $f -nt $index ]] && stale=1
        done
    fi
    if [[ -n $stale ]]; then
        local psm1
        _hob_windows "$HOB_SPIKE_DIR/hob.psm1" psm1
        _hob_err 'building the index with PowerShell (only when plugins change)...'
        powershell.exe -NoProfile -Command "Import-Module '$psm1'; [void](& (Get-Module hob) { Get-HobModel })" >/dev/null
        [[ -f $index ]] || { _hob_err 'could not build the index'; return 1; }
    fi

    IFS= read -r first < "$index"
    [[ $first == "$_HOB_STAMP" ]] && return 0

    declare -gA HOB_TO=() HOB_TO_AMBIG=() HOB_PLUG=() HOB_PLUG_AMBIG=() HOB_ROOT=() HOB_GO=() HOB_RUN=() HOB_CHILD_AMBIG=() HOB_SUB=()
    HOB_TOP=() HOB_LIST=() HOB_TOCOMP=() HOB_SHORT=()
    while IFS='|' read -r kind key value; do
        case $kind in
            top) HOB_TOP+=("$key") ;;
            to) HOB_TO[$key]=$value ;;
            'to?') HOB_TO_AMBIG[$key]=$value ;;
            plug) HOB_PLUG[$key]=$value ;;
            'plug?') HOB_PLUG_AMBIG[$key]=$value ;;
            root) HOB_ROOT[$key]=$value ;;
            short) HOB_SHORT+=("$key") ;;
            sub) HOB_SUB[$key]+="$value " ;;
            go) HOB_GO[$key]=$value ;;
            run) HOB_RUN[$key]=$value ;;
            'child?') HOB_CHILD_AMBIG[$key]=$value ;;
            list) HOB_LIST+=("$key|$value") ;;
            tocomp) HOB_TOCOMP+=("$key|$value") ;;
        esac
    done < "$index"
    _HOB_STAMP=$first
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

_hob_jump() {
    local target
    _hob_posix "$1" target
    [[ -d $target ]] || { _hob_err "$1 does not exist"; return 1; }
    pushd "$target" > /dev/null || return 1
    _hob_record "$1" "$2" "$4" "$3"
}

_hob_apply() {
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
                if [[ $target == /* && -d $target ]]; then pushd "$target" > /dev/null
                else _hob_err "ignored cd to a missing or invalid path: $value"; fi ;;
            back)
                if [[ $line == back ]]; then popd > /dev/null 2>&1 || _hob_err 'nothing to go back to'
                else _hob_err "ignored malformed directive: $line"; fi ;;
            env)
                name=${value%%=*}
                if [[ $value == *=* && $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! ${name^^} =~ $_HOB_DENY ]]; then export "$name=${value#*=}"
                else _hob_err "ignored invalid env directive: $line"; fi ;;
            unset)
                if [[ $value =~ ^[A-Za-z_][A-Za-z0-9_]*$ && ! ${value^^} =~ $_HOB_DENY ]]; then unset -v "$value"
                else _hob_err "ignored invalid unset directive: $line"; fi ;;
            *) _hob_err "ignored unknown directive: $line" ;;
        esac
    done < "$1"
}

_hob_run() {
    local exe file code
    if [[ ${1,,} == *.ps1 ]]; then _hob_err "that is a PowerShell command, which runs inside a PowerShell session; use it from PowerShell"; return 1; fi
    _hob_posix "$1" exe
    shift
    _hob_posix "$HOB_DIRECTIVES_WIN" file
    : > "$file" || return 1
    HOB_DIRECTIVES=$HOB_DIRECTIVES_WIN "$exe" "$@"
    code=$?
    _hob_apply "$file"
    : > "$file"
    return $code
}

_hob_list_places() {
    local item
    echo 'Places: h to <name>, or h to <plugin> <name> when a name is shared'
    for item in "${HOB_LIST[@]}"; do printf '  %-16s%s\n' "${item%%|*}" "${item#*|}"; done
}

# `select` is bash's built-in numbered menu: no dependencies, works in any terminal Git Bash runs in.
_hob_pick() {
    local query=$1 choice item
    local -a options=()
    if [[ -n $2 ]]; then
        IFS=',' read -ra options <<< "$2"
        options=("${options[@]# }")
    else
        for item in "${HOB_LIST[@]}"; do options+=("${item%%|*}"); done
    fi
    local PS3='to (number, Ctrl+C to cancel): '
    select choice in "${options[@]}"; do
        if [[ -n $choice ]]; then _hob_jump "${HOB_TO[${choice,,}]}" picker "$query" "$(( REPLY - 1 ))"; return; fi
        _hob_err 'cancelled'
        return 1
    done
    return 1
}

_hob_to() {
    local IFS=' '
    local key=${*,,}
    if (( $# == 0 )); then
        if [[ -t 0 && -t 1 ]]; then _hob_pick ''; else _hob_list_places; fi
        return
    fi
    if [[ -n ${HOB_TO[$key]+x} ]]; then _hob_jump "${HOB_TO[$key]}" to "$key"; return; fi
    if [[ -n ${HOB_TO_AMBIG[$key]+x} ]]; then
        if [[ -t 0 && -t 1 ]]; then _hob_pick "$key" "${HOB_TO_AMBIG[$key]}"; return; fi
        _hob_err "'$*' could be: ${HOB_TO_AMBIG[$key]}. Be more specific, for example 'h to ${HOB_TO_AMBIG[$key]%%,*}'."
        return 1
    fi
    _hob_err "no place called '$*'. 'h to' lists them all."
    return 1
}

_hob_plugin() {
    local w1=${1,,} plugin key child
    plugin=${HOB_PLUG[$w1]}
    if [[ -z $plugin ]]; then
        if [[ -n ${HOB_PLUG_AMBIG[$w1]+x} ]]; then _hob_err "'$1' is ambiguous in hob: ${HOB_PLUG_AMBIG[$w1]}"
        elif [[ -n ${HOB_TO[$w1]+x} || -n ${HOB_TO_AMBIG[$w1]+x} ]]; then _hob_err "'$1' is a place. Did you mean 'h to $1'?"
        else _hob_err "'$1' is not something hob knows. Try 'hob list'."; fi
        return 1
    fi
    if (( $# == 1 )); then
        if [[ -n ${HOB_ROOT[$plugin]} ]]; then _hob_jump "${HOB_ROOT[$plugin]}" direct; return; fi
        echo "$plugin: ${HOB_SUB[$plugin]}"
        return
    fi
    key="$plugin ${2,,}"
    if [[ -n ${HOB_GO[$key]+x} ]]; then _hob_jump "${HOB_GO[$key]}" direct; return; fi
    if [[ -n ${HOB_RUN[$key]+x} ]]; then shift 2; _hob_run "${HOB_RUN[$key]}" "$@"; return; fi
    if [[ -n ${HOB_CHILD_AMBIG[$key]+x} ]]; then _hob_err "'$2' is ambiguous in $plugin: ${HOB_CHILD_AMBIG[$key]}"
    else _hob_err "'$2' is not something $plugin knows. Try 'hob list'."; fi
    return 1
}

hob() {
    _hob_load || return 1
    case ${1,,} in
        '' | list)
            local name
            for name in "${HOB_TOP[@]}"; do echo "  $name"; done ;;
        to | cd) shift; _hob_to "$@" ;;
        back) popd > /dev/null 2>&1 || { _hob_err 'nothing to go back to'; return 1; } ;;
        recent | naive) _hob_err "'$1' is PowerShell-only in this spike"; return 1 ;;
        *) _hob_plugin "$@" ;;
    esac
}

_hob_complete() {
    _hob_load 2> /dev/null || return
    local cur=${COMP_WORDS[COMP_CWORD]} w plugin
    local -a words=("${COMP_WORDS[@]:1:COMP_CWORD-1}") pool=()
    [[ -n ${HOB_PLUG[${COMP_WORDS[0]}]} && ${COMP_WORDS[0]} != hob ]] && words=("${COMP_WORDS[0]}" "${words[@]}")
    if (( ${#words[@]} == 0 )); then pool=("${HOB_TOP[@]}")
    elif [[ ${words[0],,} == to || ${words[0],,} == cd ]]; then
        if (( ${#words[@]} == 1 )); then
            # A shared name completes to its qualified form, so match on the bare name as well.
            COMPREPLY=()
            for w in "${HOB_TOCOMP[@]}"; do
                [[ ${w%%|*} == "${cur,,}"* || ${w#*|} == "${cur,,}"* ]] && COMPREPLY+=("${w%%|*}")
            done
            return
        elif (( ${#words[@]} == 2 )); then
            plugin=${HOB_PLUG[${words[1],,}]}
            for w in ${HOB_SUB[$plugin]}; do [[ -n ${HOB_GO["$plugin $w"]+x} ]] && pool+=("$w"); done
        fi
    elif (( ${#words[@]} == 1 )); then
        plugin=${HOB_PLUG[${words[0],,}]}
        [[ -n $plugin ]] && pool=(${HOB_SUB[$plugin]})
    fi
    COMPREPLY=()
    for w in "${pool[@]}"; do [[ ${w,,} == "${cur,,}"* ]] && COMPREPLY+=("$w"); done
}

_hob_setup() {
    local alias=${HOB_ALIAS-h} name loaded='hob spike loaded'
    local -a names=(hob)
    _hob_load || return 1
    if [[ -n $alias ]]; then
        if _hob_taken "$alias"; then _hob_err "skipped alias '$alias' because it would hide an existing command"
        else alias "$alias=hob"; names+=("$alias"); loaded+=" | prefix alias: $alias"; fi
    fi
    if [[ -z $HOB_NO_SHORTCUTS ]]; then
        local made=
        for name in "${HOB_SHORT[@]}"; do
            [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || continue
            if _hob_taken "$name"; then _hob_err "skipped shortcut '$name' because it would hide an existing command"; continue; fi
            alias "$name=hob $name"
            names+=("$name")
            made+="$name "
        done
        [[ -n $made ]] && loaded+=" | shortcuts: ${made% }"
    fi
    complete -F _hob_complete "${names[@]}"
    echo "$loaded"
}
_hob_setup
