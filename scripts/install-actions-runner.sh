#!/usr/bin/env bash
#
# install-actions-runner.sh — install a GitHub Actions org self-hosted runner.
#
# Layout this script produces:
#   user:    github-runner  (dedicated account, member of `docker` group)
#   dir:     /home/github-runner/actions-runner
#   service: actions.runner.<org>.<host>.service  (systemd, enabled, started)
#
# Prerequisites (NOT done by this script — require human + Dashboard):
#   1. Docker installed and `docker` group present on the host.
#   2. GitHub organization runner group created (e.g. `jaram-deploy`) with
#      repository access restricted to the repos that should use this runner.
#      UI: https://github.com/organizations/<ORG>/settings/actions
#          -> Runner groups -> New runner group
#   3. One-time registration token issued from inside that runner group's UI.
#      Tokens expire ~1 hour after issue. The token is a secret; do not log it.
#
# Usage (run with sudo; token is consumed on successful registration):
#   sudo ./install-actions-runner.sh <REGISTRATION_TOKEN> [RUNNER_GROUP]
#
# Examples:
#   sudo ./install-actions-runner.sh AAAAAAA...CGIBXQ jaram-deploy
#   sudo ./install-actions-runner.sh AAAAAAA...CGIBXQ            # Default group
#
# Idempotent: safe to re-run. Existing user, install dir, registration, and
# service file are detected and preserved. Re-run only re-extracts the runner
# binary if config.sh is missing, and re-issues `systemctl restart` if the
# unit file is present.
#
# Exit codes:
#   0  success (or already-installed idempotent re-run)
#   1  not root, missing prerequisite, sha mismatch, systemd unit install fail
#   2  usage error (missing token argument)
#
# Upgrading the runner version:
#   1. Update RUNNER_VERSION below.
#   2. Update RUNNER_SHA256 to the matching value from
#      https://api.github.com/repos/actions/runner/releases/latest
#      (asset `actions-runner-linux-x64-<VERSION>.tar.gz`, `digest` field).
#   3. Stop the service, remove the install dir, re-run this script with a
#      fresh registration token.
#
set -euo pipefail

# --- configuration --------------------------------------------------------
ORG_URL="https://github.com/jaram-plus"
ORG_NAME="$(basename "$ORG_URL")"
LABELS="self-hosted,linux,x64,jaram-vm,deploy"
RUNNER_USER="github-runner"
INSTALL_DIR="/home/${RUNNER_USER}/actions-runner"

# Pinned runner release. Update both together (see "Upgrading" above).
RUNNER_VERSION="2.335.1"
RUNNER_SHA256="4ef2f25285f0ae4477f1fe1e346db76d2f3ebf03824e2ddd1973a2819bf6c8cf"

TARBALL_CACHE="/tmp/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
VERIFY_URL="https://github.com/organizations/${ORG_NAME}/settings/actions/runners"

# --- args -----------------------------------------------------------------
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <REGISTRATION_TOKEN> [RUNNER_GROUP]" >&2
  exit 2
fi
TOKEN="$1"
RUNNER_GROUP="${2:-}"
if [ -n "$RUNNER_GROUP" ]; then
  GROUP_FLAG=(--runnergroup "$RUNNER_GROUP")
else
  GROUP_FLAG=()
fi

# --- preflight ------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (use sudo)." >&2
  exit 1
fi
if ! getent group docker >/dev/null; then
  echo "ERROR: 'docker' group does not exist. Install Docker first." >&2
  exit 1
fi

# --- download (or reuse cached) tarball -----------------------------------
download_tarball() {
  local url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  echo "[download] fetching ${url}"
  curl -fsSL -o "$TARBALL_CACHE" "$url"
}

if [ ! -f "$TARBALL_CACHE" ]; then
  download_tarball
fi

actual_sha="$(sha256sum "$TARBALL_CACHE" | awk '{print $1}')"
if [ "$actual_sha" != "$RUNNER_SHA256" ]; then
  echo "ERROR: tarball sha256 mismatch." >&2
  echo "       expected: ${RUNNER_SHA256}" >&2
  echo "       actual:   ${actual_sha}" >&2
  echo "       (cached at ${TARBALL_CACHE}; delete to force re-download)" >&2
  exit 1
