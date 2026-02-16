#!/usr/bin/env bash
# bash completion for melon AUR helper

_melon() {
    local cur prev opts commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Core commands
    commands="-S -Ss -Si -Qs -Syu -Sua -Qu -Qua -Qm -G -Sc -Scc -Cbd -R -Rns -h --help"

    # Melon-specific options
    opts="--version --dry-run --json --color=auto --color=always --color=never
          --assume-reviewed --i-know-what-im-doing
          --cache-info --cache-clean --resume-failed
          --bottomup --topdown
          --pgpfetch --nopgpfetch
          --useask --nouseask
          --savechanges --nosavechanges
          --newsonupgrade --nonewsonupgrade
          --combinedupgrade --nocombinedupgrade
          --batchinstall --nobatchinstall
          --provides --noprovides
          --devel --nodevel
          --installdebug --noinstalldebug
          --sudoloop --nosudoloop
          --chroot --nochroot
          --failfast --nofailfast
          --keepsrc --nokeepsrc
          --sign --nosign
          --signdb --nosigndb
          --localrepo --nolocalrepo
          --rebuild"

    case "${prev}" in
        -S|-Si|-G)
            # Complete with available packages from pacman + AUR cache
            if command -v pacman &>/dev/null; then
                COMPREPLY=( $(compgen -W "$(pacman -Ssq "${cur}" 2>/dev/null | head -50)" -- "${cur}") )
            fi
            return 0
            ;;
        -R|-Rns)
            # Complete with installed packages
            if command -v pacman &>/dev/null; then
                COMPREPLY=( $(compgen -W "$(pacman -Qq 2>/dev/null)" -- "${cur}") )
            fi
            return 0
            ;;
        --color)
            COMPREPLY=( $(compgen -W "auto always never" -- "${cur}") )
            return 0
            ;;
    esac

    if [[ "${cur}" == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    elif [[ "${COMP_CWORD}" -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
    fi

    return 0
}

complete -F _melon melon
