# Azure VM Image Prep for Non-Azure Boot

This folder contains a script to prepare a RHEL VM that was originally created in Azure so it can boot and initialize outside Azure (for example in Azure Local, lab hypervisors, or disconnected environments).

## Script

- `generalize-rhel.sh`

## What the Script Changes

By default, the script performs safe preparation steps:

- Updates cloud-init datasource config to non-Azure values.
- Backs up any existing datasource config before replacing it.
- Disables and masks Azure Linux Agent (`waagent`) unless explicitly kept.
- Clears cloud-init cache and logs.
- Cleans package manager metadata (`dnf` or `yum`).

Optional deprovision mode removes host identity artifacts for image capture workflows.

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
  - Enables generalized image cleanup.
- `--keep-waagent`
  - Keeps Azure Linux Agent enabled and running.
- `-h`, `--help`
  - Displays help.

### Examples

```bash
# Default safe prep
sudo ./azure-local/image-prep/generalize-rhel.sh

# Generalize for image capture
sudo ./azure-local/image-prep/generalize-rhel.sh --deprovision

# Keep waagent and set simpler datasource order
sudo ./azure-local/image-prep/generalize-rhel.sh --keep-waagent --datasources "NoCloud, None"
```

## Deprovision Mode Details

When `--deprovision` is used, the script additionally:

- Removes SSH host keys from `/etc/ssh/ssh_host_*`
- Clears machine identity:
  - truncates `/etc/machine-id`
  - resets `/var/lib/dbus/machine-id` symlink
- Removes legacy network scripts (`ifcfg-*`, `route-*`) under `/etc/sysconfig/network-scripts`
- Clears temporary files under `/tmp` and `/var/tmp`
- Removes `/root/.bash_history`

Use this mode only when creating a reusable image.

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
