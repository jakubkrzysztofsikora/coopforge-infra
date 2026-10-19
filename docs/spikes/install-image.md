# Spike — automated OS install on a Hetzner dedicated root server

Date: 2026-10-18
Status: answered. Use `installimage` with an `/autosetup` config. The whole sequence is
scriptable over SSH; no interactive console is needed. Every command below was taken from the
`hetzneronline/installimage` sources (branch `master`, last push 2025-08-27) or from Hetzner's
own Robot documentation, not from memory. Live run is deferred (no Robot credentials, ruling R3).

## Verdict

| Option | Verdict |
| --- | --- |
| `installimage` + `/autosetup` config | **Chosen.** Unattended, one command, no editor, no console |
| `installimage` interactive (menu + `mcedit`) | Rejected — needs a human at a console, and a wrong keystroke leaves a half-installed box |
| Rescue + manual `debootstrap` | Rejected — more moving parts, no vendor support, and we would own the bootloader and RAID setup |
| Robot rescue activation alone | Not a full option — it gives a live root shell, not an installed system. It is the *precondition* for `installimage` |

The decisive detail: `installimage` reads the config from a fixed path and runs unattended when
that file exists.

```
config.sh:18   export AUTOSETUPCONFIG="/autosetup"
```

## How the unattended path actually works

`installimage` in the rescue system is a small wrapper that sources `config.sh` and
`get_options.sh`, then either starts the menu or `autosetup.sh`:

- `AUTOSETUPCONFIG=/autosetup` — if this file exists, `autosetup.sh` runs instead of the menu.
- `DEBUGFILE=/root/debug.txt` — the full log. This is what to send to Hetzner support, and what to
  read when a run fails.
- `IMAGESPATH="$SCRIPTPATH/../images/"` — the OS images are a directory next to the script, inside
  the rescue system. Enumerate them there; do not guess names.
- `-c <configfile>` copies the given config to `/autosetup` (`get_options.sh`, case `c`).

Flags that matter (from `get_options.sh -h`):

| Flag | Use |
| --- | --- |
| `-a` | Automode: no confirmations. Required for unattended runs |
| `-c <file>` | Config file. Relative names resolve inside the script's `configs/` directory, absolute paths are used as given |
| `-x <file>` | Post-install script, executed inside the chroot after installation |
| `-K <path\|url>` | Install SSH public keys from a file or URL |
| `-t yes\|no` | Take over the rescue system's SSH public keys (default `yes`) |
| `-n <hostname>` | Override `HOSTNAME` |
| `-i <image>` | Use a specific image instead of the one in the config |
| `-g` | Require a valid GPG signature on the image, abort otherwise |
| `-r yes\|no`, `-l <0\|1\|5\|6\|10>` | Software RAID on/off and level |
| `-d <drives>` | Devices to use, e.g. `nvme0n1,nvme1n1` |

Password handling, read from `get_options.sh`: the `-c` case prompts for a password **only if the
config file contains the literal string `PASSWD`**, and substitutes it into `/autosetup`. Our
config will not contain `PASSWD`, so `-a -c` stays non-interactive. SSH access is guaranteed by
keys instead, not by the password:

```
functions.sh:968  if OPT_USE_SSHKEYS != 1 and TAKE_OVER_RESCUE_SYSTEM_SSH_PUBLIC_KEYS == yes
                  and /root/.ssh/robot_user_keys is non-empty:
                      OPT_SSHKEYS_URL=/root/.ssh/robot_user_keys
```

`/root/.ssh/robot_user_keys` is populated in the rescue system from the keys we pass at rescue
activation (or at order time). With the default `TAKE_OVER_RESCUE_SYSTEM_SSH_PUBLIC_KEYS yes`,
those keys land in the installed system's root `authorized_keys` — so the same key that reached the
rescue system reaches the new system. `SSHKEYS_URL <url>` in the config, or `-K <url>`, is the
explicit alternative.

## Rescue system constraints

