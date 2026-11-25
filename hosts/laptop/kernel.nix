# ---------------------------------------------------------------------------
# kernel.nix — codified hardware dump (2026-10-13, kernel 6.18.55, lsmod 185)
#
# MacBook9,1 (Mac-9AE82516C7C6B903) — 12" Retina MacBook 2016, m3-6Y30
# (Skylake-Y, 2C/4T, 4.5 W TDP / 7 W cTDP-up), FANLESS — the SMC exposes no
# fan keys at all (see hosts/laptop/thermal.nix).
#
# PCI inventory (what is on the board and what drives it):
#   8086:190c  m3-6Y30 host bridge/uncore            → skl_uncore
#   8086:191e  HD 515 iGPU                           → i915
#   8086:9d2f  xHCI USB3 controller                  → xhci_hcd
#   8086:9d60/9d62/9d66/9d27/9d2a  LPSS SPI/I2C      → intel-lpss
#              (SPI keyboard + touchpad arrive via applespi)
#   8086:9d3a  CSME HECI                             → mei_me (+mei_hdcp/pxp)
#   8086:9d10/9d18/9d19  PCIe root ports (TBT lanes, idle)
#   8086:9d46  LPC (Apple SMC lives here)
#   8086:9d21  PMC / hardware features               → intel_pmc_core
#   8086:9d70  HDA: Cirrus CS4208 + Skylake HDMI     → snd_hda_intel (legacy)
#   8086:9d23  SMBus: bq20z451 battery               → i801_smbus + sbs/sbshc
#   106b:2003  Apple NVMe 256 GB (root + ESP)        → nvme
#   14e4:43a3  BCM4355 WiFi                          → brcmfmac (+brcmfmac_wcc)
#   14e4:1570  Broadcom BCM15700                     → no Linux driver EXISTS;
#                                                        inert, do not chase
#   Bluetooth: BCM4350C0 on UART serial1-0            → hci_uart_bcm
#              (i.e. btusb is NOT the BT transport here!)
#
# Load-bearing modules — never blacklist:
#   i915, applespi, intel_lpss(_pci), mei*, iTCO-adjacent intel_pmc_core,
#   i915, applespi, intel_lpss(_pci), mei*, intel_pmc_core, the xHCI stack,
#   snd_hda_intel + cs420x + hdmi codecs, hci_uart(_bcm),
#   brcmfmac(_wcc)/brcmutil, sbs/sbshc/i2c_smbus, nvme, zram stack, tun
#
# Deliberately pruned (each verified loaded-but-unused on this board):
#   * SOF/AVS/SoundWire DSP stack (~4 MB of modules) — 9d70 is bound by
#     snd_hda_intel via dsp_driver=1, so no SOF/AVS device ever existed
#   * PMC telemetry chain (intel_vsec/pmt_*) — no userspace consumer
#   * iTCO watchdog (+bxt) — nobody requests it; `nowatchdog` on cmdline
#   * kvm(-intel) at boot — no VM module is imported
# ---------------------------------------------------------------------------

{ lib, ... }:

{
  # Initrd only needs to find the NVMe root over the xHCI tree: no SATA,
  # no SD, no USB storage rescue boots (add "usb_storage" back if you ever
  # need a USB rescue kernel in initrd).
  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" ];
  boot.initrd.kernelModules = [ ];

  # Everything mission-critical is built-in or udev-autoloaded. (Historical:
  # kvm-intel was listed here with no VM user — remove, re-add with virt.nix)
  boot.kernelModules = [ ];

  # 9d70 uses plain legacy HDA here (CS4208 + HDMI codec, confirmed bound).
  # dsp_driver=1 keeps snd-intel-dspcfg from ever probing the SOF or AVS
  # DSP drivers, so the whole snd_sof*/soundwire_*/snd_soc_* stack stays
  # unloaded instead of loading-then-failing every boot.
  boot.extraModprobeConfig = ''
    options snd-intel-dspcfg dsp_driver=1
  '';

  boot.blacklistedKernelModules = [
    # Belt-and-suspenders for the DSP stack (the option above covers 99%).
    "snd_soc_avs"

    # PMC telemetry chain: pmt_* plus intel_vsec expose unread sysfs/debugfs
    # telemetry. intel_pmc_core itself STAYS — it participates in suspend/PM.
    "intel_vsec"
    "pmt_class"
    "pmt_telemetry"
    "pmt_discovery"
    "intel_pmc_core_pltdrv"

    # iTCO watchdog timer — no watchdog user on a laptop; combined with the
    # nowatchdog/nmi_watchdog=0 params below to kill the periodic wakeups.
    "iTCO_wdt"
    "intel_pmc_bxt"
  ];

  boot.kernelParams = [
    # No watchdog users; the NMI watchdog is pure periodic-wakeup overhead.
    "nowatchdog"
    "nmi_watchdog=0"
  ];

  # Deliberate non-changes:
  #  - networking.firewall.checkReversePath stays at its NixOS default
  #    ("loose") — that is what the tunnel needs, no override here.
  #  - pcie ASPM policy stays "default": heavier powersave policies have
  #    known brcmfmac stability bugs on these Broadcom chips.
  #  - extra firmware: only brcm + i915 need it here; with dsp_driver=1
  #    no SOF firmware files are ever requested.
}
