#!/bin/bash

# List of packages to check
packages=("openssh-server" "sudo" "intel-microcode" "mysql-server" "qemu-system-x86" "nfs-kernel-server" "quota" "bridge-utils" "libvirt-daemon-system" "uuid" "iptables-persistent" "netplan.io")

# Function to check if a package is installed
is_installed() {
    dpkg -s $1 &> /dev/null
}

# Function to check NTP status
is_ntp_active(){
    timedatectl | awk 'NR==6 {print $3}' | grep active &> /dev/null
}

# Function to ping repo
is_repo_reachable(){
    wget --spider packages.shapeblue.com &> /dev/null
}

run_command(){
  eval "$1"
  if [[ $? -ne 0 ]]; then
    echo "Fatal Error"
    exit 1
  fi
}

curUnixTime=$(date +%s)

mysql_basecfg='[mysqld]
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
log_error=/var/log/mysql/error.log
max_binlog_size=100M'

net_basecfg=\
'# Automatically generated by cloudstack_install.bash
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
          forward-delay: 0'

###################################################################################################
# Check if the script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Please run this script as root."
  exit 1
fi

isInstalled_path="/root/.config/cloudstack/installed"
if [[ -f $isInstalled_path ]]; then
  echo "Cloudstack is already installed"
  echo "To uninstall, run: [sudo apt-get purge \"cloudstack*\"] and [sudo rm /root/.config/cloudstack/installed]"
  exit 1
fi

# Check if each package is installed and up-to-date
c=0 # Missing package count
for package in "${packages[@]}"; do
    if ! is_installed "$package"; then
        echo "ERROR: $package is not installed."
	((c++))
    fi
done
if [[ $c -gt 0 ]]; then #If there's any missing package
    echo "ERROR: Please install the aforementioned packages in order to continue the installation."
    exit 1
fi
echo "Cloudstack dependency has been satisfied."


# Check if NTP service is active
if ! is_ntp_active; then
    echo "ERROR: NTP service is not active." 
    echo "You must configure NTP service in order to continue the installation."
    exit 1
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
c=0 # Successful ping count
for i in {1..5}; do # Test ping 5 times
    if is_repo_reachable; then
        ((c++))
    fi
done
if [[ $c -lt 3 ]]; then  #If <3/5 ping is successful, network issue
    echo "ERROR: Shapeblue Cloudstack repository unreachable."
    echo "Please check your connection status."
    exit 1
fi
echo "Connection check succesful."

keyring_path="/etc/apt/keyrings/cloudstack.gpg"
# Configure Shapeblue Cloudstack keyring
if [[ ! -e $keyring_path ]]; then
    echo "Fetching Shapeblue repository keyring..."
    keyring_url="http://packages.shapeblue.com/release.asc"
    run_command "wget -O- --quiet $keyring_url | gpg --dearmor > $keyring_path"
    echo "Keyring fetched."
fi


# Add Shapeblue Cloudstack repository to apt source list
srclist_path="/etc/apt/sources.list.d/cloudstack.list"
if [[ ! -e $srclist_path ]]; then
    repo_url="http://packages.shapeblue.com/cloudstack/upstream/debian/4.18"
    echo "deb [signed-by=$keyring_path] $repo_url /" > $srclist_path
    echo "Apt source list has been updated."
fi


# Configure MySQL server
echo "Configuring MySQL Server..."
mysqlcfg_path="/etc/mysql/mysql.conf.d/mysqld.cnf"
if [[ ! -f $mysqlcfg_path  ]]; then #If mysql server cfg file not exists
    echo "ERROR: MySQL server config file not found. Please ensure that the configuration file ($mysqlcfg_path) exists."
    exit 1
fi
backup_name="${mysqlcfg_path}_backup${curUnixTime}"
mv $mysqlcfg_path $backup_name #Back up old config
echo "Old MySQL server config file has been renamed to $backup_name"
echo "$mysql_basecfg" > $mysqlcfg_path
if [[ $? -eq 0 ]]; then
    echo "MySQL configuration succesful."
