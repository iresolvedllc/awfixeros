{ ... }:

{
  # Host hardening. The docker group stays in users.nix.
  # User namespaces stay on: browsers, Flatpak, Nix builds, and Docker need them.
  # Kernel modules stay loadable: Docker and USB hotplug need that.

  security.protectKernelImage = true;
  security.forcePageTableIsolation = true;
  security.allowUserNamespaces = true;

  boot.kernelParams = [
    "slab_nomerge"
    "init_on_alloc=1"
    "page_alloc.shuffle=1"
  ];

  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.perf_event_paranoid" = 3;
    # Unprivileged bpf stays off, and cannot be turned back on until reboot.
    "kernel.unprivileged_bpf_disabled" = 1;
    # Attach a debugger to your own children. Attaching to another user's
    # process needs root. gdb on a process you started still works.
    "kernel.yama.ptrace_scope" = 1;

    "fs.suid_dumpable" = 0;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "fs.protected_symlinks" = 1;
    "fs.protected_hardlinks" = 1;

    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.secure_redirects" = 0;
    "net.ipv4.conf.default.secure_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_rfc1337" = 1;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.default.accept_source_route" = 0;
  };

  # AppArmor is on. Stock profiles target /usr paths, so Nix binaries stay
  # unconfined until a profile names their store path. The LSM is ready.
  security.apparmor.enable = true;
  security.apparmor.killUnconfinedConfinables = false;

  security.audit.enable = true;
  security.audit.failureMode = "printk";
  security.audit.rateLimit = 200;
  security.auditd.enable = true;
  security.auditd.settings = {
    max_log_file = 20;
    num_logs = 5;
    max_log_file_action = "rotate";
    space_left_action = "syslog";
    admin_space_left_action = "suspend";
    disk_full_action = "suspend";
    disk_error_action = "syslog";
  };
  # Only paths that exist on this machine. A missing watch makes auditctl
  # reject the whole rules file.
  security.audit.rules = [
    "-w /etc/passwd -p wa -k identity"
    "-w /etc/shadow -p wa -k identity"
    "-w /etc/group -p wa -k identity"
    "-w /etc/sudoers -p wa -k sudoers"
    "-w /etc/ssh -p wa -k ssh"
    "-w /var/log/wtmp -p wa -k session"
    "-w /var/log/btmp -p wa -k session"
    "-w /run/utmp -p wa -k session"
    "-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k modules"
    "-a always,exit -F arch=b32 -S init_module -S finit_module -S delete_module -k modules"
    "-a always,exit -F arch=b64 -S execve -F exe=/run/wrappers/bin/sudo -k sudo"
    "-a always,exit -F arch=b64 -S execve -F exe=/run/wrappers/bin/su -k sudo"
  ];

  security.sudo.wheelNeedsPassword = true;
  security.sudo.execWheelOnly = true;
  security.sudo.extraConfig = ''
    Defaults timestamp_timeout=5
    Defaults passwd_timeout=1
    Defaults use_pty
    Defaults umask=0077
    Defaults env_reset
  '';

  security.pam.services.login.failDelay = {
    enable = true;
    delay = 4000000;
  };
  security.pam.services.sddm.failDelay = {
    enable = true;
    delay = 4000000;
  };
  security.pam.services.sudo.failDelay = {
    enable = true;
    delay = 4000000;
  };

  # Firmware updates. The daemon does not install them on its own.
  services.fwupd.enable = true;

  # New USB devices must match a class below. Hubs, keyboards, storage,
  # audio, video, USB ethernet, USB-C billboard, and Android ADB stay
  # allowed so a dock or a phone still works. Other classes are blocked.
  # The keyboard and trackpad are SPI, not USB.
  services.usbguard = {
    enable = true;
    implicitPolicyTarget = "block";
    presentControllerPolicy = "keep";
    presentDevicePolicy = "apply-policy";
    insertedDevicePolicy = "apply-policy";
    IPCAllowedUsers = [
      "root"
      "awfixer"
    ];
    rules = ''
      allow with-interface one-of { 09:*:* }
      allow with-interface one-of { 03:*:* }
      allow with-interface one-of { 08:*:* }
      allow with-interface one-of { 01:*:* }
      allow with-interface one-of { 0e:*:* }
      allow with-interface one-of { 02:*:* }
      allow with-interface one-of { 11:*:* }
      allow with-interface one-of { ff:42:01 }
    '';
  };
}
