#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# shellcheck disable=SC2016
set -eux
set -o pipefail

# shellcheck source=test/units/util.sh
. "$(dirname "$0")"/util.sh

if [[ ! -f /usr/lib/systemd/system/systemd-mountfsd.socket ]] ||
   [[ ! -f /usr/lib/systemd/system/systemd-nsresourced.socket ]] ||
   ! grep -q bpf /sys/kernel/security/lsm ||
   ! find /usr/lib* -name libbpf.so.1 2>/dev/null | grep . ||
   systemd-analyze compare-versions "$(uname -r)" lt 6.5 ||
   systemd-analyze compare-versions "$(pkcheck --version | awk '{print $3}')" lt 124; then
    echo "Skipping unpriv nspawn test"
    exit 0
fi

at_exit() {
    rm -rf /home/testuser/.local/state/machines/zurps ||:
    machinectl terminate zurps ||:
    rm -f /usr/share/polkit-1/rules.d/registermachinetest.rules
}

trap at_exit EXIT

systemctl start systemd-mountfsd.socket systemd-nsresourced.socket

run0 -u testuser mkdir -p .local/state/machines

create_dummy_container /home/testuser/.local/state/machines/zurps
cat >/home/testuser/.local/state/machines/zurps/sbin/init <<EOF
#!/bin/sh
echo "I am living in a container"
exec sleep infinity
EOF
chmod +x /home/testuser/.local/state/machines/zurps/sbin/init
systemd-dissect --shift /home/testuser/.local/state/machines/zurps foreign

# Install a PK rule that allows 'testuser' user to register a machine even
# though they are not on an fg console, just for testing
cat >/usr/share/polkit-1/rules.d/registermachinetest.rules <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.machine1.register-machine" &&
        subject.user == "testuser") {
        return polkit.Result.YES;
    }
});
EOF

loginctl enable-linger testuser

run0 -u testuser systemctl start --user systemd-nspawn@zurps.service

machinectl status zurps
machinectl status zurps | grep "UID:" | grep "$(id -u testuser)"
machinectl status zurps | grep "Unit: user@" | grep "$(id -u testuser)"
machinectl status zurps | grep "Subgroup: machine.slice/systemd-nspawn@zurps.service/payload"
machinectl terminate zurps

(! run0 -u testuser systemctl is-active --user systemd-nspawn@zurps.service)

loginctl disable-linger testuser
