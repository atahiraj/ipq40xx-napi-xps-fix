# IPQ40xx NAPI/XPS tuning for OpenWrt

Configures Ethernet interrupt placement, NAPI processing and transmit packet
steering (XPS) on the AVM FRITZ!Box 7530 with a four-core IPQ4019.

## Requirements

- Run as root on the router.
- Four online CPUs (`0-3`), four RX queues and four TX queues on `eth0`.
- A writable `eth0/threaded` setting and the supported eight-thread NAPI layout.
- Existing RX packet steering (RPS) masks `2,4,8,1` for queues 0–3.
- The `taskset` command; irqbalance must already be installed to use its mode.
- No pending UCI changes.

The installer checks the hardware layout and prerequisites before applying the
profile. This is a device-specific configuration, not a generic IPQ40xx profile.

## Installation

Copy all four scripts into the same directory on the router:

| File | Purpose |
| --- | --- |
| `install.sh` | Validate, install and apply the selected profile |
| `napi-xps-fix` | Init service that applies and verifies the profile |
| `packet-steering.sh` | Hook that reapplies the profile after OpenWrt packet steering |
| `uninstall.sh` | Remove the profile and restore stock packet steering |

Choose a profile:

```sh
# Standard NAPI processing with fixed IRQ placement
sh install.sh manual softirq

# Dedicated NAPI threads with fixed IRQ placement
sh install.sh manual threaded

# Dedicated NAPI threads with IRQ placement managed by irqbalance
sh install.sh irqbalance threaded
```

The second argument defaults to `threaded`. `softirq` requires `manual` IRQ
placement. Rerun the installer to switch profiles or update an installation.

Installation enables packet steering, sets `steering_flows=0` and configures
irqbalance for the selected mode. It does not install packages or restart
networking or Wi-Fi. If installation fails after making changes, it attempts
to restore the previous configuration.

## Processing and CPU placement

`softirq` uses standard NAPI polling (`eth0/threaded=0`). `threaded` enables
dedicated NAPI kernel threads (`eth0/threaded=1`). Both modes use the same XPS
masks and retain the NAPI thread affinities; those affinities apply when
threaded processing is enabled.

For queue indices 0–3:

| Setting | CPU masks |
| --- | --- |
| TX XPS | `1,2,4,8` |
| Required RX RPS | `2,4,8,1` |
| RX IRQs, manual mode | `1,2,4,8` |
| TX IRQs, manual mode | `2,4,8,1` |

Masks are hexadecimal CPU bitsets: `1`, `2`, `4` and `8` select CPUs 0, 1, 2
and 3 respectively. The service validates RPS; it does not write RPS masks.
In irqbalance mode, the daemon controls IRQ placement instead of fixed masks.

The selected profile is stored in `/etc/config/napi_xps`:

```uci
config profile 'main'
    option irq_mode 'manual'
    option processing 'softirq'
```

Configurations without a `processing` option default to `threaded`.
Throughput depends on the device, traffic and network path; no profile guarantees
a particular speed.

## Verification

```sh
# Check prerequisites without applying changes
/etc/init.d/napi-xps-fix check

# Verify the selected profile against live settings
/etc/init.d/napi-xps-fix verify

# Display modes, queue masks, IRQ masks and thread affinities
/etc/init.d/napi-xps-fix show
```

## Reboots and upgrades

The service runs at boot, and the packet-steering hook reapplies the profile
when OpenWrt updates packet steering.

The installer adds the service, hook, profile and boot links to
`/etc/sysupgrade.conf`. Select **Keep settings** during sysupgrade to preserve
them. In irqbalance mode, the new image must also include the irqbalance package.
Run `verify` after upgrading; a firmware change may alter the supported layout.

## Uninstallation

```sh
sh uninstall.sh
```

Removal restores threaded NAPI, clears custom XPS and thread affinities,
releases Ethernet IRQ masks and reloads stock packet steering. It removes the
installed service, hook, profile and their explicit sysupgrade entries.
irqbalance remains stopped and disabled. The network packet-steering UCI
settings applied by the installer remain configured.
