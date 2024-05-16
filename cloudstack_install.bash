#!/bin/bash

# List of packages to check
packages=("openssh-server" "sudo" "intel-microcode" "mysql-server" "qemu-system-x86" "nfs-kernel-server" "quota" "bridge-utils" "libvirt-daemon-system" "uuid" "iptables-persistent")

# Function to check if a package is installed
is_installed() {
    dpkg -s $1 &> /dev/null
}

# Function to check NTP status
is_ntp_active(){
    timedatectl timesync-status &> /dev/null
}

# Function to ping repo
is_repo_reachable(){
    ping -c 1 packages.shapeblue.com &> /dev/null
}

# Function to not exit when error and in debug mode
debug=1
debug_err_exit(){
    if [[ $debug -eq 0 ]]; then
        exit 1
    fi
}

curUnixTime=$(date +%s)

###################################################################################################
# Check if the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi


# Check if each package is installed and up-to-date
c=0
for package in "${packages[@]}"; do
    if ! is_installed "$package"; then
        echo "ERROR: $package is not installed."
	((c++))
    fi
done
if [[ $c -gt 0 ]]; then
    echo "ERROR: Please install the aforementioned packages in order to continue the installation."
    debug_err_exit
fi
echo "Cloudstack dependency has been satisfied."


# Check if NTP service is active
if ! is_ntp_active; then
    echo "ERROR: NTP service is not active." 
    echo "You must configure NTP service in order to continue the installation."
    debug_err_exit
fi
echo "NTP service active."

# Check SSH configuration via login test to root in this machine (localhost)
echo "Testing local root SSH login..."
if ! ssh root@localhost exit; then
    echo "ERROR: Local root SSH login failed."
    echo "Please change the local SSH server configuration (/etc/ssh/sshd_config) to allow password-based root login."
    echo "You might also want to check whether root user is accessible via normal login (using "su" command, for example)."
    exit 1
fi
echo "Local root SSH login succesful."


# Test connectivity to Shapeblue Cloudstack repo
echo "Checking connection to Shapeblue Cloudstack repository..."
c=0
for i in {1..5}; do
    if is_repo_reachable; then
        ((c++))
    fi
done
if [[ $c -lt 3 ]]; then
    echo "ERROR: Shapeblue Cloudstack repository unreachable."
    echo "Please check your connection status."
    debug_err_exit
fi
echo "Connection check succesful."


# Configure Shapeblue Cloudstack keyring, and check for existing one
if [[ ! -e /etc/apt/keyrings/cloudstack.gpg ]]; then
    echo "Fetching Shapeblue repository keyring..."
    wget -O- --quiet http://packages.shapeblue.com/release.asc | gpg --dearmor > tee /etc/apt/keyrings/cloudstack.gpg
    echo "Keyring fetched."
fi


# Add Shapeblue Cloudstack repository to apt source list, and check for existing one
if [[ ! -e /etc/apt/sources.list.d/cloudstack.list ]]; then
    echo deb [signed-by=/etc/apt/keyrings/cloudstack.gpg] http://packages.shapeblue.com/cloudstack/upstream/debian/4.18 / > /etc/apt/sources.list.d/cloudstack.list
    echo "Apt source list has been updated."
fi

# Configure MySQL server
echo "Configuring MySQL Server..."
if [[ ! -f  /etc/mysql/mysql.conf.d/mysqld.cnf ]]; then
    echo "ERROR: MySQL server config file not found. Please ensure that the configuration file (/etc/mysql/mysql.conf.d/mysqld.cnf) exists."
    exit 1
fi
mv /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf_backup$curUnixTime
echo "Old MySQL server config file has been renamed to mysqld.cnf_backup$curUnixTime"

echo '[mysqld]
server-id = 1
sql-mode="STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION"
innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=1000
log-bin=mysql-bin
binlog-format="ROW"
user=mysql
bind-address=127.0.0.1
mysqlx-bind-address=127.0.0.1
key_buffer_size=16M
myisam-recover-options=BACKUP
log_error = /var/log/mysql/error.log
max_binlog_size   = 100M' > /etc/mysql/mysql.conf.d/mysqld.cnf
if [[ $? -eq 0 ]]; then
    echo "MySQL configuration succesful."
else   
    exit 1;
fi

if ! grep -s -q -F -e "/export" /etc/exports; then
    echo "/export  *(rw,async,no_root_squash,no_subtree_check)" >> /etc/exports
fi
mkdir -p /export/primary /export/secondary
exportfs -a
sed -i -e 's/^RPCMOUNTDOPTS="--manage-gids"$/RPCMOUNTDOPTS="-p 892 --manage-gids"/g' /etc/default/nfs-kernel-server
sed -i -e 's/^STATDOPTS=$/STATDOPTS="--port 662 --outgoing-port 2020"/g' /etc/default/nfs-common
if ! grep "^NEED_STATD" /etc/default/nfs-common; then
  echo "NEED_STATD=yes" >> /etc/default/nfs-common