else   
    exit 1;
fi


# Configure NFS server
nfsserver_path="/etc/default/nfs-kernel-server"
exports_path="/etc/exports"
nfscommon_path="/etc/default/nfs-common"
quota_path="/etc/default/quota"
for path in ${nfsserver_path} ${exports_path} ${nfscommon_path} ${quota_path}; do
  if [[ ! -f $path ]]; then
    echo "$path directory not found!"
    exit 1
  fi
done
if ! grep -s -q -F -e "/export" /etc/exports; then #If /etc/exports has no entry on /export
    echo "/export  *(rw,async,no_root_squash,no_subtree_check)" >> /etc/exports
fi
mkdir -p /export/primary /export/secondary
run_command "exportfs -a"
sed -i -e 's/^RPCMOUNTDOPTS="--manage-gids"$/RPCMOUNTDOPTS="-p 892 --manage-gids"/g' ${nfsserver_path}
sed -i -e 's/^STATDOPTS=$/STATDOPTS="--port 662 --outgoing-port 2020"/g' ${nfscommon_path}
sed -i -e 's/^NEED_STATD=$/NEED_STATD=yes/g' ${nfscommon_path}
sed -i -e 's/^RPCRQUOTADOPTS=$/RPCRQUOTADOPTS="-p 875"/g' ${quota_path}
run_command "service nfs-kernel-server restart"
echo "NFS exports configured."


# Configure network interface
echo "Configuring network interface..."
netcfg_path="/etc/netplan/01-cloudstack-cfg.yaml"
if [[ ! -f $netcfg_path ]]; then # If no cloudstack net config, create it
  for file in /etc/netplan/*; do # Backup existing net config
      if [ -f "$file" ] && [[ "$file" != *_backup* ]]; then # If file exists and not a backup
        sudo mv "$file" "${file}_backup${curUnixTime}"
        echo "File $file has been renamed to ${file}_backup${curUnixTime}"
      fi
  done
  echo "$net_basecfg" > $netcfg_path # Pass base cfg to path
  net_int=$(ls /sys/class/net | grep -E "(en|eth)"); IFS=' ' set -- $net_int
  net_int=("$@"); # Get list of network interface
  echo "Pick one network interface to be used for cloud network bridge"
  i=0
  for interface in ${net_int[@]}; do # Display choice of existing interface
    echo "[$i] $interface"
    ((i++))
  done
  ((i--))
  read user_input
  if [[ $user_input -gt i ]] || [[ $user_input -lt 0 ]]; then # Input sanitization
    echo "Invalid input"
    exit 1
  fi
  chosen_int=${net_int[user_input]} #Get chosen interface
  ip_addr=$(ip -4 addr show dev $chosen_int | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  gw=$(ip route | grep $chosen_int | grep default | awk '{print $3}')
  for string_var in "chosen_int" "ip_addr" "gw"; do
    if [[ -z ${!string_var} ]]; then
      echo "ERROR: Unexpected empty string ($string_var)"
      exit 1
    fi
  done
  sed -i -e "s/eno1/$chosen_int/g" $netcfg_path #Replace template from net_basecfg with appropriate param
  sed -i -e "s#192\.168\.104\.10/24#$ip_addr/24#g" $netcfg_path 
  sed -i -e "s#192\.168\.104\.1\$#$gw#g" $netcfg_path
  chmod go-r $netcfg_path # Modify netplan config permission (no rw from other)
  chmod go-w $netcfg_path
  run_command "netplan generate"
  run_command "netplan apply"
  run_command "systemctl restart NetworkManager systemd-networkd"
  run_command "modprobe ip_conntrack"
  run_command "modprobe nf_conntrack"
else # Cloudstack net config already exists
  echo "Network already configured ($netcfg_path already exists)"
  chosen_int="cloudbr0"
  if ! ip addr show dev $chosen_int  &> /dev/null; then
    echo "ERROR: Interface cloudbr0 does not exist but net config already present."
    echo "Please delete existing configuration ($netcfg_path) and run this script again."
    exit 1
  fi
  ip_addr=$(ip -4 addr show dev $chosen_int | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
  gw=$(ip route | grep $chosen_int | grep default | awk '{print $3}')
fi
sleep 5
if ! is_repo_reachable; then
  echo "ERROR: Network configured, but failed to reach repository"
  exit 1
fi
echo "Network configuration succesful."

# Configure libvirtd
echo "Configuring libvirtd..."
sed -i -e 's/\#vnc_listen.*$/vnc_listen = "0.0.0.0"/g' /etc/libvirt/qemu.conf
sed -i.bak 's/^\(LIBVIRTD_ARGS=\).*/\1"--listen"/' /etc/default/libvirtd
cfg_params=('listen_tls=0' 'listen_tcp=1' 'tcp_port="16509"' 'mdns_adv=0' 'auth_tcp="none"')
for cfg_param in ${cfg_params[@]}; do # Insert param to config file
  if ! grep "^${cfg_param}$" /etc/libvirt/libvirtd.conf &> /dev/null; then # If config param is not present
    echo "${cfg_param}" >> /etc/libvirt/libvirtd.conf
  fi
