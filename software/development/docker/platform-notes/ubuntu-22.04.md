# Docker on Ubuntu 22.04 — Platform Notes

The install script targets Ubuntu 24.04. On 22.04, the GPG key setup differs
because `install -m 0755 -d /etc/apt/keyrings` may not be available in older
apt versions.

## Manual install steps for Ubuntu 22.04

Run these commands instead of `scripts/install.sh`:

```bash
# 1. Install prerequisites
sudo apt-get install -y ca-certificates curl gnupg

# 2. Create keyrings directory the 22.04 way
sudo mkdir -p /etc/apt/keyrings

# 3. Add Docker's GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# 4. Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. Install
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
```

After installing, run `scripts/configure.sh` normally — it is identical on
both platforms.