| Constraint | Value | Consequence |
| --- | --- | --- |
| Activation validity | One boot only | A reset consumes it; re-activate before every attempt |
| Activation window | 60 minutes from activation if no reboot happens | Do not activate, then go do something else |
| SSH ports | 22 and 222 | Try both; 222 is the fallback when 22 is filtered |
| Login | `root`, with the one-time rescue password, or an uploaded key | The password is returned by the activation API call and shown once |
| Root password after install | Follows the rescue/`PASSWD` handling | **Verify on the first box** rather than assume; key-based SSH is the primary path |

## Scripted sequence

Every step is either a Robot API call or an SSH command into the rescue system.

```bash
# 0. Prerequisites, once: Robot → Administration → Settings → Web Service Settings → Ordering ON,
#    and a Robot web-service user (ROBOT_USER / ROBOT_WS_PASSWORD). HTTP basic auth on
#    https://robot-ws.your-server.de

# 1. Register the SSH key we will use for both rescue and the installed system
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" -X POST https://robot-ws.your-server.de/key \
  -d "name=coopforge" --data-urlencode "public_key=$(cat ~/.ssh/coopforge.pub)"

# 2. Order (authorized_key[] is what populates /root/.ssh/robot_user_keys later)
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" -X POST \
  https://robot-ws.your-server.de/order/server/transaction \
  -d "product_id=$PRODUCT_ID" -d "location=$LOCATION" -d "authorized_key[]=$FINGERPRINT"

# 3. Wait for the box: poll until status is ready
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" https://robot-ws.your-server.de/server/$SERVER_NUMBER
#    -> server.status: "in process" | "ready"

# 4. Activate rescue (one boot, 60 min) and reset into it
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" -X POST \
  https://robot-ws.your-server.de/boot/$SERVER_NUMBER/rescue \
  -d "os=linux" -d "authorized_key[]=$FINGERPRINT"
curl -u "$ROBOT_USER:$ROBOT_WS_PASSWORD" -X POST \
  https://robot-ws.your-server.de/reset/$SERVER_NUMBER -d "type=hw"

# 5. Into the rescue system (key auth; try both ports)
ssh -p 22 root@$SERVER_IP

# 6. Clear any pre-existing software RAID before installimage runs
mdadm --stop /dev/md* 2>/dev/null || true
wipefs -fa /dev/nvme0n1 /dev/nvme1n1

# 7. Write the config and install
cat >/root/install.conf <<'CONF'
DRIVE1 /dev/nvme0n1
DRIVE2 /dev/nvme1n1
SWRAID 1
SWRAIDLEVEL 1
BOOTLOADER grub
HOSTNAME coopforge-seed-24g
PART /boot/efi esp 256M
PART /boot ext4 1G
PART /     ext4 all
IMAGE /root/images/Ubuntu-2404-noble-amd64-base.tar.gz
CONF
ls -1 "$(dirname "$(readlink -f "$(command -v installimage)")")/../images/"   # confirm the image name
installimage -a -c /root/install.conf

# 8. Reboot into the installed system
reboot
#    wait for SSH, then verify
ssh root@$SERVER_IP 'hostnamectl; lsblk; cat /proc/mdstat'
```

### Why these config values

- **Two NVMe drives, `SWRAID 1`.** Both GEX45 and GEX63 ship two NVMe drives and neither has a
  hardware RAID controller, so software RAID 1 is the only redundancy option. `SWRAIDLEVEL 1` is
  the level; the same `SWRAID 1` line only enables it.
- **`PART /boot/efi esp 256M` is mandatory in UEFI mode.** `functions.sh` errors with
  `ERROR: ESP missing or multiple ESP found` when `UEFI=1` and exactly one ESP is not declared. The
  script's own default partition set uses `PART /boot/efi esp 256M`. If a box turns out to boot
  legacy BIOS, that line must be dropped — omitting all `PART` lines and letting `installimage`
  generate its UEFI-aware default set is the safe fallback.