done
UUID=$(uuid)
if ! grep "^host_uuid" /etc/libvirt/libvirtd.conf &> /dev/null; then # If config param is not present
  echo host_uuid = \"$UUID\" >> /etc/libvirt/libvirtd.conf
fi
run_command "systemctl mask libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd-tls.socket libvirtd-tcp.socket"
run_command "systemctl restart libvirtd"
echo "libvirtd config succesful."


# Configure firewall
echo "Configuring firewall..."
run_command "modprobe br_netfilter"
cfg_params=('net.bridge.bridge-nf-call-arptables=0' 'net.bridge.bridge-nf-call-iptables=0')
for cfg_param in ${cfg_params[@]}; do
  if ! grep "^${cfg_param}$" /etc/sysctl.conf &> /dev/null; then
    echo "${cfg_param}" >> /etc/sysctl.conf
  fi
done
run_command "sysctl -p &> /dev/null"
NETWORK_ADDR=$(ip route | grep cloudbr0 | grep kernel | grep -v default | awk '{print $1}')
tcpport_open=(111 2049 32803 892 875 662 3128 8250 8080 8443 9090 16514)
for port in ${tcpport_open[@]}; do
  run_command "iptables -A INPUT -s $NETWORK_ADDR -m state --state NEW -p tcp --dport $port -j ACCEPT"
done
udpport_open=(111 3128 32769)
for port in ${udpport_open[@]}; do
  run_command "iptables -A INPUT -s $NETWORK_ADDR -m state --state NEW -p udp --dport $port -j ACCEPT"
done
run_command "iptables-save > /etc/iptables/rules.v4"
echo "Firewall configuration succesful."

# Configure AppArmor
echo "Configuring AppArmor..."
ln -s /etc/apparmor.d/usr.sbin.libvirtd /etc/apparmor.d/disable/ &> /dev/null
ln -s /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper /etc/apparmor.d/disable/ &> /dev/null
apparmor_parser -R /etc/apparmor.d/usr.sbin.libvirtd &> /dev/null
apparmor_parser -R /etc/apparmor.d/usr.lib.libvirt.virt-aa-helper &> /dev/null
echo "AppArmor configuration succesful."

echo "Installing Cloudstack package..."
run_command "apt-get update -y"
run_command "apt-get install -y cloudstack-management cloudstack-usage cloudstack-agent"
echo -n "Enter root password of this machine: "
read -rs password
echo
run_command "cloudstack-setup-databases cloud:cloud@localhost --deploy-as=root:$password -i $ip_addr"
run_command "cloudstack-setup-management"
echo "Cloudstack installation successful!"

mkdir -p /root/.config/cloudstack/
touch /root/.config/cloudstack/installed

echo "Open management console in http://$ip_addr:8080/client"
echo "Use default credential. (Username: admin) (Password: password)"
exit 0
