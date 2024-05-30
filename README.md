# CloudstackInstallScript
Bash installation script for Cloudstack

This installation script is based on https://github.com/maradens/apachecloudstack

**Warning**: This script only works in apt-based environment (Ubuntu, Debian, etc) as of now.

Note: Cloudstack does not support management server network using wireless interface

# Usage
`sudo bash cloudstack_install.bash`

Prerequisites:
1. Root Privileges: Make sure root privileges is enabled
2. Required Packages: Please install the following packages before you launch the script: `sudo apt-get install "openssh-server" "sudo" "intel-microcode" "mysql-server" "qemu-system-x86" "nfs-kernel-server" "quota" "bridge-utils" "libvirt-daemon-system" "uuid" "iptables-persistent" "netplan.io"`
3. NTP and SSH: Please make sure NTP Service active and SSH Configuration are adjusted to allow root password-based login.
4. Internet Connections: Obviously, you need to be connected to the internet in order to access cloudstack repository.

# CONTINUE WITH INSTALATION (DASHBOARD)
[![IMAGE ALT TEXT HERE](https://img.youtube.com/vi/kO7uZVOm9fw/0.jpg)](https://www.youtube.com/watch?v=kO7uZVOm9fw)

# REGISTER ISO AND ADD INSTANCE
[![IMAGE ALT TEXT HERE](https://img.youtube.com/vi/0sKBQg9rr50/0.jpg)](https://www.youtube.com/watch?v=0sKBQg9rr50)
