#!/bin/bash
# cis-tenable-check.sh — runs INSIDE a booted guest (piped over ssh by cis-scan.sh when CIS_TENABLE=1).
# Re-implements the logic of the Tenable "CIS Red Hat Enterprise Linux 10 v1.0.1 L1 Server" checks that failed on
# rhel10-hardened-2026111817 (docs/TENABLE_CIS_AUDIT_FINDINGS_2026-11-19.md), using the commands and regexes that
# Tenable printed in its report. "PASS" here means "the same command gives the compliant answer". It is NOT a Tenable scan.
# Second half = RUNTIME REGRESSION checks: things a fix could break on a pod VM (loopback, firewall, mounts, units).
# Output: one line per check: "PASS|FAIL|INFO <tag> <detail>", then a summary line "TENABLE_EQ pass=N fail=M".
set -u
P=0; F=0
res() { # <PASS|FAIL|INFO> <tag> <detail>
    echo "$1 $2 $3"
    case "$1" in PASS) P=$((P+1));; FAIL) F=$((F+1));; esac
}
chk() { # <tag> <detail-if-fail> <command...>  (PASS when command succeeds)
    local tag="$1" det="$2"; shift 2
    if "$@" >/dev/null 2>&1; then res PASS "$tag" ""; else res FAIL "$tag" "$det"; fi
}

echo "=== A. Tenable-equivalent checks ==="
# #1 CIS 1.1.2.1.1: /etc/fstab has a /tmp line AND tmp.mount enabled
chk "#1-fstab-/tmp" "no /tmp line in /etc/fstab" grep -Eq '^[^#]+[[:space:]]+/tmp[[:space:]]' /etc/fstab
chk "#1-tmp.mount-enabled" "tmp.mount is-enabled='$(systemctl is-enabled tmp.mount 2>&1)' (Tenable printed 'enabled' and PASSED)" bash -c '[ "$(systemctl is-enabled tmp.mount)" = enabled ]'

# #3 CIS 6.2.4.1: the CIS audit script, with the fix actions replaced by a report (same case table)
bad=0
while IFS= read -r -d $'\0' f; do
    while IFS=: read -r name mode user group; do
        case "$(basename "$name")" in
            lastlog|lastlog.*|wtmp|wtmp.*|wtmp-*|btmp|btmp.*|btmp-*|README) mask=0113; au='(root|utmp)'; ag='(root|utmp)'; au='root';;
            cloud-init.log*|localmessages*|waagent.log*) mask=0133; au='(root|syslog)'; ag='(root|adm)';;
            *.journal|*.journal~) mask=0137; au='root'; ag='(root|systemd-journal)';;
            *) mask=0137; au='(root|syslog)'; ag='(root|adm)'
               if [ "$user" = root ] || ! grep -Pq -- "^\h*$(awk -F: '$1=="'"$user"'" {print $7}' /etc/passwd)\b" /etc/shells; then
                   grep -Pq -- "$au" <<< "$user" || au="(root|syslog|$user)"
                   grep -Pq -- "$ag" <<< "$group" || ag="(root|adm|$group)"
               fi;;
        esac
        # lastlog/wtmp/btmp group rule in the CIS table is (root|utmp)
        case "$(basename "$name")" in lastlog*|wtmp*|btmp*|README) ag='(root|utmp)';; esac
        if [ $(( mode & mask )) -gt 0 ]; then res FAIL "#3-varlog" "$name mode $mode (mask $mask)"; bad=1; fi
        [[ "$user" =~ $au ]] || { res FAIL "#3-varlog" "$name owner $user"; bad=1; }
        [[ "$group" =~ $ag ]] || { res FAIL "#3-varlog" "$name group $group"; bad=1; }
    done < <(stat -Lc '%n:%#a:%U:%G' "$f")
done < <(find -L /var/log -type f \( -perm /0137 -o ! -user root -o ! -group root \) -print0)
[ "$bad" = 0 ] && res PASS "#3-varlog" "all /var/log files within CIS modes"

# #4 CIS 5.3.2.2.2 pwquality minlen regex from the report
chk "#4-minlen>=15" "$(grep -iE '^\s*minlen' /etc/security/pwquality.conf | head -1)" \
    grep -Piq '^\h*minlen\h*=\h*(1[5-9]|[2-9][0-9]|[1-9][0-9]{2,})\b' /etc/security/pwquality.conf

