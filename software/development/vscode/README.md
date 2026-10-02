# Visual Studio Code

> **Profiles:** `[workstation]`
> **Platforms:** ubuntu-24.04 (primary)

Microsoft's code editor, installed from Microsoft's **official apt repository**
so it updates through `apt` with the rest of the system, plus a declarative list
of extensions.

## Why the official apt repo

Microsoft publishes VS Code as a `.deb` with a first-party apt repository and as
a classic snap. This module uses the apt repository, following the manual steps
on <https://code.visualstudio.com/docs/setup/linux> (read 2026-10-01):

1. Fetch `https://packages.microsoft.com/keys/microsoft.asc`, dearmor it, and
   install it to `/usr/share/keyrings/microsoft.gpg`.
2. Write `/etc/apt/sources.list.d/vscode.sources`:

   ```
   Types: deb
   URIs: https://packages.microsoft.com/repos/code
   Suites: stable
   Components: main
   Architectures: amd64,arm64,armhf
   Signed-By: /usr/share/keyrings/microsoft.gpg
   ```

3. `apt-get update` + `apt-get install code`.

These are the same paths the `code` package's own postinst manages, so a later
package upgrade rewrites them in place instead of adding a second source.

## Snap vs apt

`install.sh` checks for a `code` binary on PATH **first**. If one is there, from
any source, it skips the whole apt path before any `sudo` and goes straight to
extensions. That keeps a machine that already has the snap (marcus-desktop, as
of 2026-10-01: snap `code` 1.140.0, `latest/stable`, classic) from ending up
with two copies.

To move such a machine onto apt, do it by hand; the snap and the `.deb` share
`~/.config/Code` and `~/.vscode/extensions`, so settings and extensions carry
over:

```bash
sudo snap remove code
bash scripts/install.sh
```

## Install

```bash
bash scripts/install.sh
```

Idempotent: the keyring (valid per `gpg --show-keys`), the apt source (names the
Microsoft repo) and the package (`dpkg -s code`) are each guarded, so a second
run skips every step before reaching `sudo`. It ends by running
`scripts/configure.sh`.

## Extensions

`canonical/extensions.txt` is the declared list, one Marketplace ID per line,
seeded from `code --list-extensions` on marcus-desktop. `scripts/configure.sh`
diffs it against `code --list-extensions` (case-insensitive) and installs only
what is missing. It needs no `sudo`, never uninstalls anything, and warns about
installed extensions that are not declared.

```bash
bash scripts/configure.sh                       # install missing extensions
diff <(grep -vE '^[[:space:]]*(#|$)' canonical/extensions.txt | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]' | sort -u) \
     <(code --list-extensions | tr '[:upper:]' '[:lower:]' | sort -u)   # see drift, compared as configure.sh does
```

## User settings are not managed

This repo has no convention for tracking personal dotfiles (the `canonical/`
directories elsewhere hold harness payloads, not application preferences), so
this module **does not** track, link or copy VS Code settings. They live in:

| File | Holds |
|---|---|
| `~/.config/Code/User/settings.json` | user settings |
| `~/.config/Code/User/keybindings.json` | keybindings |
| `~/.config/Code/User/snippets/` | user snippets |
| `~/.config/Code/User/profiles/` | named profiles |
| `~/.vscode/extensions/` | installed extensions |

Use VS Code's built-in Settings Sync if you want these carried between machines.

## Verify

```bash
bash scripts/verify.sh
```

Checks that `code` is on PATH and reports a version, that an update channel
exists (the apt source, or the snap, which warns and skips), and that every
declared extension is installed. Exit 0 means all checks passed.

## Uninstall

```bash
bash scripts/uninstall.sh          # dry run: prints what would go and what stays
bash scripts/uninstall.sh --yes    # remove the apt package, source, and keyring
```

Removes the apt package and `vscode.sources`. Removes `microsoft.gpg` only if no
other apt source references it (Edge and `packages-microsoft-prod` use the same
filename). Keeps `~/.config/Code`, `~/.vscode/extensions`, and any snap
install, which this module did not create.

## Updating

```bash
sudo apt-get update && sudo apt-get upgrade      # apt install
snap refresh code                                # snap install (automatic anyway)
```

Microsoft notes the apt repository can lag a new release by up to three hours.
