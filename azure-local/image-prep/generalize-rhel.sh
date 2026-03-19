#!/usr/bin/env bash
set -euo pipefail

# Prepare a RHEL-based VM created in Azure so it can be cloned/moved and boot outside Azure.
# Default behavior is conservative and can be expanded with --deprovision for image capture workflows.

SCRIPT_NAME="$(basename "$0")"
DEFAULT_DATASOURCES="NoCloud, ConfigDrive, None"
DATASOURCES="$DEFAULT_DATASOURCES"
DEPROVISION=1
DISABLE_WAAGENT=1
WAAGENT_DEPROVISION_USER=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --datasources "NoCloud, ConfigDrive, None"  cloud-init datasources for non-Azure boots
  --deprovision                                force deprovision mode (default)
  --no-deprovision                             skip host/user generalization cleanup
  --waagent-deprovision-user                   run waagent -force -deprovision+user (destructive)
  --keep-waagent                               keep Azure Linux Agent enabled
  -h, --help                                   show this help

Examples:
  sudo ./$SCRIPT_NAME
  sudo ./$SCRIPT_NAME --no-deprovision
  sudo ./$SCRIPT_NAME --deprovision
  sudo ./$SCRIPT_NAME --deprovision --waagent-deprovision-user
  sudo ./$SCRIPT_NAME --datasources "NoCloud, None" --keep-waagent
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root. Re-run with sudo." >&2
    exit 1
  fi
}

backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    local backup="${src}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$src" "$backup"
    log "Backed up $src -> $backup"
  fi
}

write_nonazure_cloudinit() {
  local cfg_dir="/etc/cloud/cloud.cfg.d"
  local cfg_file="${cfg_dir}/91-azure_datasource.cfg"

  mkdir -p "$cfg_dir"
  backup_file "$cfg_file"

  cat > "$cfg_file" <<EOF
# Managed by $SCRIPT_NAME
# Force non-Azure cloud-init datasource probing for portable VM images.
datasource_list: [${DATASOURCES}]
EOF

  log "Wrote cloud-init datasource config: $cfg_file"
}

disable_waagent_if_present() {
  if [[ "$DISABLE_WAAGENT" -eq 0 ]]; then
    log "Skipping waagent disable because --keep-waagent was specified"
    return
  fi

  if systemctl list-unit-files | grep -q '^waagent\.service'; then
    systemctl disable --now waagent.service || true
    systemctl mask waagent.service || true
    log "Disabled and masked waagent.service"
  else
    log "waagent.service not found; skipping"
  fi
}

clean_cloudinit_cache() {
  if command -v cloud-init >/dev/null 2>&1; then
    cloud-init clean --logs || true
    rm -rf /var/lib/cloud/ /var/log/* /tmp/* || true
    log "Cleared cloud-init cache"
  else
    log "cloud-init not found; skipping cloud-init cleanup"
  fi
}

clean_vm_specific_details() {
  # These files are tied to one machine identity and should not be kept in a reusable image.
  rm -f /etc/ssh/ssh_host_* || true
  rm -f /etc/lvm/devices/system.devices || true

  if [[ -d /etc/sysconfig/network-scripts ]]; then
    find /etc/sysconfig/network-scripts -maxdepth 1 -type f -delete || true
  fi
}

clear_all_bash_histories() {
  rm -f /root/.bash_history || true

  while IFS=: read -r _ _ uid _ _ home shell; do
    if [[ "$uid" -ge 1000 ]] && [[ -d "$home" ]] && [[ "$shell" != "/sbin/nologin" ]] && [[ "$shell" != "/usr/sbin/nologin" ]] && [[ "$shell" != "/bin/false" ]]; then
      rm -f "$home/.bash_history" || true
    fi
  done < /etc/passwd

  export HISTSIZE=0
  export HISTFILESIZE=0
  unset HISTFILE || true
  log "Cleared bash history for root and local interactive users"
}

run_waagent_deprovision_user() {
  if [[ "$WAAGENT_DEPROVISION_USER" -ne 1 ]]; then
    return
  fi

  if command -v waagent >/dev/null 2>&1; then
    log "Running waagent -force -deprovision+user"
    waagent -force -deprovision+user || true
  else
    log "waagent binary not found; skipping --waagent-deprovision-user"
  fi
}

deprovision_host_identity() {
  if [[ "$DEPROVISION" -ne 1 ]]; then
    log "Deprovision mode not enabled; preserving host identity"
    return
  fi

  log "Deprovision mode enabled: removing host-specific state"

  clean_vm_specific_details

  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true
  ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

  rm -rf /var/tmp/* || true
  clear_all_bash_histories
  run_waagent_deprovision_user
}

clean_package_metadata() {
  if command -v dnf >/dev/null 2>&1; then
    dnf clean all || true
  elif command -v yum >/dev/null 2>&1; then
    yum clean all || true
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --datasources)
        DATASOURCES="${2:-}"
        if [[ -z "$DATASOURCES" ]]; then
          echo "--datasources requires a value" >&2
          exit 2
        fi
        shift 2
        ;;
      --deprovision)
        DEPROVISION=1
        shift
        ;;
      --no-deprovision)
        DEPROVISION=0
        WAAGENT_DEPROVISION_USER=0
        shift
        ;;
      --waagent-deprovision-user)
        WAAGENT_DEPROVISION_USER=1
        DEPROVISION=1
        shift
        ;;
      --keep-waagent)
        DISABLE_WAAGENT=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_root

  log "Starting non-Azure prep for RHEL VM"
  write_nonazure_cloudinit
  disable_waagent_if_present
  clean_cloudinit_cache
  clean_package_metadata
  deprovision_host_identity

  log "Completed. Reboot before validation or image capture."
}

main "$@"
