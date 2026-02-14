# fish completion for melon AUR helper

# Commands
complete -c melon -f -n '__fish_use_subcommand' -a '-S' -d 'Install packages (repo first, AUR fallback)'
complete -c melon -f -n '__fish_use_subcommand' -a '-Ss' -d 'Search repos + AUR'
complete -c melon -f -n '__fish_use_subcommand' -a '-Si' -d 'Show package info'
complete -c melon -f -n '__fish_use_subcommand' -a '-Qs' -d 'Search locally installed packages'
complete -c melon -f -n '__fish_use_subcommand' -a '-Syu' -d 'Full upgrade (pacman sync + AUR)'
complete -c melon -f -n '__fish_use_subcommand' -a '-Sua' -d 'Upgrade only AUR packages'
complete -c melon -f -n '__fish_use_subcommand' -a '-Qu' -d 'Check for updates (repo + AUR)'
complete -c melon -f -n '__fish_use_subcommand' -a '-Qua' -d 'Check for AUR updates only'
complete -c melon -f -n '__fish_use_subcommand' -a '-Qm' -d 'List foreign packages'
complete -c melon -f -n '__fish_use_subcommand' -a '-G' -d 'Clone AUR package repo(s)'
complete -c melon -f -n '__fish_use_subcommand' -a '-Sc' -d 'Clean pacman + melon info cache'
complete -c melon -f -n '__fish_use_subcommand' -a '-Scc' -d 'Deep clean all caches'

# Package name completion for -S, -Si, -G
function __melon_list_packages
    pacman -Ssq $argv 2>/dev/null | head -100
end

function __melon_list_installed
    pacman -Qq 2>/dev/null
end

complete -c melon -f -n '__fish_seen_subcommand_from -S -Si -G -Ss' -a '(__melon_list_packages (commandline -ct))'
complete -c melon -f -n '__fish_seen_subcommand_from -R -Rns' -a '(__melon_list_installed)'

# Melon-specific options
complete -c melon -l version -d 'Show version'
complete -c melon -l dry-run -d 'Print actions without executing'
complete -c melon -l json -d 'Output machine-readable summaries'
complete -c melon -l assume-reviewed -d 'Skip AUR review prompts'
complete -c melon -l i-know-what-im-doing -d 'Required with --assume-reviewed in non-interactive'
complete -c melon -l cache-info -d 'Show melon cache info'
complete -c melon -l cache-clean -d 'Remove melon cache'
complete -c melon -l resume-failed -d 'Retry last failed package set'
complete -c melon -l bottomup -d 'Sort AUR search results bottom-up'
complete -c melon -l topdown -d 'Sort AUR search results top-down'

# Color
complete -c melon -l color -xa 'auto always never' -d 'Control color output'

# Toggle options
complete -c melon -l pgpfetch -d 'Import PGP keys from PKGBUILDs'
complete -c melon -l nopgpfetch -d 'Skip PGP key import'
complete -c melon -l useask -d 'Auto-resolve conflicts with pacman ask'
complete -c melon -l nouseask -d 'Do not auto-resolve conflicts'
complete -c melon -l savechanges -d 'Commit PKGBUILD changes during review'
complete -c melon -l nosavechanges -d 'Do not commit PKGBUILD changes'
complete -c melon -l newsonupgrade -d 'Show Arch news during sysupgrade'
complete -c melon -l nonewsonupgrade -d 'Skip Arch news'
complete -c melon -l combinedupgrade -d 'Combine repo and AUR upgrade'
complete -c melon -l nocombinedupgrade -d 'Separate repo and AUR upgrade'
complete -c melon -l batchinstall -d 'Build multiple AUR packages then install together'
complete -c melon -l nobatchinstall -d 'Install AUR packages one by one'
complete -c melon -l provides -d 'Search for providers'
complete -c melon -l noprovides -d 'Skip provider search'
complete -c melon -l devel -d 'Check development packages during sysupgrade'
complete -c melon -l nodevel -d 'Skip development packages'
complete -c melon -l installdebug -d 'Install debug packages when available'
complete -c melon -l noinstalldebug -d 'Skip debug packages'
complete -c melon -l sudoloop -d 'Loop sudo calls in background'
complete -c melon -l nosudoloop -d 'Do not loop sudo'
complete -c melon -l chroot -d 'Build in chroot'
complete -c melon -l nochroot -d 'Build without chroot'
complete -c melon -l failfast -d 'Exit on first build failure'
complete -c melon -l nofailfast -d 'Continue on build failure'
complete -c melon -l keepsrc -d 'Keep src/pkg dirs after build'
complete -c melon -l nokeepsrc -d 'Clean src/pkg dirs after build'
complete -c melon -l sign -d 'Sign packages with gpg'
complete -c melon -l nosign -d 'Do not sign packages'
complete -c melon -l signdb -d 'Sign databases with gpg'
complete -c melon -l nosigndb -d 'Do not sign databases'
complete -c melon -l localrepo -d 'Build into local repo'
complete -c melon -l nolocalrepo -d 'Do not use local repo'
complete -c melon -l rebuild -d 'Force rebuild of target packages'
