# Gaming Profile

Gaming-focused setup. Assumes the platform baseline is already complete.

> **Applies to:** Ubuntu 24.04 (primary) · Ubuntu 22.04
>
> Windows 11: use Windows-native installers — see each module's platform notes.

---

## Setup sequence

### 1. Platform baseline (if not already done)

- [ ] [System update](../platforms/ubuntu-24.04/scripts/01-system-update.sh) `[all]`
- [ ] [Core packages](../platforms/ubuntu-24.04/scripts/02-core-packages.sh) `[all]`
- [ ] [Shell setup](../platforms/ubuntu-24.04/scripts/03-shell-setup.sh) `[all]`
- [ ] [SSH config](../platforms/ubuntu-24.04/scripts/04-ssh-config.sh) `[all]`

### 2. Gaming software

- [ ] [Steam — install](../software/gaming/steam/scripts/install.sh) `[gaming]`

### 3. Post-install

- Enable Steam Play (Proton) for Windows game compatibility:
  **Steam → Settings → Compatibility → Enable Steam Play for all titles**
