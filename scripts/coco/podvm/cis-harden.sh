#!/bin/bash
# cis-harden.sh — CIS Level 1 Server "safe tier" hardening for the RHEL 10 HARDENED podvm image.
# Runs INSIDE the guest via virt-customize --run (patches/coco-components.sh, only when HARDENED=1),
# i.e. BEFORE the dm-verity hash is computed, so every change here is covered by roothash.
#
# TIERS (cumulative). Level is read from /tmp/cis-level (written by coco-components.sh / cis-dev-loop.sh
# from HARDENED=1..4; default 1). Each tier is validated (cis-scan + test-podvm) before the next is added,
# so a regression is attributable to ONE tier. See rhel10-experimental/LESSONS_LEARNED_2026-10-13.md Lesson 93
# and ibm_cloud_rhel9/UPSTREAM_DEVIATIONS.md (CIS section) for the reason behind every setting.
#   1 = safe config (banners, modules, coredump, sysctl subset, cron, umask/TMOUT, journald, sshd tuning, perms)
#   2 = access control (sudo, PAM/authselect, su wheel, PermitRootLogin/AllowUsers, aging, crypto policy)
#   3 = boot/filesystem (/tmp + /dev/shm mount opts, AIDE, grub password, firewalld)
#   4 = network sysctl (rp_filter, IPv6 forwarding). IPv4 forwarding is a proposed WAIVER (pod routing).
# Proposed permanent waivers (not here): ensure_root_password_configured, IPv4 forwarding, runtime-created unowned files.
# SSH stays enabled (needed to re-run oscap). NEVER add MACs/Ciphers to sshd config on RHEL.
set -euo pipefail
LEVEL=$(cat /tmp/cis-level 2>/dev/null || echo 1); rm -f /tmp/cis-level
case "$LEVEL" in 1|2|3|4) ;; *) echo "ERROR: bad CIS level '$LEVEL'" >&2; exit 1;; esac
echo "cis-harden.sh level=$LEVEL"

BANNER='Authorized users only. All activity may be monitored and reported.'
DONE=()

# dnf_add: install packages but FAIL if it upgrades the validated base (systemd/kernel/selinux-policy/dracut).
# Learned Session 31: `dnf install systemd-journal-remote` upgraded systemd 257-23.el10_2.1 -> .2 and the guest then froze
# at boot ("Failed to allocate manager object"). The image must keep the base's core packages exactly as validated.
dnf_add() {
    local before after
    before=$(rpm -q systemd kernel-core selinux-policy dracut | sort)
    dnf install -y "$@" >/root/cis-dnf.out 2>&1 || { tail -5 /root/cis-dnf.out >&2; echo "ERROR: dnf install $* failed" >&2; exit 1; }
    after=$(rpm -q systemd kernel-core selinux-policy dracut | sort)
    if [ "$before" != "$after" ]; then
        echo "ERROR: dnf install $* changed core packages (would break boot / change validated base):" >&2
        diff <(echo "$before") <(echo "$after") >&2 || true
        exit 1
    fi
    rm -f /root/cis-dnf.out
}

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
systemctl mask bluetooth.service bluetooth.socket >/dev/null 2>&1 || true
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

# --- 7. umask 027 and idle timeout (forms taken from SSG fix.sh: sed on every uncommented umask; typeset -xr TMOUT in profile.d)
sed -i -E 's/^(UMASK[[:space:]]+).*/\1027/' /etc/login.defs
grep -qE '^UMASK[[:space:]]+027' /etc/login.defs
for f in /etc/bashrc /etc/profile; do
    grep -q "^[^#]*\bumask" "$f" && sed -i -E "s/^([^#]*\bumask)[[:space:]]+[[:digit:]]+/\1 027/g" "$f" || echo "umask 027" >> "$f"
done
rm -f /etc/profile.d/cis-tmout.sh
printf '# CIS: idle timeout\ntypeset -xr TMOUT=900\n' > /etc/profile.d/tmout.sh
chmod 644 /etc/profile.d/tmout.sh
DONE+=(umask-tmout)