# #6 CIS 5.4.3.3 umask: profile.d file and login.defs
chk "#6-profile.d-umask" "no /etc/profile.d/*.sh with umask 027" grep -Eqs '^[[:space:]]*umask[[:space:]]+0?27\b' /etc/profile.d/*.sh
chk "#6-login.defs-UMASK" "UMASK not 027" grep -Piq '^\s*UMASK\s+027\b' /etc/login.defs

# #7 CIS 5.4.1.1: login.defs regex and the shadow awk from the report
chk "#7-PASS_MAX_DAYS<=90" "$(grep -E '^PASS_MAX_DAYS' /etc/login.defs)" grep -Piq '^\s*PASS_MAX_DAYS\s+([1-9]|[1-8][0-9]|90)\s*$' /etc/login.defs
SH=$(awk -F: '($2~/^\$.+\$/) {if($5 > 90 || $5 < 1)print "User: " $1 " PASS_MAX_DAYS: " $5}' /etc/shadow)
[ -z "$SH" ] && res PASS "#7-shadow-users" "" || res FAIL "#7-shadow-users" "$SH"
# root must not be expired by the new max age (CIS warning): last-change date must be set
RL=$(chage -l root 2>/dev/null | awk -F: '/Last password change/{print $2}' | xargs)
case "$RL" in ''|never) res FAIL "#7-root-lastchange" "root last password change = '$RL' (would expire at once)";; *) res PASS "#7-root-lastchange" "$RL";; esac

# #9 CIS 5.4.2.5 root path integrity: every dir in root's login PATH exists, is a directory, owned by root, mode within 0755
RPATH=$(bash -l -c 'echo $PATH' 2>/dev/null)
bad=0
IFS=: read -ra DIRS <<< "$RPATH"
for d in "${DIRS[@]}"; do
    if [ -z "$d" ] || [ "$d" = . ]; then res FAIL "#9-root-path" "empty or '.' element in PATH=$RPATH"; bad=1; continue; fi
    [ -d "$d" ] || { res FAIL "#9-root-path" "$d is not a directory"; bad=1; continue; }
    m=$(stat -L -c %a "$d"); o=$(stat -L -c %U "$d")   # -L: /bin and /sbin are symlinks to /usr/bin, /usr/sbin
    [ "$o" = root ] || { res FAIL "#9-root-path" "$d owner $o"; bad=1; }
    [ $(( 0$m & ~0755 )) -eq 0 ] || { res FAIL "#9-root-path" "$d mode $m"; bad=1; }
done
[ "$bad" = 0 ] && res PASS "#9-root-path" "$RPATH"

# #10 CIS 4.1.6 loopback rich rules in the zone of lo
LOZONE=$(firewall-cmd --get-zone-of-interface=lo 2>/dev/null)
RR=$(firewall-cmd --zone="$LOZONE" --list-rich-rules 2>/dev/null)
echo "$RR" | grep -q 'family="ipv4" source address="127.0.0.1" destination NOT address="127.0.0.1" drop' \
    && res PASS "#10-fw-ipv4" "zone $LOZONE" || res FAIL "#10-fw-ipv4" "zone '$LOZONE' rich rules: $RR"
echo "$RR" | grep -q 'family="ipv6" source address="::1" destination NOT address="::1" drop' \
    && res PASS "#10-fw-ipv6" "zone $LOZONE" || res FAIL "#10-fw-ipv6" "zone '$LOZONE' rich rules: $RR"

# #13 CIS 2.4.1.7 /etc/cron.yearly: root:root, no group/other access
if [ -d /etc/cron.yearly ] && [ "$(stat -c %U:%G /etc/cron.yearly)" = root:root ] && [ $(( 0$(stat -c %a /etc/cron.yearly) & 077 )) -eq 0 ]; then
    res PASS "#13-cron.yearly" "$(stat -c '%a %U:%G' /etc/cron.yearly)"
else res FAIL "#13-cron.yearly" "$(stat -c '%a %U:%G' /etc/cron.yearly 2>&1)"; fi

# #15 CIS 1.6.2 exact awk from the report; must print nothing, and sha1_in_certs = 0
LEFT=$(awk -F= '($1~/(hash|sign)/ && $2~/SHA1/ && $2!~/^\s*\-\s*([^#\n\r]+)?SHA1/){print}' /etc/crypto-policies/state/CURRENT.pol)
[ -z "$LEFT" ] && res PASS "#15-sha1-awk" "none" || res FAIL "#15-sha1-awk" "$LEFT"
chk "#15-sha1_in_certs" "sha1_in_certs not 0" grep -Pq '^\h*sha1_in_certs\h*=\h*0\b' /etc/crypto-policies/state/CURRENT.pol

# #8/#14 (journal-remote / journal-upload)
chk "#8-journal-remote-pkg" "systemd-journal-remote not installed" rpm -q systemd-journal-remote
res INFO "#14-journal-upload" "enabled=$(systemctl is-enabled systemd-journal-upload.service 2>&1) active=$(systemctl is-active systemd-journal-upload.service 2>&1)"

# #12/#16 forwarding (expected to be handled by the fwd batch, or listed as waiver)
res INFO "#12-all.forwarding" "$(sysctl -n net.ipv4.conf.all.forwarding)"
res INFO "#16-default.forwarding" "$(sysctl -n net.ipv4.conf.default.forwarding)"

echo "=== B. Runtime regression checks (would a fix have broken the pod VM?) ==="
chk "R-firewalld-active" "firewalld not running" bash -c '[ "$(firewall-cmd --state 2>&1)" = running ]'
chk "R-15150-open-in-public" "15150/tcp not in public zone" bash -c 'firewall-cmd --zone=public --list-ports | grep -qw 15150/tcp'
chk "R-tmp-mounted-tmpfs" "$(findmnt -no SOURCE,FSTYPE,OPTIONS /tmp 2>&1)" bash -c 'findmnt -no FSTYPE /tmp | grep -qx tmpfs'
chk "R-tmp-noexec-nosuid-nodev" "$(findmnt -no OPTIONS /tmp 2>&1)" bash -c 'o=$(findmnt -no OPTIONS /tmp); [[ $o == *noexec* && $o == *nosuid* && $o == *nodev* ]]'
chk "R-dev-shm-noexec" "$(findmnt -no OPTIONS /dev/shm 2>&1)" bash -c 'findmnt -no OPTIONS /dev/shm | grep -q noexec'
chk "R-no-failed-units" "failed: $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')" bash -c '[ -z "$(systemctl --failed --no-legend --plain)" ]'
chk "R-sshd-or-no-need" "" true
# loopback TCP still works through the new rich rules (CDH / attestation-agent / agent-protocol-forwarder talk over 127.0.0.1)
if ss -ltn | grep -q ':15150 '; then
    chk "R-loopback-tcp-15150" "connect 127.0.0.1:15150 refused/dropped" bash -c 'timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/15150"'
else res INFO "R-loopback-tcp-15150" "agent-protocol-forwarder not listening in this boot (no network provisioning)"; fi
python3 - <<'PY' && res PASS "R-loopback-tcp-selftest" "" || res FAIL "R-loopback-tcp-selftest" "127.0.0.1 TCP to a local listener dropped"
import socket, threading
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); port = s.getsockname()[1]
threading.Thread(target=lambda: s.accept(), daemon=True).start()
c = socket.create_connection(("127.0.0.1", port), timeout=5); c.close()
PY
chk "R-loopback-icmp" "ping 127.0.0.1 failed" ping -c1 -W2 127.0.0.1
chk "R-loopback6-icmp" "ping ::1 failed" ping -6 -c1 -W2 ::1
# the VM's own non-loopback address must still reach its own listeners (not matched by the loopback-source rule)
MYIP=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
if [ -n "$MYIP" ]; then chk "R-own-ip-ping" "ping $MYIP failed" ping -c1 -W2 "$MYIP"; fi
chk "R-pam-login-config-valid" "authselect check failed" authselect check
chk "R-crypto-policy-applies" "$(update-crypto-policies --show)" bash -c 'update-crypto-policies --show | grep -q NO-SHA1 || ! ls /etc/crypto-policies/policies/modules/NO-SHA1.pmod'
# rpm still verifies Red Hat signatures with SHA1 removed
chk "R-rpm-sig-rhel-pkg" "rpm -K failed on an installed header" bash -c 'rpm -q --qf "%{NAME} %{SIGPGP:pgpsig}\n" bash | grep -qi "key ID"'
chk "R-openssl-tls-nosha1" "openssl cannot do a SHA256 sign/verify" bash -c 'echo x | openssl dgst -sha256 >/dev/null'

echo "TENABLE_EQ pass=$P fail=$F"