fi
sed -i -e 's/^RPCRQUOTADOPTS=$/RPCRQUOTADOPTS="-p 875"/g' /etc/default/quota
service nfs-kernel-server restart
echo "NFS exports configured."

echo "Configuring network interface..."
for file in /etc/netplan/*; do
    if [ -f "$file" ] && [[ "$file" != *_backup ]]; then
      sudo mv "$file" "${file}_backup"
      echo "File $file has been renamed to ${file}_backup"
    fi
done
echo '# Automatically generated by cloudstack_install.bash
network:
  version: 2
  renderer: networkd
  ethernets:
    eno1:
      dhcp4: false
      dhcp6: false
      optional: true
  bridges:
    cloudbr0:
      addresses: [192.168.104.10/24]
      routes:
        - to: default
          via: 192.168.104.1
      nameservers:
        addresses: [1.1.1.1,8.8.8.8]
      interfaces: [eno1]
      dhcp4: false
      dhcp6: false
      parameters:
        stp: false
        forward-delay: 0' > /etc/netplan/01-netcfg.yaml
net_int=$(ls /sys/class/net)
IFS=' ' set -- $net_int; net_int=("$@");
echo "Pick one network interface to be used for cloud network bridge"
i=0
for interface in ${net_int[@]}; do
  echo "[$i] $interface"
  ((i++))
done
((i--))
read user_input
if [[ $user_input -gt i ]] || [[ $user_input -lt 0 ]]; then
  echo "Invalid input"
  exit 1
fi
chosen_int=${net_int[user_input]}
sed -i -e "s/eno1/$chosen_int/g" /etc/netplan/01-netcfg.yaml
ip_addr=$(ip -4 addr show dev $chosen_int | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
gw=$(ip route | grep $chosen_int | grep dhcp | grep -v default | awk '{print $1}')
sed -i -e "s#192\.168\.104\.10/24#$ip_addr/24#g" /etc/netplan/01-netcfg.yaml
sed -i -e "s#192\.168\.104\.1\$#$gw#g" /etc/netplan/01-netcfg.yaml
chmod go-r /etc/netplan/01-netcfg.yaml
chmod go-w /etc/netplan/01-netcfg.yaml
netplan generate
netplan apply
echo "Network configuration succesful."

sed -i -e 's/\#vnc_listen.*$/vnc_listen = "0.0.0.0"/g' /etc/libvirt/qemu.conf
sed -i.bak 's/^\(LIBVIRTD_ARGS=\).*/\1"--listen"/' /etc/default/libvirtd
cfg_params=('listen_tls=0' 'listen_tcp=1' 'tcp_port="16509"' 'mdns_adv=0' 'auth_tcp="none"')
for cfg_param in ${cfg_params[@]}; do
  if ! grep "^${cfg_param}$" /etc/libvirt/libvirtd.conf; then
    echo "${cfg_param}" >> /etc/libvirt/libvirtd.conf
  fi
done
systemctl mask libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd-tls.socket libvirtd-tcp.socket
systemctl restart libvirtd

cfg_params=('net.bridge.bridge-nf-call-arptables=0' 'net.bridge.bridge-nf-call-iptables=0')
for cfg_param in ${cfg_params[@]}; do
  if ! grep "^${cfg_param}$" /etc/sysctl.conf; then
    echo "${cfg_param}" >> /etc/sysctl.conf
  fi
done
sysctl -p

UUID=$(uuid)
if ! grep "^host_uuid" /etc/sysctl.conf; then
  echo host_uuid = \"$UUID\" >> /etc/libvirt/libvirtd.conf
fi
systemctl restart libvirtd

NETWORK_ADDR=ip route | grep $chosen_int | grep kernel | grep -v default | awk '{print $1}'
tcpport_open=(111 2049 32803 892 875 662 3128 8250 8080 8443 9090 16514)
for port in ${tcpport_open[@]}; do
  iptables -A INPUT -s $NETWORK_ADDR -m state --state NEW -p tcp --dport $port -j ACCEPT
done
udpport_open=(111 3128 32769)
for port in ${udpport_open[@]}; do
  iptables -A INPUT -s $NETWORK_ADDR -m state --state NEW -p tcp --dport $port -j ACCEPT
done

ln -s /etc/apparmor.d/usr.sbin.libvirtd /etc/apparmor.d/disable/
ln -s /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper /etc/apparmor.d/disable/
apparmor_parser -R /etc/apparmor.d/usr.sbin.libvirtd
apparmor_parser -R /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper

apt-get update -y
apt-get install -y cloudstack-management cloudstack-usage cloudstack-agent
cloudstack-setup-databases cloud:cloud@localhost --deploy-as=root:password -i $ip_addr
cloudstack-setup-management


exit 0




