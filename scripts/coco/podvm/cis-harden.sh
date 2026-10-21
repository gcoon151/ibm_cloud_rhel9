#!/bin/bash
# cis-harden.sh — CIS Level 1 Server "safe tier" hardening for the RHEL 10 HARDENED podvm image.
# Runs INSIDE the guest via virt-customize --run (patches/coco-components.sh, only when HARDENED=1),
# i.e. BEFORE the dm-verity hash is computed, so every change here is covered by roothash.
#
# Scope: step 1 of the hardened image (see rhel10-experimental/NESSUS_CIS_REVIEW.md).
# Deliberately NOT here (need testing or a user decision): sudo, PAM/authselect, grub2 password,
# firewalld, ip forwarding, rp_filter, PermitRootLogin/AllowUsers, AIDE, /tmp + /dev/shm mounts.
# SSH stays enabled (needed to re-run oscap). NEVER add MACs/Ciphers to sshd config on RHEL.
set -euo pipefail

BANNER='Authorized users only. All activity may be monitored and reported.'
DONE=()

# --- 1. fwupd: CANNOT be removed (shim-x64 -> dbxtool -> fwupd; dnf refuses, removal would drop the Secure Boot shim).
# Mask it instead so nothing starts it: that stops the runtime-created uid-62803 /var/cache/private/fwupdmgr
# (no_files_or_dirs_*) and an outbound-calling timer on a VM with no firmware to manage.
systemctl mask fwupd.service fwupd-refresh.service fwupd-refresh.timer
for u in fwupd.service fwupd-refresh.service fwupd-refresh.timer; do
    [ "$(readlink -f /etc/systemd/system/$u)" = "/dev/null" ] || { echo "ERROR: $u not masked" >&2; exit 1; }
done
rpm -q shim-x64 >/dev/null
DONE+=(fwupd-masked)

# --- 2. banners (text read from the CIS-hardened ROKS worker)
printf '%s\n' "$BANNER" > /etc/issue
printf '%s\n' "$BANNER" > /etc/issue.net
printf '%s'   "$BANNER" > /etc/motd
chmod 644 /etc/issue /etc/issue.net /etc/motd
DONE+=(banners)

# --- 3. disabled kernel modules + bluetooth
for m in cramfs freevxfs hfs hfsplus jffs2 usb-storage atm can dccp rds sctp tipc firewire-core; do
    printf 'install %s /bin/false\nblacklist %s\n' "$m" "$m" > "/etc/modprobe.d/cis-${m}.conf"
done
systemctl disable bluetooth.service >/dev/null 2>&1 || true
DONE+=(modprobe-blacklist)

# --- 4. core dumps
mkdir -p /etc/systemd/coredump.conf.d /etc/security/limits.d
printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf.d/cis.conf
printf '* hard core 0\n' > /etc/security/limits.d/cis-core.conf
DONE+=(coredump)

# --- 5. sysctl (safe subset: NO forwarding, NO rp_filter — those can break pod networking)
cat > /etc/sysctl.d/99-cis.conf << 'EOF'
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
EOF
DONE+=(sysctl)

# --- 6. cron / at access and permissions
for d in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly; do
    [ -d "$d" ] && chmod 700 "$d"
done
[ -f /etc/crontab ] && chmod 600 /etc/crontab
rm -f /etc/cron.deny /etc/at.deny
install -m 600 -o root -g root /dev/null /etc/cron.allow
install -m 600 -o root -g root /dev/null /etc/at.allow
DONE+=(cron)

# --- 7. umask 027 and idle timeout
sed -i -E 's/^(UMASK[[:space:]]+).*/\1027/' /etc/login.defs
sed -i -E 's/^([[:space:]]*)umask 0?(02|22)\b/\1umask 027/' /etc/profile /etc/bashrc
grep -qE '^UMASK[[:space:]]+027' /etc/login.defs
printf 'TMOUT=600\nreadonly TMOUT\nexport TMOUT\n' > /etc/profile.d/cis-tmout.sh
chmod 644 /etc/profile.d/cis-tmout.sh
DONE+=(umask-tmout)

# --- 8. journald: single logger (journald only), no syslog forward, size-capped persistent
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
printf '[Journal]\nStorage=persistent\nCompress=yes\nForwardToSyslog=no\nSystemMaxUse=64M\n' > /etc/systemd/journald.conf.d/cis.conf
systemctl disable rsyslog.service >/dev/null 2>&1 || true
DONE+=(journald)

# --- 9. sshd: only settings that cannot lock us out (no PermitRootLogin/AllowUsers/MACs/Ciphers)
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-cis.conf << 'EOF'
Banner /etc/issue.net
LogLevel VERBOSE
LoginGraceTime 60
MaxAuthTries 4
MaxSessions 10
MaxStartups 10:30:60
ClientAliveInterval 15
ClientAliveCountMax 3
PermitUserEnvironment no
HostbasedAuthentication no
IgnoreRhosts yes
PermitEmptyPasswords no
EOF
ssh-keygen -q -t ed25519 -N '' -f /tmp/cis-sshd-test-key
sshd -t -h /tmp/cis-sshd-test-key || { echo "ERROR: sshd config invalid" >&2; exit 1; }
rm -f /tmp/cis-sshd-test-key /tmp/cis-sshd-test-key.pub
DONE+=(sshd-dropin)

# --- marker (host-side verify checks this)
printf '%s\n' "${DONE[@]}" > /etc/podvm-cis-hardened
echo "✓ cis-harden.sh complete: ${DONE[*]}"
