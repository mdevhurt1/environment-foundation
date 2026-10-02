#!/usr/bin/env bash
# Description: Offline test of the README's apt post-invoke hook install block.
#              Runs that block as written, with sudo dropped and its root paths
#              moved into a temp dir, against stubbed dpkg-query and docker:
#              the first nvidia driver upgrade after install must restart
#              ollama, and an unrelated dpkg run must not.
#              Touches no real apt config, stamp or container.
# Profiles:    workstation
# Platforms:   ubuntu-24.04
# Dependencies: bash, awk, sed, mktemp
# Idempotent.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="$(cd "$here/../../../.." && pwd)"
# shellcheck source=../../../../shared/logging.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/shared/logging.sh"

require_not_root

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/sbin" "$tmp/apt" "$tmp/var"

# The fenced bash block that installs the hook, rooted in $tmp.
awk '/^```bash$/ { blk = ""; inb = 1; next }
     inb && /^```$/ { inb = 0; if (blk ~ /restart-ollama-on-nvidia-change/) printf "%s", blk; next }
     inb { blk = blk $0 "\n" }' "$here/../README.md" \
    | sed -e 's/sudo //g' \
          -e "s#/usr/local/sbin/#$tmp/sbin/#g" \
          -e "s#/etc/apt/apt.conf.d/#$tmp/apt/#g" \
          -e "s#/var/lib/#$tmp/var/#g" > "$tmp/install-block.sh"
grep -q 'restart-ollama-on-nvidia-change' "$tmp/install-block.sh" \
    || { echo 'FAIL: hook install block not found in README.md'; exit 1; }

# Stubs: dpkg-query reports $tmp/pkgs; docker logs each restart.
cat > "$tmp/bin/dpkg-query" <<STUB
#!/usr/bin/env bash
cat "$tmp/pkgs"
STUB
cat > "$tmp/bin/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
    ps) echo abc123 ;;
    restart) echo restart >> "$tmp/restarts" ;;
esac
STUB
chmod +x "$tmp/bin/dpkg-query" "$tmp/bin/docker"

restarts() { [ -f "$tmp/restarts" ] && wc -l < "$tmp/restarts" || echo 0; }
dpkg_run() { PATH="$tmp/bin:$PATH" "$tmp/sbin/restart-ollama-on-nvidia-change"; }

install_fresh() {  # a clean machine with driver 570.1, then the install block
    rm -rf "$tmp/sbin" "$tmp/apt" "$tmp/var" "$tmp/restarts"
    mkdir -p "$tmp/sbin" "$tmp/apt" "$tmp/var"
    printf 'nvidia-driver-570 570.1\nlibnvidia-compute-570 570.1\n' > "$tmp/pkgs"
    PATH="$tmp/bin:$PATH" bash "$tmp/install-block.sh" >/dev/null
    [ "$(restarts)" -eq 0 ] || { echo 'FAIL: installing the hook restarted ollama'; exit 1; }
}

# The first dpkg run after install is an unrelated one: no restart.
install_fresh
dpkg_run
[ "$(restarts)" -eq 0 ] || { echo 'FAIL: unrelated first dpkg run restarted ollama'; exit 1; }

# The first dpkg run after install is the driver upgrade: restart.
install_fresh
printf 'nvidia-driver-570 570.2\nlibnvidia-compute-570 570.2\n' > "$tmp/pkgs"
dpkg_run
[ "$(restarts)" -eq 1 ] || { echo "FAIL: first driver upgrade after install did not restart ollama (restarts=$(restarts))"; exit 1; }
echo 'PASS: hook acts on the first driver upgrade after install, not on an unrelated dpkg run'
