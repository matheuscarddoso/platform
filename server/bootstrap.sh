#!/usr/bin/env bash
# Idempotent provisioning for the production VPS (Ubuntu 26.04 LTS).
# Safe to re-run at any time: every step converges to the desired state.
#
#   rsync -a server/ root@HOST:/opt/platform/ && ssh root@HOST /opt/platform/bootstrap.sh
set -Eeuo pipefail
trap 'echo "bootstrap failed at line $LINENO" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$HERE/files"
SWAP_SIZE="${SWAP_SIZE:-4G}"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
export NEEDRESTART_MODE=a

log() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# install_file <src> <dst> <mode>: copies only when content differs, returns 0 if changed.
install_file() {
  local src="$1" dst="$2" mode="$3"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then return 1; fi
  install -D -m "$mode" "$src" "$dst"
  echo "  updated $dst"
}

PUBLIC_IF="$(ip -o route show default | awk '{print $5; exit}')"
[[ -n "$PUBLIC_IF" ]] || { echo "could not detect public interface" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "System packages"
apt-get update -q
apt-get -yq -o Dpkg::Options::=--force-confold upgrade
apt-get -yq install --no-install-recommends \
  ca-certificates curl gnupg jq ufw fail2ban unattended-upgrades needrestart \
  apt-listchanges htop ncdu rsync

# ---------------------------------------------------------------------------
log "SSH hardening (keys only)"
if install_file "$FILES/ssh/00-hardening.conf" /etc/ssh/sshd_config.d/00-hardening.conf 0644; then
  sshd -t
  systemctl reload ssh
fi

# ---------------------------------------------------------------------------
log "Kernel tuning (BBR, network, memory)"
install_file "$FILES/sysctl/99-platform.conf" /etc/sysctl.d/99-platform.conf 0644 || true
echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr
sysctl --quiet --system

# ---------------------------------------------------------------------------
log "Swap ($SWAP_SIZE)"
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ---------------------------------------------------------------------------
log "journald retention"
if install_file "$FILES/journald/platform.conf" /etc/systemd/journald.conf.d/platform.conf 0644; then
  systemctl restart systemd-journald
fi

# ---------------------------------------------------------------------------
log "Unattended security upgrades"
install_file "$FILES/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades 0644 || true
install_file "$FILES/apt/52platform-unattended" /etc/apt/apt.conf.d/52platform-unattended 0644 || true
install_file "$FILES/needrestart/platform.conf" /etc/needrestart/conf.d/platform.conf 0644 || true
systemctl enable --now unattended-upgrades.service >/dev/null

# ---------------------------------------------------------------------------
log "fail2ban"
if install_file "$FILES/fail2ban/jail.local" /etc/fail2ban/jail.local 0644; then
  systemctl restart fail2ban
fi
systemctl enable --now fail2ban >/dev/null

# ---------------------------------------------------------------------------
log "Docker Engine (official repository)"
if ! command -v docker >/dev/null; then
  . /etc/os-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  # Docker's release signing key fingerprint, published at docs.docker.com/engine/install/ubuntu
  gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc \
    | grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:$' \
    || { echo "Docker GPG key fingerprint mismatch" >&2; exit 1; }
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -q
  apt-get -yq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  # Merge: keep keys written by other tools (Coolify), enforce ours.
  merged="$(jq -s '.[0] * .[1]' /etc/docker/daemon.json "$FILES/docker/daemon.json")"
  if [[ "$merged" != "$(jq . /etc/docker/daemon.json)" ]]; then
    printf '%s\n' "$merged" > /etc/docker/daemon.json
    systemctl restart docker
  fi
else
  install -m 0644 "$FILES/docker/daemon.json" /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker containerd >/dev/null

# ---------------------------------------------------------------------------
log "Firewall: host (ufw) + container ports (DOCKER-USER allowlist)"
# Docker publishes ports through DNAT in the FORWARD path, which ufw's INPUT
# rules never see. The DOCKER-USER chain is the supported hook to filter it:
# only 80/443 may reach containers from the internet; everything else a
# container publishes (Coolify UI 8000, websockets 6001/6002, Traefik 8080...)
# stays reachable only from the host itself (SSH tunnel).
for fam in "" 6; do
  rules="/etc/ufw/after${fam}.rules"
  sed -i '/^# BEGIN platform-docker-user$/,/^# END platform-docker-user$/d' "$rules"
  sed "s/__PUBLIC_IF__/$PUBLIC_IF/g" "$FILES/ufw/docker-user.rules" >> "$rules"
done
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw --force default deny routed >/dev/null    # Docker accepts its own bridge traffic ahead of ufw
ufw allow 22/tcp comment 'ssh' >/dev/null
ufw allow 80/tcp comment 'http' >/dev/null
ufw allow 443/tcp comment 'https' >/dev/null
ufw allow 443/udp comment 'http3' >/dev/null
ufw --force enable >/dev/null
ufw reload >/dev/null

# ---------------------------------------------------------------------------
log "CI deploy user (forced-command SSH, no shell, no docker access)"
id deploy >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/deploy --shell /bin/sh deploy
passwd -l deploy >/dev/null
install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
touch /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 0600 /home/deploy/.ssh/authorized_keys
install -d -m 0750 -o root -g deploy /etc/ci-deploy /etc/ci-deploy/apps
install -m 0755 "$HERE/ci-deploy" /usr/local/bin/ci-deploy

log "Done"
echo "  interface: $PUBLIC_IF"
echo "  docker:    $(docker --version)"
echo "  swap:      $(swapon --show=SIZE --noheadings | xargs)"
echo "  tcp cc:    $(sysctl -n net.ipv4.tcp_congestion_control)"
