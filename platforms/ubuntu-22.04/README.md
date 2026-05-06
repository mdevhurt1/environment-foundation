# Ubuntu 22.04 LTS Baseline

Follows the same steps as the
[Ubuntu 24.04 baseline](../ubuntu-24.04/README.md). The exceptions below
apply — all other steps are identical.

## Differences from Ubuntu 24.04

### Python default version

Ubuntu 22.04 ships Python 3.10. Some software modules may require a newer
version. Where this matters, the module's `platform-notes/ubuntu-22.04.md`
documents the workaround (typically installing from the deadsnakes PPA).

### pip

22.04's default pip may be older. After the core packages step, upgrade it:

```bash
sudo apt-get install -y python3-pip
pip3 install --upgrade pip
```

### Docker GPG key path

Docker's official instructions changed the GPG key location between 22.04 and
24.04. See
[software/development/docker/platform-notes/ubuntu-22.04.md](../../software/development/docker/platform-notes/ubuntu-22.04.md)
for the 22.04-specific install steps.

### snap behavior

22.04 uses snap more aggressively for some packages (e.g., Firefox). If a
package installs via snap unexpectedly, prefer the apt alternative or flatpak.
Remove the snap version first:

```bash
sudo snap remove <package>
sudo apt-get install -y <package>
```