- **`/boot` ≥ 200M, `/` ≥ 1500M** are enforced sizes; the values above are well clear.
- **`IMAGE` must point at a real file in the rescue image directory.** Standard images include
  Ubuntu 24.04 LTS (Noble Numbat) Base; the exact filename is enumerated at runtime in step 7.
  Ubuntu 24.04 is chosen because `cuda-drivers-580` is published for `ubuntu2404` in NVIDIA's CUDA
  repository (see `vllm-sm120.md`).
- **NVMe naming.** `DRIVE1 /dev/nvme0n1`; `installimage` appends the `p` separator for NVMe
  partitions internally, so no manual partition naming is needed.

## Post-install bootstrap (over SSH, not in the chroot)

A post-install script (`-x`) runs inside the chroot, where the GPU is not reachable. Keep it to
package installation and SSH hardening; do the GPU work after the reboot.

```bash
apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg
# NVIDIA driver R580 + container toolkit, from NVIDIA's CUDA repo for ubuntu2404
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/k.deb
dpkg -i /tmp/k.deb && apt-get update
apt-get install -y cuda-drivers-580 nvidia-container-toolkit
nvidia-smi                       # R580+, both GPUs listed
# Docker
curl -fsSL https://get.docker.com | sh
nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
# Engine
docker pull vllm/vllm-openai:v0.31.0
```

## Failure modes

| Failure | Symptom | Handling |
| --- | --- | --- |
| Rescue window expired (60 min) or already consumed (one boot) | SSH refused, or the box boots the old OS | Re-activate rescue, reset again. Treat activation as a step that must be immediately followed by a reset |
| Config validation fails | `autosetup.sh` drops into `mcedit` and the run hangs with no tty | In automode this is visible only as a stalled install; read `/root/debug.txt` after re-entering rescue, fix the config, re-run |
| Pre-existing software RAID | `installimage` aborts on a busy device | `mdadm --stop /dev/md*` and `wipefs -fa` before installimage (step 6) |
| Wrong `DRIVE1`/`DRIVE2` | `ERROR: Value for DRIVE1 is not correct` | Enumerate real devices with `lsblk`; the names above match Hetzner's NVMe layout |
| UEFI vs legacy BIOS mismatch | `ERROR: ESP missing or multiple ESP found`, or an unbootable box | Drop the ESP line for legacy BIOS, or omit all `PART` lines and use the built-in defaults |
| Driver below R580 | Container fails to start with a CUDA version error | Install `cuda-drivers-580`; or switch the engine tag to `v0.31.0-cu129`, which needs only 575.51.03 |
| Order placed while ordering is disabled in Robot | `POST /order/server/transaction` returns an error | Enable ordering in Robot settings before the first run |
| Box left half-provisioned and billing | Order succeeded, install failed | The monthly charge starts at order time; the teardown path must be able to cancel a box that never served (Task 10) |

## Stage timings to measure on the first live run

Deferred per R3. Each stage is a timestamp in the provisioning script's output, so the numbers
become the runbook's expectations:

| Stage | Measure |
| --- | --- |
| Order → `status: ready` | Wall clock from `POST /order/server/transaction` to the first `ready` |
| Reset → rescue SSH reachable | Wall clock, on both port 22 and port 222 |
| `installimage` start → "installation complete" | Hetzner's documentation suggests 1–5 minutes for a standard image; confirm |
| Reboot → installed-system SSH reachable | Wall clock |
| Bootstrap (driver + docker + engine pull) | Wall clock; the engine image is ~9 GB |
| Engine start → `/health` 200 | Cold model load, dominated by the model pull from Hugging Face |

## Open items to verify on the first box

1. Root password behaviour after an automode install with no `PASSWD` in the config (key-based SSH
   is unaffected either way).
2. The real image filename for Ubuntu 24.04 base, enumerated in step 7.
3. Whether the GEX45/GEX63 firmware boots UEFI or legacy BIOS, which decides the ESP line.
4. Whether `-a -c /root/install.conf` is accepted verbatim, or whether writing `/autosetup`
   directly and running bare `installimage` is the more reliable form on the current rescue build.
