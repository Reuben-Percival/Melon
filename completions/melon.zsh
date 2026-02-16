#compdef melon
# zsh completion for melon AUR helper

_melon_packages() {
    local -a pkgs
    pkgs=(${(f)"$(pacman -Ssq "$1" 2>/dev/null | head -100)"})
    _describe 'package' pkgs
}

_melon_installed_packages() {
    local -a pkgs
    pkgs=(${(f)"$(pacman -Qq 2>/dev/null)"})
    _describe 'installed package' pkgs
}

_melon() {
    local -a commands melon_opts

    commands=(
        '-S:install packages (repo first, AUR fallback)'
        '-Ss:search repos + AUR'
        '-Si:show package info'
        '-Qs:search locally installed packages'
        '-Syu:full upgrade (pacman sync + AUR updates)'
        '-Sua:upgrade only installed AUR packages'
        '-Qu:check for updates (repo + AUR)'
        '-Qua:check for AUR updates only'
        '-Qm:list foreign (AUR/manual) packages'
        '-G:clone AUR package repo to current directory'
        '-Sc:clean pacman cache + melon info cache'
        '-Scc:deep clean all caches'
        '-Cbd:prune all unused dependency packages'
    )

    melon_opts=(
        '--version[show version]'
        '--dry-run[print actions without executing]'
        '--json[output machine-readable summaries]'
        '--color=[control color output]:mode:(auto always never)'
        '--assume-reviewed[skip AUR review prompts]'
        '--i-know-what-im-doing[required with --assume-reviewed in non-interactive]'
        '--cache-info[show cache info]'
        '--cache-clean[remove melon cache]'
        '--resume-failed[retry last failed package set]'
        '--bottomup[sort AUR search results bottom-up]'
        '--topdown[sort AUR search results top-down]'
        '--pgpfetch[import PGP keys from PKGBUILDs]'
        '--nopgpfetch[skip PGP key import]'
        '--useask[auto-resolve conflicts with pacman ask]'
        '--nouseask[do not auto-resolve conflicts]'
        '--savechanges[commit PKGBUILD changes during review]'
        '--nosavechanges[do not commit PKGBUILD changes]'
        '--newsonupgrade[show Arch news during sysupgrade]'
        '--nonewsonupgrade[skip Arch news]'
        '--combinedupgrade[combine repo and AUR upgrade]'
        '--nocombinedupgrade[separate repo and AUR upgrade]'
        '--batchinstall[build multiple AUR packages then install together]'
        '--nobatchinstall[install AUR packages one by one]'
        '--provides[search for providers]'
        '--noprovides[skip provider search]'
        '--devel[check development packages during sysupgrade]'
        '--nodevel[skip development packages]'
        '--installdebug[install debug packages when available]'
        '--noinstalldebug[skip debug packages]'
        '--sudoloop[loop sudo calls in background]'
        '--nosudoloop[do not loop sudo]'
        '--chroot[build in chroot]'
        '--nochroot[build without chroot]'
        '--failfast[exit on first build failure]'
        '--nofailfast[continue on build failure]'
        '--keepsrc[keep src/pkg dirs after build]'
        '--nokeepsrc[clean src/pkg dirs after build]'
        '--sign[sign packages with gpg]'
        '--nosign[do not sign packages]'
        '--signdb[sign databases with gpg]'
        '--nosigndb[do not sign databases]'
        '--localrepo[build into local repo]'
        '--nolocalrepo[do not use local repo]'
        '--rebuild[force rebuild of target packages]'
    )

    _arguments -s \
        '1:command:->cmds' \
        '*:package:->pkgs' \
        $melon_opts

    case "$state" in
        cmds)
            _describe 'command' commands
            ;;
        pkgs)
            case "${words[2]}" in
                -S|-Si|-G|-Ss)
                    _melon_packages "$words[$CURRENT]"
                    ;;
                -R|-Rns)
                    _melon_installed_packages
                    ;;
            esac
            ;;
    esac
}

_melon "$@"
