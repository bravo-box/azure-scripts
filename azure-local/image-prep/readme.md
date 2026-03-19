# Azure VM Image Prep for Non-Azure Boot

This folder contains a script to prepare a RHEL VM that was originally created in Azure so it can boot and initialize outside Azure (for example in Azure Local, lab hypervisors, or disconnected environments).

## Script

- `generalize-rhel.sh`

## What the Script Changes

By default, the script performs full generalization for image capture:

- Updates cloud-init datasource config to non-Azure values.
- Backs up any existing datasource config before replacing it.
- Disables and masks Azure Linux Agent (`waagent`) unless explicitly kept.
- Clears cloud-init cache and logs (`/var/lib/cloud`, `/var/log`, `/tmp`).
- Cleans package manager metadata (`dnf` or `yum`).
- Removes host identity artifacts and clears user bash history.

Use `--no-deprovision` when you want only datasource/agent/cache preparation without host/user generalization.

## Requirements

- RHEL-based Linux VM
- Root privileges (`sudo`)
- `bash`
- `systemd`/`systemctl` (for waagent service management)

## Usage

Run from the repository root:

```bash
sudo ./azure-local/image-prep/generalize-rhel.sh
```

### Options

- `--datasources "NoCloud, ConfigDrive, None"`
  - Overrides cloud-init datasource list written to `/etc/cloud/cloud.cfg.d/91-azure_datasource.cfg`.
- `--deprovision`
  - Forces generalized image cleanup (default behavior).
- `--no-deprovision`
  - Skips host and user generalization cleanup.
- `--waagent-deprovision-user`
  - Runs `waagent -force -deprovision+user` (destructive). Implies `--deprovision`.
- `--keep-waagent`
  - Keeps Azure Linux Agent enabled and running.
- `-h`, `--help`
  - Displays help.

### Examples

```bash
# Default safe prep
sudo ./azure-local/image-prep/generalize-rhel.sh

# Prep only (no host/user generalization)
sudo ./azure-local/image-prep/generalize-rhel.sh --no-deprovision

# Explicit generalize for image capture (same as default)
sudo ./azure-local/image-prep/generalize-rhel.sh --deprovision

# Generalize and deprovision user metadata via waagent
sudo ./azure-local/image-prep/generalize-rhel.sh --deprovision --waagent-deprovision-user

# Keep waagent and set simpler datasource order
sudo ./azure-local/image-prep/generalize-rhel.sh --keep-waagent --datasources "NoCloud, None"
```

## Deprovision Mode Details

When `--deprovision` is used, the script additionally:

- Removes SSH host keys from `/etc/ssh/ssh_host_*`
- Removes `/etc/lvm/devices/system.devices`
- Clears machine identity:
  - truncates `/etc/machine-id`
  - resets `/var/lib/dbus/machine-id` symlink
- Removes files under `/etc/sysconfig/network-scripts`
- Clears temporary files under `/var/tmp`
- Removes bash history for root and local interactive users

Use this mode only when creating a reusable image.

If `--waagent-deprovision-user` is specified, `waagent -force -deprovision+user` is also executed.

## Verification

After running the script, verify the key outcomes:

```bash
# 1) Confirm cloud-init datasource setting
sudo cat /etc/cloud/cloud.cfg.d/91-azure_datasource.cfg

# 2) Confirm waagent state (unless --keep-waagent was used)
systemctl status waagent --no-pager

# 3) Confirm cloud-init cache is cleared
sudo ls -la /var/lib/cloud/
```

If preparing an image, reboot and validate first-boot behavior in the target environment.

## Rollback

The script creates a timestamped backup of the datasource config when one exists:

- `/etc/cloud/cloud.cfg.d/91-azure_datasource.cfg.bak.<timestamp>`

To restore:

```bash
sudo cp -a /etc/cloud/cloud.cfg.d/91-azure_datasource.cfg.bak.<timestamp> \
  /etc/cloud/cloud.cfg.d/91-azure_datasource.cfg
```

If you disabled waagent and need it again:

```bash
sudo systemctl unmask waagent
sudo systemctl enable --now waagent
```

## Operational Notes

- Test in non-production first.
- Do not run `--deprovision` on a VM you intend to keep as-is.
- Reboot after prep before final validation or image capture.
