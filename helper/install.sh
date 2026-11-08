#!/bin/bash
# Installs, updates or removes the privileged helper of the DMS plugin
# "Framework Charge Limit". Must run as root; the plugin runs it through pkexec,
# which asks for an administrator password:
#
#   pkexec /bin/bash helper/install.sh install     install or update
#   pkexec /bin/bash helper/install.sh uninstall   remove
#
# Files written (and nothing else):
#   /usr/local/libexec/dms-framework-charge-limit/charge-limit   the helper
#   /usr/local/libexec/dms-framework-charge-limit/uninstall      removes all of this
#   /usr/share/polkit-1/actions/io.github.hbouttev.dms-framework-charge-limit.policy

set -euo pipefail
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

readonly HELPER_DIR=/usr/local/libexec/dms-framework-charge-limit
readonly POLICY_DIR=/usr/share/polkit-1/actions
readonly POLICY=$POLICY_DIR/io.github.hbouttev.dms-framework-charge-limit.policy

SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SRC_DIR

die() {
    echo "error=$*" >&2
    exit 1
}

# Copies $1 to $2 with mode $3, atomically: a running pkexec never sees a partial file.
put() {
    local tmp
    tmp="$(dirname -- "$2")/.$(basename -- "$2").new"
    install -o root -g root -m "$3" -- "$1" "$tmp"
    mv -f -- "$tmp" "$2"
}

do_install() {
    [[ -d $POLICY_DIR ]] || die "polkit is not installed: $POLICY_DIR does not exist"
    command -v pkexec >/dev/null || die "pkexec (polkit) is not installed"
    local f
    for f in charge-limit uninstall polkit.policy; do
        [[ -f $SRC_DIR/$f ]] || die "missing $SRC_DIR/$f"
    done
    bash -n -- "$SRC_DIR/charge-limit" || die "$SRC_DIR/charge-limit is not a valid script"
    bash -n -- "$SRC_DIR/uninstall" || die "$SRC_DIR/uninstall is not a valid script"

    install -d -o root -g root -m 0755 -- "$HELPER_DIR"
    put "$SRC_DIR/charge-limit" "$HELPER_DIR/charge-limit" 0755
    put "$SRC_DIR/uninstall" "$HELPER_DIR/uninstall" 0755
    # Last, so that the passwordless rule never points to a missing or partial helper.
    put "$SRC_DIR/polkit.policy" "$POLICY" 0644

    "$HELPER_DIR/charge-limit" info | sed 's/^/installed./'
}

((EUID == 0)) || die "run as root, e.g. pkexec /bin/bash $0 ${1:-install}"

case "${1:-}" in
install)
    do_install
    ;;
uninstall)
    exec /bin/bash "$SRC_DIR/uninstall"
    ;;
*)
    die "usage: install.sh install | uninstall"
    ;;
esac