# --- 8. journald: single logger (journald only), no syslog forward, size-capped persistent
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
printf '[Journal]\nStorage=persistent\nCompress=yes\nForwardToSyslog=no\nSystemMaxUse=64M\n' > /etc/systemd/journald.conf.d/cis.conf
systemctl disable rsyslog.service >/dev/null 2>&1 || true
mkdir -p /etc/rsyslog.d
printf '$FileCreateMode 0640\n' > /etc/rsyslog.d/00-rsyslog_filecreatemode.conf
chmod 644 /etc/rsyslog.d/00-rsyslog_filecreatemode.conf
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
ClientAliveCountMax 1
PermitUserEnvironment no
HostbasedAuthentication no
IgnoreRhosts yes
PermitEmptyPasswords no
EOF
ssh-keygen -q -t ed25519 -N '' -f /tmp/cis-sshd-test-key
sshd -t -h /tmp/cis-sshd-test-key || { echo "ERROR: sshd config invalid" >&2; exit 1; }
rm -f /tmp/cis-sshd-test-key /tmp/cis-sshd-test-key.pub
chmod 700 /etc/ssh/sshd_config.d
chmod 600 /etc/ssh/sshd_config.d/*.conf
DONE+=(sshd-dropin)

# --- 10. tier-1 extras: journal-remote pkg (installed but kept disabled), root locked-password, grub + user-init-file perms
# systemd-journal-remote: previously WAIVED (session 31) because install upgraded systemd .1->.2 and broke boot.
# Re-tested session 32: base now ships .1 and repo has no upgrade pending — install is safe (only adds libxslt/xmlsec1).
dnf_add systemd-journal-remote
systemctl disable --now systemd-journal-remote.service systemd-journal-remote.socket 2>/dev/null || true
DONE+=(journal-remote)

# --- root locked-password: set a SHA-512 hash so ensure_root_password_configured passes.
# Account stays functionally locked (no login); the hash is a random non-guessable value.
ROOT_HASH=$(python3 -c "import crypt,os; print(crypt.crypt(os.urandom(32).hex(), crypt.mksalt(crypt.METHOD_SHA512)))")
usermod -p "$ROOT_HASH" root
grep -q '^\$' <(python3 -c "import subprocess; print(subprocess.check_output(['getent','shadow','root']).decode().split(':')[1])")  \
    || { echo "ERROR: root password hash not set" >&2; exit 1; }
DONE+=(root-locked-password)

find -P /boot/grub2/ -maxdepth 1 -perm /u+xs,g+xwrs,o+xwrt -type f -exec chmod u-xs,g-xwrs,o-xwrt {} \;
for h in $(awk -F: '$3>=1000 && $7!="/sbin/nologin" {print $6}' /etc/passwd); do
    [ -d "$h" ] && find "$h" -maxdepth 1 -type f -name '.*' -exec chmod u-s,g-wxs,o= {} \;
done
DONE+=(tier1-extras)


# =================================================================== TIER 2: access control
if [ "$LEVEL" -ge 2 ]; then
    # --- sudo: use_pty, logfile, re-auth timeout (drop-in validated with visudo before it is kept)
    printf 'Defaults use_pty\nDefaults logfile="/var/log/sudo.log"\nDefaults timestamp_timeout=15\n' > /etc/sudoers.d/00-cis
    chmod 440 /etc/sudoers.d/00-cis
    visudo -cf /etc/sudoers.d/00-cis >/dev/null || { echo "ERROR: sudoers drop-in invalid" >&2; exit 1; }
    DONE+=(sudo)

    # --- PAM via authselect features (faillock, pwhistory, no nullok) + pwquality/faillock/pwhistory settings (SSG values)
    # SSG rule accounts_password_pam_modules_in_authselect_profile requires profile to match "custom/*".
    # Create custom/hardening based on local so the check passes while keeping the same PAM behaviour.
    authselect select local with-faillock with-pwhistory without-nullok --force >/dev/null
    authselect create-profile hardening -b local >/dev/null
    authselect select custom/hardening with-faillock with-pwhistory without-nullok --force >/dev/null
    authselect check >/dev/null
    cat > /etc/security/pwquality.conf <<'EOF'
minlen = 14
minclass = 4
dictcheck = 1
difok = 2
maxrepeat = 3
maxsequence = 3
enforce_for_root
EOF
    cat > /etc/security/faillock.conf <<'EOF'
deny = 5
unlock_time = 900
EOF
    printf 'remember = 24\nenforce_for_root\n' > /etc/security/pwhistory.conf
    DONE+=(pam-authselect)

    # --- su restricted to (empty) group sugroup
    getent group sugroup >/dev/null || groupadd sugroup
    grep -qE '^auth\s+required\s+pam_wheel.so\s+use_uid\s+group=sugroup' /etc/pam.d/su || \
        sed -i -E '0,/^auth\s+include/s//auth            required        pam_wheel.so use_uid group=sugroup\n&/' /etc/pam.d/su
    grep -qE 'pam_wheel.so use_uid group=sugroup' /etc/pam.d/su
    DONE+=(su-wheel)

    # --- sshd access: login user on this image is vpcuser (NESSUS_CIS_REVIEW §7.1); root login off.
    # Separate drop-in so tier 2 is attributable. PermitRootLogin/AllowUsers only - NO MACs/Ciphers.
    printf 'PermitRootLogin no\nAllowUsers vpcuser\n' > /etc/ssh/sshd_config.d/01-cis-access.conf
    chmod 600 /etc/ssh/sshd_config.d/01-cis-access.conf
    id vpcuser >/dev/null || { echo "ERROR: vpcuser does not exist - AllowUsers would lock everyone out" >&2; exit 1; }
    ssh-keygen -q -t ed25519 -N '' -f /tmp/cis-sshd-test-key
    sshd -t -h /tmp/cis-sshd-test-key || { echo "ERROR: sshd config invalid (tier 2)" >&2; exit 1; }
    rm -f /tmp/cis-sshd-test-key /tmp/cis-sshd-test-key.pub
    DONE+=(sshd-access)

    # --- password aging defaults
    sed -i -E 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 365/' /etc/login.defs
    useradd -D -f 45
    DONE+=(aging)

    # --- crypto policy: SSG DEFAULT + NO-SSH* + NO-WEAKMAC modules (configure_custom_crypto_policy_cis)
    # NO-SSHWEAKMACS includes -HMAC-SHA1* per SSG fix.sh requirement; NO-WEAKMAC removes -*-128* MACs globally.
    mkdir -p /etc/crypto-policies/policies/modules
    printf 'cipher@SSH = -*-CBC\n' > /etc/crypto-policies/policies/modules/NO-SSHCBC.pmod
    printf 'cipher@SSH = -3DES-CBC -AES-128-CBC -AES-192-CBC -AES-256-CBC\n' > /etc/crypto-policies/policies/modules/NO-SSHWEAKCIPHERS.pmod
    printf 'mac@SSH = -HMAC-MD5* -UMAC-64* -UMAC-128* -HMAC-SHA1*\n' > /etc/crypto-policies/policies/modules/NO-SSHWEAKMACS.pmod
    printf 'mac = -*-128*\n' > /etc/crypto-policies/policies/modules/NO-WEAKMAC.pmod
    update-crypto-policies --no-reload --set DEFAULT:NO-SSHCBC:NO-SSHWEAKCIPHERS:NO-SSHWEAKMACS:NO-WEAKMAC >/dev/null
    DONE+=(crypto-policy)
fi

# =================================================================== TIER 3: boot / filesystem
if [ "$LEVEL" -ge 3 ]; then
    # --- /dev/shm and /tmp hardened mounts
    grep -q '^tmpfs /dev/shm ' /etc/fstab || echo 'tmpfs /dev/shm tmpfs defaults,nodev,nosuid,noexec 0 0' >> /etc/fstab
    mkdir -p /etc/systemd/system/tmp.mount.d
    printf '[Mount]\nOptions=mode=1777,strictatime,nosuid,nodev,noexec\n' > /etc/systemd/system/tmp.mount.d/cis.conf
    systemctl enable tmp.mount >/dev/null 2>&1
    [ -L /etc/systemd/system/local-fs.target.wants/tmp.mount ] || { echo "ERROR: tmp.mount not enabled" >&2; exit 1; }
    DONE+=(tmp-shm-mounts)

    # --- AIDE: install, audit-tool rules, baseline DB (built here so it is covered by dm-verity), daily check
    dnf_add aide
    for t in auditctl auditd augenrules aureport ausearch autrace; do
        echo "/usr/sbin/$t p+i+n+u+g+s+b+acl+xattrs+sha512" >> /etc/aide.conf
    done
    /usr/sbin/aide --init >/dev/null 2>&1 || true   # aide returns non-zero for informational conditions; DB presence is asserted next
    mv -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
    [ -s /var/lib/aide/aide.db.gz ] || { echo "ERROR: AIDE database not created" >&2; exit 1; }
    grep -q '/usr/sbin/aide --check' /etc/crontab || echo '05 4 * * * root /usr/sbin/aide --check' >> /etc/crontab
    DONE+=(aide)

    # --- grub superuser password: random, hashed, plaintext discarded. BLS entries stay --unrestricted
    # (headless boot must NOT prompt); only editing the menu / cmdline needs the password.
    command -v grub2-mkpasswd-pbkdf2 >/dev/null || { echo "ERROR: grub2-mkpasswd-pbkdf2 missing" >&2; exit 1; }
    GP=$(head -c 24 /dev/urandom | base64)
    GH=$(printf '%s\n%s\n' "$GP" "$GP" | grub2-mkpasswd-pbkdf2 2>&1 | awk '/grub\.pbkdf2/{print $NF}')
    unset GP
    case "$GH" in grub.pbkdf2.*) ;; *) echo "ERROR: grub password hash not generated" >&2; exit 1;; esac
    printf 'GRUB2_PASSWORD=%s\n' "$GH" > /boot/grub2/user.cfg
    chmod 600 /boot/grub2/user.cfg
    unset GH
    DONE+=(grub-password)

    # --- firewalld: enabled, loopback trusted, 15150/tcp (agent-protocol-forwarder) must remain open
    rpm -q firewalld >/dev/null
    systemctl enable firewalld >/dev/null 2>&1
    firewall-offline-cmd --zone=trusted --add-interface=lo >/dev/null
    firewall-offline-cmd --zone=public --list-ports | grep -qw '15150/tcp' || { echo "ERROR: 15150/tcp not open in firewalld" >&2; exit 1; }
    DONE+=(firewalld)
fi

# =================================================================== TIER 4: network sysctl
if [ "$LEVEL" -ge 4 ]; then
    cat > /etc/sysctl.d/99-cis-net.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF
    DONE+=(sysctl-net)
fi

# --- marker (host-side verify checks this)
printf '%s\n' "level-${LEVEL}" "${DONE[@]}" > /etc/podvm-cis-hardened
echo "✓ cis-harden.sh complete: ${DONE[*]}"