fi
echo "[preflight] tarball sha256 OK"

# --- user -----------------------------------------------------------------
if id "$RUNNER_USER" >/dev/null 2>&1; then
  echo "[user] ${RUNNER_USER} already exists"
else
  useradd -m -s /bin/bash "$RUNNER_USER"
  echo "[user] created ${RUNNER_USER}"
fi
if id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -qx docker; then
  echo "[user] ${RUNNER_USER} already in docker group"
else
  usermod -aG docker "$RUNNER_USER"
  echo "[user] added ${RUNNER_USER} to docker group"
fi

# --- dir + chown (BEFORE extract; otherwise RUNNER_USER can't write) -----
# Own both /home/<RUNNER_USER> (probably already, from useradd -m) and the
# install dir. Critical: install dir must be writable by RUNNER_USER before tar.
mkdir -p "$INSTALL_DIR"
chown -R "$RUNNER_USER:$RUNNER_USER" "$(dirname "$INSTALL_DIR")"

# --- extract --------------------------------------------------------------
if [ ! -f "$INSTALL_DIR/config.sh" ]; then
  echo "[install] extracting runner to ${INSTALL_DIR}"
  sudo -u "$RUNNER_USER" tar -xzf "$TARBALL_CACHE" -C "$INSTALL_DIR"
else
  echo "[install] ${INSTALL_DIR}/config.sh already present, skipping extract"
fi
chown -R "$RUNNER_USER:$RUNNER_USER" "$INSTALL_DIR"

# --- configure ------------------------------------------------------------
# Runner writes .credentials and .runner next to config.sh, so cwd must be
# $INSTALL_DIR when invoking. Skip if already configured.
if [ -f "$INSTALL_DIR/.credentials" ] || [ -f "$INSTALL_DIR/.runner" ]; then
  echo "[config] runner already configured (.credentials/.runner present), skipping config.sh"
else
  echo "[config] registering runner with org ${ORG_URL}"
  echo "[config] labels: ${LABELS}${RUNNER_GROUP:+ ; group: ${RUNNER_GROUP}}"
  (
    cd "$INSTALL_DIR"
    # -H sets HOME to target user's home (/home/<RUNNER_USER>).
    sudo -u "$RUNNER_USER" -H ./config.sh \
      --url "$ORG_URL" \
      --token "$TOKEN" \
      --labels "$LABELS" \
      --unattended \
      --replace \
      "${GROUP_FLAG[@]}"
  )
fi

# --- systemd service ------------------------------------------------------
# svc.sh install MUST run as root (it writes to /etc/systemd/system/). The
# argument is the user the service will run AS, not the invoking user.
if ls /etc/systemd/system/actions.runner.*.service >/dev/null 2>&1; then
  echo "[svc] systemd unit file already present"
else
  echo "[svc] installing systemd service (./svc.sh install ${RUNNER_USER})"
  (
    cd "$INSTALL_DIR"
    ./svc.sh install "$RUNNER_USER"
  )
fi

# --- enable + start (idempotent) ------------------------------------------
# svc.sh names org-runner units as actions.runner.<org>.<host>.service
# (NOT *-actions-runner.service), so discover the actual unit file instead
# of hardcoding the pattern.
systemctl daemon-reload
UNIT_FILE="$(ls /etc/systemd/system/actions.runner.*.service 2>/dev/null | head -1)"
if [ -n "$UNIT_FILE" ]; then
  UNIT_NAME="$(basename "$UNIT_FILE")"
  systemctl enable "$UNIT_NAME" 2>/dev/null || true
  systemctl restart "$UNIT_NAME"
  systemctl --no-pager --full status "$UNIT_NAME" --no-legend | head -20 || true
else
  echo "[svc] WARNING: no actions.runner.*.service unit file found in /etc/systemd/system" >&2
fi

echo
echo "=== DONE ==="
echo "Service unit (discovered): ${UNIT_NAME:-<none>}"
echo "Verify on GitHub: ${VERIFY_URL}"
