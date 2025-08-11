#!/bin/bash
# shellcheck disable=SC1091,SC2164,SC2034,SC1072,SC1073,SC1009

# Secure OpenVPN server installer for Debian, Ubuntu, CentOS, Amazon Linux 2, Fedora, Oracle Linux 8, Arch Linux, Rocky Linux and AlmaLinux.
# https://github.com/angristan/openvpn-install

OPENVPN_ROOT="/etc/openvpn"
UNBOUND_ROOT="/etc/unbound"
UNBOUND_CONF="$UNBOUND_ROOT/unbound.conf"
UNBOUND_OPENVPN_CONF="$UNBOUND_ROOT/openvpn.conf"
EASYRSA_ROOT="$OPENVPN_ROOT/easy-rsa"
EASYRSA_PKI="$EASYRSA_ROOT/pki"
SERVER_CONF="$OPENVPN_ROOT/server.conf"
CLIENT_TEMPLATE="$OPENVPN_ROOT/client-template.txt"

IPTABLES_ROOT="/etc/iptables"

ADD_OPENVPN_RULES="$IPTABLES_ROOT/add-openvpn-rules.sh"
RM_OPENVPN_RULES="$IPTABLES_ROOT/rm-openvpn-rules.sh"

function isRoot() {
	if [ "$EUID" -ne 0 ]; then
		return 1
	fi
}

function tunAvailable() {
	if [ ! -e /dev/net/tun ]; then
		return 1
	fi
}

function checkOS() {
	if [[ -e /etc/debian_version ]]; then
		OS="debian"
		source /etc/os-release

		if [[ $ID == "debian" || $ID == "raspbian" ]]; then
			if [[ $VERSION_ID -lt 9 ]]; then
				echo "⚠️ Your version of Debian is not supported."
				echo ""
				echo "However, if you're using Debian >= 9 or unstable/testing, you can continue at your own risk."
				echo ""
				until [[ $CONTINUE =~ (y|n) ]]; do
					read -rp "Continue? [y/n]: " -e CONTINUE
				done
				if [[ $CONTINUE == "n" ]]; then
					exit 1
				fi
			fi
		elif [[ $ID == "ubuntu" ]]; then
			OS="ubuntu"
			MAJOR_UBUNTU_VERSION=$(echo "$VERSION_ID" | cut -d '.' -f1)
			if [[ $MAJOR_UBUNTU_VERSION -lt 16 ]]; then
				echo "⚠️ Your version of Ubuntu is not supported."
				echo ""
				echo "However, if you're using Ubuntu >= 16.04 or beta, you can continue at your own risk."
				echo ""
				until [[ $CONTINUE =~ (y|n) ]]; do
					read -rp "Continue? [y/n]: " -e CONTINUE
				done
				if [[ $CONTINUE == "n" ]]; then
					exit 1
				fi
			fi
		fi
	elif [[ -e /etc/system-release ]]; then
		source /etc/os-release
		if [[ $ID == "fedora" || $ID_LIKE == "fedora" ]]; then
			OS="fedora"
		fi
		if [[ $ID == "centos" || $ID == "rocky" || $ID == "almalinux" ]]; then
			OS="centos"
			if [[ ${VERSION_ID%.*} -lt 7 ]]; then
				echo "⚠️ Your version of CentOS is not supported."
				echo ""
				echo "The script only supports CentOS 7 and CentOS 8."
				echo ""
				exit 1
			fi
		fi
		if [[ $ID == "ol" ]]; then
			OS="oracle"
			if [[ ! $VERSION_ID =~ (8) ]]; then
				echo "Your version of Oracle Linux is not supported."
				echo ""
				echo "The script only supports Oracle Linux 8."
				exit 1
			fi
		fi
		if [[ $ID == "amzn" ]]; then
			if [[ $VERSION_ID == "2" ]]; then
				OS="amzn"
			elif [[ "$(echo "$PRETTY_NAME" | cut -c 1-18)" == "Amazon Linux 2023." ]] && [[ "$(echo "$PRETTY_NAME" | cut -c 19)" -ge 6 ]]; then
				OS="amzn2023"
			else
				echo "⚠️ Your version of Amazon Linux is not supported."
				echo ""
				echo "The script only supports Amazon Linux 2 or Amazon Linux 2023.6+"
				echo ""
				exit 1
			fi
		fi
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	else
		echo "It looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, Amazon Linux 2, Oracle Linux 8 or Arch Linux system."
		exit 1
	fi
}

function installSpeedtest() {
	case "$OS" in
		debian|ubuntu) apt-get update && apt-get install -y speedtest-cli ;;
		fedora) dnf install -y speedtest-cli ;;
		centos|oracle) yum install -y speedtest-cli ;;
		amzn|amzn2023) yum install -y speedtest-cli ;;
		arch) pacman -Sy --noconfirm speedtest-cli ;;
		*)
			echo "❌ No install method for $OS."
			exit 1
			;;
	esac
}

function runSpeedtest() {
	if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
		echo "⚙️ Installing speedtest-cli..."
		 installSpeedtest
	fi

	if command -v speedtest &>/dev/null; then
		speedtest --secure
	elif command -v speedtest-cli &>/dev/null; then
		speedtest-cli
	else
		echo "❌ Speedtest utility not found after install."
		exit 1
	fi
}

function initialCheck() {
	if ! isRoot; then
		echo "Sorry, you need to run this script as root."
		exit 1
	fi
	if ! tunAvailable; then
		echo "TUN is not available."
		exit 1
	fi
	checkOS
}

function installUnbound() {
	case "$OS" in
		debian|ubuntu) PM="apt-get install -y" ;;
		centos|amzn|oracle) PM="yum install -y" ;;
		fedora) PM="dnf install -y" ;;
		arch) PM="pacman -Syu --noconfirm" ;;
		*) echo "Unsupported OS: $OS"; return 1 ;;
	esac

	if [[ ! -e $UNBOUND_CONF ]]; then
		$PM unbound

		if [[ $OS == "arch" ]]; then
			curl -o "$UNBOUND_ROOT/root.hints" https://www.internic.net/domain/named.cache
		fi

		[[ -f "$UNBOUND_CONF" ]] && mv "$UNBOUND_CONF" "$UNBOUND_CONF.old"

		cat > "$UNBOUND_CONF" <<EOF
server:
	interface: 10.8.0.1
	access-control: 10.8.0.1/24 allow
	hide-identity: yes
	hide-version: yes
	use-caps-for-id: yes
	prefetch: yes
EOF

		if [[ $IPV6_SUPPORT == 'y' ]]; then
			cat >> "$UNBOUND_CONF" <<EOF
	interface: fd42:42:42:42::1
	access-control: fd42:42:42:42::/112 allow
EOF
		fi

		cat >> "$UNBOUND_CONF" <<EOF
	private-address: 10.0.0.0/8
	private-address: fd42:42:42:42::/112
	private-address: 172.16.0.0/12
	private-address: 192.168.0.0/16
	private-address: 169.254.0.0/16
	private-address: fd00::/8
	private-address: fe80::/10
	private-address: 127.0.0.0/8
	private-address: ::ffff:0:0/96
EOF

		if [[ $OS == "arch" ]]; then
			cat >> "$UNBOUND_CONF" <<EOF
	use-syslog: yes
	do-daemonize: no
	username: "unbound"
	directory: $UNBOUND_ROOT
	trust-anchor-file: trusted-key.key
	root-hints: root.hints
	port: 53
	num-threads: 2
	harden-glue: yes
	qname-minimisation: yes
EOF
		fi

	else
		echo "include: $UNBOUND_OPENVPN_CONF" >> "$UNBOUND_CONF"

		cat > "$UNBOUND_OPENVPN_CONF" <<EOF
server:
	interface: 10.8.0.1
	access-control: 10.8.0.1/24 allow
	hide-identity: yes
	hide-version: yes
	use-caps-for-id: yes
	prefetch: yes
	private-address: 10.0.0.0/8
	private-address: fd42:42:42:42::/112
	private-address: 172.16.0.0/12
	private-address: 192.168.0.0/16
	private-address: 169.254.0.0/16
	private-address: fd00::/8
	private-address: fe80::/10
	private-address: 127.0.0.0/8
	private-address: ::ffff:0:0/96
EOF

		[[ $IPV6_SUPPORT == 'y' ]] && cat >> "$UNBOUND_OPENVPN_CONF" <<EOF
	interface: fd42:42:42:42::1
	access-control: fd42:42:42:42::/112 allow
EOF
	fi

	systemctl enable unbound
	systemctl restart unbound
}

function resolvePublicIP() {
	if [[ $IPV6_SUPPORT == "y" ]]; then
		CURL_IP_VERSION_FLAG=""
		DIG_IP_VERSION_FLAG="-6"
	else
		CURL_IP_VERSION_FLAG="-4"
		DIG_IP_VERSION_FLAG="-4"
	fi

	local services=(
		"https://api.seeip.org"
		"https://ifconfig.me"
		"https://api.ipify.org"
	)

	for url in "${services[@]}"; do
		PUBLIC_IP=$(curl -f -m 5 -sS --retry 2 --retry-connrefused $CURL_IP_VERSION_FLAG "$url" 2>/dev/null) && [[ -n $PUBLIC_IP ]] && break
	done

	[[ -z $PUBLIC_IP ]] && PUBLIC_IP=$(dig $DIG_IP_VERSION_FLAG TXT +short o-o.myaddr.l.google.com @ns1.google.com | tr -d '"')

	if [[ -z $PUBLIC_IP ]]; then
		echo "Couldn't resolve the public IP" >&2
		exit 1
	fi

	echo "$PUBLIC_IP"
}

function askServerIP() {
    echo ""
    echo "I need to know the IPv4 address of the network interface you want OpenVPN listening to."
	echo "Unless your server is behind NAT, it should be your public IPv4 address."

	IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | head -1)

	if [[ -z $IP ]]; then
		IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi

	APPROVE_IP=${APPROVE_IP:-n}
	if [[ $APPROVE_IP =~ n ]]; then
		read -rp "IP address: " -e -i "$IP" IP
	fi

	if echo "$IP" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo ""
		echo "It seems this server is behind NAT. What is its public IPv4 address or hostname?"
		echo "We need it for the clients to connect to the server."

		if [[ -z $ENDPOINT ]]; then
			DEFAULT_ENDPOINT=$(resolvePublicIP)
		fi

		until [[ $ENDPOINT != "" ]]; do
			read -rp "Public IPv4 address or hostname: " -e -i "$DEFAULT_ENDPOINT" ENDPOINT
		done
	fi
}

function askIPv6() {
	echo ""
	echo "Checking for IPv6 connectivity..."
	echo ""
	if type ping6 >/dev/null 2>&1; then
		PING6="ping6 -c3 ipv6.google.com > /dev/null 2>&1"
	else
		PING6="ping -6 -c3 ipv6.google.com > /dev/null 2>&1"
	fi

	if eval "$PING6"; then
		echo "Your host appears to have IPv6 connectivity."
		SUGGESTION="y"
	else
		echo "Your host does not appear to have IPv6 connectivity."
		SUGGESTION="n"
	fi

	echo ""
	until [[ $IPV6_SUPPORT =~ (y|n) ]]; do
		read -rp "Do you want to enable IPv6 support (NAT)? [y/n]: " -e -i $SUGGESTION IPV6_SUPPORT
	done
}

function askPort() {
	echo ""
	echo "What port do you want OpenVPN to listen to?"
	echo "   1) Default: 1194"
	echo "   2) Custom"
	echo "   3) Random [49152-65535]"
	until [[ $PORT_CHOICE =~ ^[1-3]$ ]]; do
		read -rp "Port choice [1-3]: " -e -i 1 PORT_CHOICE
	done

	case $PORT_CHOICE in
	1)
		PORT="1194"
		;;
	2)
		until [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; do
			read -rp "Custom port [1-65535]: " -e -i 1194 PORT
		done
		;;
	3)
		PORT=$(shuf -i49152-65535 -n1)
		echo "Random Port: $PORT"
		;;
	esac
}

function askProtocol() {
	echo ""
	echo "What protocol do you want OpenVPN to use?"
	echo "UDP is faster. Unless it is not available, you shouldn't use TCP."
	echo "   1) UDP"
	echo "   2) TCP"

	until [[ $PROTOCOL_CHOICE =~ ^[1-2]$ ]]; do
		read -rp "Protocol [1-2]: " -e -i 1 PROTOCOL_CHOICE
	done

	case $PROTOCOL_CHOICE in
	1)
		PROTOCOL="udp"
		;;
	2)
		PROTOCOL="tcp"
		;;
	esac
}

function askDNS() {
	echo ""
	echo "What DNS resolvers do you want to use with the VPN?"
	echo "   1) Current system resolvers (from /etc/resolv.conf)"
	echo "   2) Self-hosted DNS Resolver (Unbound)"
	echo "   3) Cloudflare (Anycast: worldwide)"
	echo "   4) Quad9 (Anycast: worldwide)"
	echo "   5) Quad9 uncensored (Anycast: worldwide)"
	echo "   6) FDN (France)"
	echo "   7) DNS.WATCH (Germany)"
	echo "   8) OpenDNS (Anycast: worldwide)"
	echo "   9) Google (Anycast: worldwide)"
	echo "   10) Yandex Basic (Russia)"
	echo "   11) AdGuard DNS (Anycast: worldwide)"
	echo "   12) NextDNS (Anycast: worldwide)"
	echo "   13) Custom"

	until [[ $DNS =~ ^[0-9]+$ ]] && [ "$DNS" -ge 1 ] && [ "$DNS" -le 13 ]; do
		read -rp "DNS [1-12]: " -e -i 11 DNS

		if [[ $DNS == 2 ]] && [[ -e $UNBOUND_CONF ]]; then
			echo ""
			echo "Unbound is already installed."
			echo "You can allow the script to configure it in order to use it from your OpenVPN clients"
			echo "We will simply add a second server to $UNBOUND_CONF for the OpenVPN subnet."
			echo "No changes are made to the current configuration."
			echo ""

			until [[ $CONTINUE =~ (y|n) ]]; do
				read -rp "Apply configuration changes to Unbound? [y/n]: " -e CONTINUE
			done

			if [[ $CONTINUE == "n" ]]; then
				unset DNS
				unset CONTINUE
			fi

		elif [[ $DNS == "13" ]]; then
			until [[ $DNS1 =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
				read -rp "Primary DNS: " -e DNS1
			done

			until [[ $DNS2 =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
				read -rp "Secondary DNS (optional): " -e DNS2
				[[ -z $DNS2 ]] && break
			done
		fi
	done
}

function askCompression() {
	echo ""
	echo "Do you want to use compression? It is not recommended since the VORACLE attack makes use of it."
	until [[ $COMPRESSION_ENABLED =~ (y|n) ]]; do
		read -rp "Enable compression? [y/n]: " -e -i n COMPRESSION_ENABLED
	done

	if [[ $COMPRESSION_ENABLED == "y" ]]; then
		echo "Choose which compression algorithm you want to use: (they are ordered by efficiency)"
		echo "   1) LZ4-v2"
		echo "   2) LZ4"
		echo "   3) LZO"
		until [[ $COMPRESSION_CHOICE =~ ^[1-3]$ ]]; do
			read -rp "Compression algorithm [1-3]: " -e -i 1 COMPRESSION_CHOICE
		done

		case $COMPRESSION_CHOICE in
		1) COMPRESSION_ALG="lz4-v2" ;;
		2) COMPRESSION_ALG="lz4" ;;
		3) COMPRESSION_ALG="lzo" ;;
		esac
	fi
}

function askCipher() {
	echo ""
	echo "Choose a cipher for the data channel:"
	echo "   1) AES-128-GCM (recommended)"
	echo "   2) AES-192-GCM"
	echo "   3) AES-256-GCM"
	until [[ $CIPHER_CHOICE =~ ^[1-3]$ ]]; do
		read -rp "Cipher choice [1-3]: " -e -i 1 CIPHER_CHOICE
	done

	case $CIPHER_CHOICE in
		1) CIPHER="AES-128-GCM" ;;
		2) CIPHER="AES-192-GCM" ;;
		3) CIPHER="AES-256-GCM" ;;
	esac
}

function askCertificate() {
	echo ""
	echo "Choose certificate type:"
	echo "   1) ECDSA (recommended)"
	echo "   2) RSA"
	until [[ $CERT_TYPE =~ ^[1-2]$ ]]; do
		read -rp "Certificate type [1-2]: " -e -i 1 CERT_TYPE
	done

	if [[ $CERT_TYPE == "1" ]]; then
		echo "Choose curve for ECDSA certificate:"
		echo "   1) prime256v1 (recommended)"
		echo "   2) secp384r1"
		echo "   3) secp521r1"
		until [[ $CERT_CURVE_CHOICE =~ ^[1-3]$ ]]; do
			read -rp "ECDSA curve [1-3]: " -e -i 1 CERT_CURVE_CHOICE
		done
		case $CERT_CURVE_CHOICE in
			1) CERT_CURVE="prime256v1" ;;
			2) CERT_CURVE="secp384r1" ;;
			3) CERT_CURVE="secp521r1" ;;
		esac
	else
		echo "Choose RSA key size:"
		echo "   1) 2048 (recommended)"
		echo "   2) 3072"
		echo "   3) 4096"
		until [[ $RSA_SIZE_CHOICE =~ ^[1-3]$ ]]; do
			read -rp "RSA key size [1-3]: " -e -i 1 RSA_SIZE_CHOICE
		done
		case $RSA_SIZE_CHOICE in
			1) CERT_CURVE="2048" ;;
			2) CERT_CURVE="3072" ;;
			3) CERT_CURVE="4096" ;;
		esac
	fi
}

function askControlChannelCipher() {
	echo ""
	echo "Choose cipher for the control channel:"
	echo "   1) TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256 (recommended)"
	echo "   2) TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384"
	until [[ $CC_CIPHER_CHOICE =~ ^[1-2]$ ]]; do
		read -rp "Control channel cipher [1-2]: " -e -i 1 CC_CIPHER_CHOICE
	done
	case $CC_CIPHER_CHOICE in
		1) CC_CIPHER="TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256" ;;
		2) CC_CIPHER="TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384" ;;
	esac
}

function askDiffieHellman() {
	echo ""
	echo "Choose Diffie-Hellman key exchange type:"
	echo "   1) ECDH (recommended)"
	echo "   2) DH"
	until [[ $DH_TYPE =~ ^[1-2]$ ]]; do
		read -rp "DH type [1-2]: " -e -i 1 DH_TYPE
	done

	if [[ $DH_TYPE == "1" ]]; then
		echo "Choose curve for ECDH:"
		echo "   1) prime256v1 (recommended)"
		echo "   2) secp384r1"
		echo "   3) secp521r1"
		until [[ $DH_CURVE_CHOICE =~ ^[1-3]$ ]]; do
			read -rp "ECDH curve [1-3]: " -e -i 1 DH_CURVE_CHOICE
		done
		case $DH_CURVE_CHOICE in
			1) DH_CURVE="prime256v1" ;;
			2) DH_CURVE="secp384r1" ;;
			3) DH_CURVE="secp521r1" ;;
		esac
	else
		echo "Choose DH key size:"
		echo "   1) 2048 (recommended)"
		echo "   2) 3072"
		echo "   3) 4096"
		until [[ $DH_KEYSIZE_CHOICE =~ ^[1-3]$ ]]; do
			read -rp "DH key size [1-3]: " -e -i 1 DH_KEYSIZE_CHOICE
		done
		case $DH_KEYSIZE_CHOICE in
			1) DH_CURVE="2048" ;;
			2) DH_CURVE="3072" ;;
			3) DH_CURVE="4096" ;;
		esac
	fi
}

function askHMAC() {
	echo ""
	echo "Choose HMAC digest algorithm:"
	echo "   1) SHA256 (recommended)"
	echo "   2) SHA384"
	echo "   3) SHA512"
	until [[ $HMAC_CHOICE =~ ^[1-3]$ ]]; do
		read -rp "HMAC algorithm [1-3]: " -e -i 1 HMAC_CHOICE
	done
	case $HMAC_CHOICE in
		1) HMAC_ALG="SHA256" ;;
		2) HMAC_ALG="SHA384" ;;
		3) HMAC_ALG="SHA512" ;;
	esac
}

function askTLSSignature() {
	echo ""
	echo "Choose TLS authentication method:"
	echo "   1) TLS-crypt (recommended)"
	echo "   2) TLS-auth"
	until [[ $TLS_SIG =~ ^[1-2]$ ]]; do
		read -rp "TLS method [1-2]: " -e -i 1 TLS_SIG
	done
}

function askEncryptionSettings() {
	echo ""
	echo "Do you want to customize encryption settings?"
	echo "Unless you know what you're doing, you should stick with the default parameters provided by the script."
	echo "Note that whatever you choose, all choices are safe (unlike OpenVPN's defaults)."
	echo ""

	until [[ $CUSTOMIZE_ENC =~ (y|n) ]]; do
		read -rp "Customize encryption settings? [y/n]: " -e -i n CUSTOMIZE_ENC
	done

	if [[ $CUSTOMIZE_ENC == "n" ]]; then
		CIPHER="AES-128-GCM"
		CERT_TYPE="1"
		CERT_CURVE="prime256v1"
		CC_CIPHER="TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256"
		DH_TYPE="1"
		DH_CURVE="prime256v1"
		HMAC_ALG="SHA256"
		TLS_SIG="1"
	else
		askCipher
		askCertificate
		askControlChannelCipher
		askDiffieHellman
		askHMAC
		askTLSSignature
	fi
}

function installQuestions() {
	echo "Welcome to the OpenVPN installer!"
	echo "The git repository is available at: https://github.com/angristan/openvpn-install"
	echo ""

	echo "I need to ask you a few questions before starting the setup."
	echo "You can leave the default options and just press enter if you are okay with them."

	askServerIP
	askIPv6
	askPort
	askProtocol
	askDNS
	askCompression
    askEncryptionSettings

	echo ""
	echo "Okay, that was all I needed. We are ready to setup your OpenVPN server now."
	echo "You will be able to generate a client at the end of the installation."
	APPROVE_INSTALL=${APPROVE_INSTALL:-n}
	if [[ $APPROVE_INSTALL =~ n ]]; then
		read -n1 -r -p "Press any key to continue..."
	fi
}

function initializeVariables() {
	if [[ $AUTO_INSTALL == "y" ]]; then
		# Set default choices so that no questions will be asked.
		APPROVE_INSTALL=${APPROVE_INSTALL:-y}
		APPROVE_IP=${APPROVE_IP:-y}
		IPV6_SUPPORT=${IPV6_SUPPORT:-n}
		PORT_CHOICE=${PORT_CHOICE:-1}
		PROTOCOL_CHOICE=${PROTOCOL_CHOICE:-1}
		DNS=${DNS:-1}
		COMPRESSION_ENABLED=${COMPRESSION_ENABLED:-n}
		CUSTOMIZE_ENC=${CUSTOMIZE_ENC:-n}
		CLIENT=${CLIENT:-client}
		PASS=${PASS:-1}
		CONTINUE=${CONTINUE:-y}

		if [[ -z $ENDPOINT ]]; then
			ENDPOINT=$(resolvePublicIP)
		fi
	fi
}

function detectNetworkInterface() {
	# Get the "public" interface from the default route
	NIC=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
	if [[ -z $NIC ]] && [[ $IPV6_SUPPORT == 'y' ]]; then
		NIC=$(ip -6 route show default | sed -ne 's/^default .* dev \([^ ]*\) .*$/\1/p')
	fi

	# $NIC can not be empty for script rm-openvpn-rules.sh
	if [[ -z $NIC ]]; then
		echo
		echo "Could not detect public interface."
		echo "This needs for setup MASQUERADE."
		until [[ $CONTINUE =~ (y|n) ]]; do
			read -rp "Continue? [y/n]: " -e CONTINUE
		done
		if [[ $CONTINUE == "n" ]]; then
			exit 1
		fi
	fi
}

function installOpenVPNPackages() {
	if [[ -e $SERVER_CONF ]]; then
		return 0
	fi

	case "$OS" in
		debian|ubuntu)
			apt-get update
			apt-get install -y ca-certificates gnupg wget curl rsync iptables openssl

			if [[ $VERSION_ID == "16.04" ]]; then
				echo "deb http://build.openvpn.net/debian/openvpn/stable xenial main" >/etc/apt/sources.list.d/openvpn.list
				wget -qO - https://swupdate.openvpn.net/repos/repo-public.gpg | apt-key add -
				apt-get update
			fi

			apt-get install -y openvpn
			;;
		centos)
			yum install -y epel-release
			yum install -y openvpn iptables openssl wget ca-certificates curl rsync tar 'policycoreutils-python*'
			;;
		oracle)
			yum install -y oracle-epel-release-el8
			yum-config-manager --enable ol8_developer_EPEL
			yum install -y openvpn iptables openssl wget ca-certificates curl rsync tar policycoreutils-python-utils
			;;
		amzn)
			amazon-linux-extras install -y epel
			yum install -y openvpn iptables openssl wget ca-certificates curl rsync
			;;
		amzn2023)
			dnf install -y openvpn iptables openssl wget ca-certificates
			;;
		fedora)
			dnf install -y openvpn iptables openssl wget ca-certificates curl rsync policycoreutils-python-utils
			;;
		arch)
			pacman --needed --noconfirm -Syu openvpn iptables openssl wget ca-certificates curl rsync
			;;
		*)
			echo "Unsupported OS: $OS" >&2
			return 1
			;;
	esac
}

function removeEasyRsaFolder() {
    # An old version of easy-rsa was available by default in some openvpn packages
    if [[ -d "$EASYRSA_ROOT/" ]]; then
        rm -rf "$EASYRSA_ROOT/"
    fi
}

function detectNoGroup() {
	# Find out if the machine uses nogroup or nobody for the permissionless group
	if grep -qs "^nogroup:" /etc/group; then
		NOGROUP=nogroup
	else
		NOGROUP=nobody
	fi
}

function getOpenVPNVersion() {
    local version_line
    version_line=$(openvpn --version | head -n1)
    if [[ $version_line =~ OpenVPN[[:space:]]([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0.0"
    fi
}

function selectEasyRSAVersion() {
    local ovpn_version=$1
    local major=${ovpn_version%%.*}
    local minor=${ovpn_version#*.}
    minor=${minor%%.*}

    if (( major > 2 )) || { (( major == 2 )) && (( minor >= 4 )); }; then
        # OpenVPN 2.4+ -> EasyRSA 3.x
        echo "3.1.2"
    else
        echo "2.2.2"
    fi
}

function installEasyRSA() {
    local ovpn_version
    ovpn_version=$(getOpenVPNVersion)
    local easyrsa_version
    easyrsa_version=$(selectEasyRSAVersion "$ovpn_version")

    echo "Detected OpenVPN version: $ovpn_version"
    echo "Using EasyRSA version: $easyrsa_version"

    wget -O /tmp/easy-rsa.tgz "https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsa_version}/EasyRSA-${easyrsa_version}.tgz"
    mkdir -p "$EASYRSA_ROOT"
    tar xzf /tmp/easy-rsa.tgz --strip-components=1 --no-same-owner --directory "$EASYRSA_ROOT"
    rm -f /tmp/easy-rsa.tgz
}

function setupEasyRSA() {
	# Install the latest version of easy-rsa from source, if not already installed.
	if [[ ! -d "$EASYRSA_ROOT/" ]]; then

		cd "$EASYRSA_ROOT/" || return
		case $CERT_TYPE in
		1)
			echo "set_var EASYRSA_ALGO ec" >vars
			echo "set_var EASYRSA_CURVE $CERT_CURVE" >>vars
			;;
		2)
			echo "set_var EASYRSA_KEY_SIZE $RSA_KEY_SIZE" >vars
			;;
		esac

		# Generate a random, alphanumeric identifier of 16 characters for CN and one for server name
		SERVER_CN="cn_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
		echo "$SERVER_CN" >SERVER_CN_GENERATED
		SERVER_NAME="server_$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)"
		echo "$SERVER_NAME" >SERVER_NAME_GENERATED

		# Create the PKI, set up the CA, the DH params and the server certificate
		./easyrsa init-pki
		EASYRSA_CA_EXPIRE=3650 ./easyrsa --batch --req-cn="$SERVER_CN" build-ca nopass

		if [[ $DH_TYPE == "2" ]]; then
			# ECDH keys are generated on-the-fly so we don't need to generate them beforehand
			openssl dhparam -out dh.pem $DH_KEY_SIZE
		fi

		EASYRSA_CERT_EXPIRE=3650 ./easyrsa --batch build-server-full "$SERVER_NAME" nopass
		EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl

		case $TLS_SIG in
		1)
			# Generate tls-crypt key
			openvpn --genkey --secret "$OPENVPN_ROOT/tls-crypt.key"
			;;
		2)
			# Generate tls-auth key
			openvpn --genkey --secret "$OPENVPN_ROOT/tls-auth.key"
			;;
		esac
	else
		# If easy-rsa is already installed, grab the generated SERVER_NAME
		# for client configs
		cd "$EASYRSA_ROOT/" || return
		SERVER_NAME=$(cat SERVER_NAME_GENERATED)
	fi
}

function setupCertificates() {
	# Move all the generated files
	cp pki/ca.crt pki/private/ca.key "pki/issued/$SERVER_NAME.crt" "pki/private/$SERVER_NAME.key" "$EASYRSA_PKI/crl.pem" $OPENVPN_ROOT
	if [[ $DH_TYPE == "2" ]]; then
		cp dh.pem $OPENVPN_ROOT
	fi

	# Make cert revocation list readable for non-root
	chmod 644 "$OPENVPN_ROOT/crl.pem"
}

function writeServerConfigHeader() {
    local outfile="$1"

    echo "port $PORT" >"$outfile"
    if [[ $IPV6_SUPPORT == 'n' ]]; then
        echo "proto $PROTOCOL" >>"$outfile"
    else
        echo "proto ${PROTOCOL}6" >>"$outfile"
    fi

    cat >>"$outfile" <<EOF
dev tun
user nobody
group $NOGROUP
persist-key
persist-tun
keepalive 10 120
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
EOF

    case $DNS in
        1)
            if grep -q "127.0.0.53" "/etc/resolv.conf"; then
                RESOLVCONF='/run/systemd/resolve/resolv.conf'
            else
                RESOLVCONF='/etc/resolv.conf'
            fi
            sed -ne 's/^nameserver[[:space:]]\+\([^[:space:]]\+\).*$/\1/p' "$RESOLVCONF" | \
            while read -r line; do
                if [[ $line =~ ^[0-9.]*$ ]] || [[ $IPV6_SUPPORT == 'y' ]]; then
                    echo "push \"dhcp-option DNS $line\"" >>"$outfile"
                fi
            done
            ;;
        2)  echo 'push "dhcp-option DNS 10.8.0.1"' >>"$outfile"
            [[ $IPV6_SUPPORT == 'y' ]] && echo 'push "dhcp-option DNS fd42:42:42:42::1"' >>"$outfile"
            ;;
        3)  echo -e 'push "dhcp-option DNS 1.0.0.1"\npush "dhcp-option DNS 1.1.1.1"' >>"$outfile" ;;
        4)  echo -e 'push "dhcp-option DNS 9.9.9.9"\npush "dhcp-option DNS 149.112.112.112"' >>"$outfile" ;;
        5)  echo -e 'push "dhcp-option DNS 9.9.9.10"\npush "dhcp-option DNS 149.112.112.10"' >>"$outfile" ;;
        6)  echo -e 'push "dhcp-option DNS 80.67.169.40"\npush "dhcp-option DNS 80.67.169.12"' >>"$outfile" ;;
        7)  echo -e 'push "dhcp-option DNS 84.200.69.80"\npush "dhcp-option DNS 84.200.70.40"' >>"$outfile" ;;
        8)  echo -e 'push "dhcp-option DNS 208.67.222.222"\npush "dhcp-option DNS 208.67.220.220"' >>"$outfile" ;;
        9)  echo -e 'push "dhcp-option DNS 8.8.8.8"\npush "dhcp-option DNS 8.8.4.4"' >>"$outfile" ;;
        10) echo -e 'push "dhcp-option DNS 77.88.8.8"\npush "dhcp-option DNS 77.88.8.1"' >>"$outfile" ;;
        11) echo -e 'push "dhcp-option DNS 94.140.14.14"\npush "dhcp-option DNS 94.140.15.15"' >>"$outfile" ;;
        12) echo -e 'push "dhcp-option DNS 45.90.28.167"\npush "dhcp-option DNS 45.90.30.167"' >>"$outfile" ;;
        13) echo "push \"dhcp-option DNS $DNS1\"" >>"$outfile"
            [[ -n $DNS2 ]] && echo "push \"dhcp-option DNS $DNS2\"" >>"$outfile"
            ;;
    esac
    echo 'push "redirect-gateway def1 bypass-dhcp"' >>"$outfile"

    if [[ $IPV6_SUPPORT == 'y' ]]; then
        cat >>"$outfile" <<EOF
server-ipv6 fd42:42:42:42::/112
tun-ipv6
push tun-ipv6
push "route-ipv6 2000::/3"
push "redirect-gateway ipv6"
EOF
    fi
}

function generateServerConfig() {
    local outfile="$SERVER_CONF"
    writeServerConfigHeader "$outfile"

    [[ $COMPRESSION_ENABLED == "y" ]] && echo "compress $COMPRESSION_ALG" >>"$outfile"

    if [[ $DH_TYPE == "1" ]]; then
        echo -e "dh none\necdh-curve $DH_CURVE" >>"$outfile"
    else
        echo "dh dh.pem" >>"$outfile"
    fi

    case $TLS_SIG in
        1) echo "tls-crypt tls-crypt.key" >>"$outfile" ;;
        2) echo "tls-auth tls-auth.key 0" >>"$outfile" ;;
    esac

    cat >>"$outfile" <<EOF
crl-verify crl.pem
ca ca.crt
cert $SERVER_NAME.crt
key $SERVER_NAME.key
auth $HMAC_ALG
cipher $CIPHER
ncp-ciphers $CIPHER
tls-server
tls-version-min 1.2
tls-cipher $CC_CIPHER
client-config-dir $OPENVPN_ROOT/ccd
status /var/log/openvpn/status.log
verb 3
EOF
}

function updateServerConfigHead() {
    local tmpfile
    tmpfile=$(mktemp)
    writeServerConfigHeader "$tmpfile"

    local tail_start
    tail_start=$(grep -n -m1 -E '^(compress|dh )' $SERVER_CONF | cut -d -f1)
    [[ -n $tail_start ]] && tail -n +"$tail_start" $SERVER_CONF >>"$tmpfile"

    mv "$tmpfile" $SERVER_CONF
}

function prepareSystem() {
	# Create client-config-dir dir
	mkdir -p "$OPENVPN_ROOT/ccd"
	# Create log dir
	mkdir -p /var/log/openvpn

	# Enable routing
	echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-openvpn.conf
	if [[ $IPV6_SUPPORT == 'y' ]]; then
		echo 'net.ipv6.conf.all.forwarding=1' >>/etc/sysctl.d/99-openvpn.conf
	fi
	# Apply sysctl rules
	sysctl --system
}

function prepareOpenVPNService() {
    if command -v sestatus &>/dev/null && sestatus | grep -q "Current mode.*enforcing"; then
        if [[ $PORT != "1194" ]]; then
            semanage port -a -t openvpn_port_t -p "$PROTOCOL" "$PORT" 2>/dev/null || true
        fi
    fi

    local service_source service_dest service_name

    case "$OS" in
        arch|fedora|centos|oracle|amzn2023)
            service_source="/usr/lib/systemd/system/openvpn-server@.service"
            service_dest="/etc/systemd/system/openvpn-server@.service"
            service_name="openvpn-server@server"
            ;;
        ubuntu)
            if [[ $VERSION_ID == "16.04" ]]; then
                service_source=""
                service_dest=""
                service_name="openvpn"
            else
                service_source="/lib/systemd/system/openvpn@.service"
                service_dest="/etc/systemd/system/openvpn@.service"
                service_name="openvpn@server"
            fi
            ;;
        *)
            service_source="/lib/systemd/system/openvpn@.service"
            service_dest="/etc/systemd/system/openvpn@.service"
            service_name="openvpn@server"
            ;;
    esac

    if [[ -n "$service_source" && -f "$service_source" ]]; then
        cp "$service_source" "$service_dest"
        sed -i 's|LimitNPROC|#LimitNPROC|' "$service_dest"
        sed -i "s|\$OPENVPN_ROOT/server|\$OPENVPN_ROOT|" "$service_dest"
        systemctl daemon-reload
    fi

    echo "$service_name"
}

function configureAndStartService() {
    local service_name
    service_name=$(prepareOpenVPNService)

    if [[ $OS == "ubuntu" && $VERSION_ID == "16.04" ]]; then
        systemctl enable openvpn
        systemctl start openvpn
    else
        systemctl enable "$service_name"
        systemctl restart "$service_name"
    fi
}

function setupIptablesAndService() {
	local add_rules=()
	local rm_rules=()

	add_rules+=(
		"iptables -t nat -I POSTROUTING 1 -s 10.8.0.0/24 -o $NIC -j MASQUERADE"
		"iptables -I INPUT 1 -i tun0 -j ACCEPT"
		"iptables -I FORWARD 1 -i $NIC -o tun0 -j ACCEPT"
		"iptables -I FORWARD 1 -i tun0 -o $NIC -j ACCEPT"
		"iptables -I INPUT 1 -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT"
	)
	rm_rules+=(
		"iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE"
		"iptables -D INPUT -i tun0 -j ACCEPT"
		"iptables -D FORWARD -i $NIC -o tun0 -j ACCEPT"
		"iptables -D FORWARD -i tun0 -o $NIC -j ACCEPT"
		"iptables -D INPUT -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT"
	)

	if [[ $IPV6_SUPPORT == 'y' ]]; then
		add_rules+=(
			"ip6tables -t nat -I POSTROUTING 1 -s fd42:42:42:42::/112 -o $NIC -j MASQUERADE"
			"ip6tables -I INPUT 1 -i tun0 -j ACCEPT"
			"ip6tables -I FORWARD 1 -i $NIC -o tun0 -j ACCEPT"
			"ip6tables -I FORWARD 1 -i tun0 -o $NIC -j ACCEPT"
			"ip6tables -I INPUT 1 -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT"
		)
		rm_rules+=(
			"ip6tables -t nat -D POSTROUTING -s fd42:42:42:42::/112 -o $NIC -j MASQUERADE"
			"ip6tables -D INPUT -i tun0 -j ACCEPT"
			"ip6tables -D FORWARD -i $NIC -o tun0 -j ACCEPT"
			"ip6tables -D FORWARD -i tun0 -o $NIC -j ACCEPT"
			"ip6tables -D INPUT -i $NIC -p $PROTOCOL --dport $PORT -j ACCEPT"
		)
	fi

	mkdir -p "$IPTABLES_ROOT"

	# Создаём скрипты с правилами
	printf "%s\n" "${add_rules[@]}" > "$ADD_OPENVPN_RULES"
	printf "%s\n" "${rm_rules[@]}" > "$RM_OPENVPN_RULES"

	chmod +x "$ADD_OPENVPN_RULES" "$RM_OPENVPN_RULES"

	# Создаём systemd-сервис
	cat > /etc/systemd/system/iptables-openvpn.service <<EOF
[Unit]
Description=iptables rules for OpenVPN
Before=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ADD_OPENVPN_RULES
ExecStop=$RM_OPENVPN_RULES
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable iptables-openvpn
	systemctl start iptables-openvpn
}

function writeClientTemplateHeader() {
    local outfile="$1"

    echo "client" >"$outfile"

    if [[ $PROTOCOL == 'udp' ]]; then
        echo "proto udp" >>"$outfile"
        echo "explicit-exit-notify" >>"$outfile"
    elif [[ $PROTOCOL == 'tcp' ]]; then
        echo "proto tcp-client" >>"$outfile"
    fi

    local ip_to_use="$IP"
    [[ -n $ENDPOINT ]] && ip_to_use="$ENDPOINT"

    echo "remote $ip_to_use $PORT" >>"$outfile"
}

function createClientTemplate() {
    local outfile=$CLIENT_TEMPLATE

    writeClientTemplateHeader "$outfile"

    cat >>"$outfile" <<EOF
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name $SERVER_NAME name
auth $HMAC_ALG
auth-nocache
cipher $CIPHER
tls-client
tls-version-min 1.2
tls-cipher $CC_CIPHER
ignore-unknown-option block-outside-dns
setenv opt block-outside-dns # Prevent Windows 10 DNS leak
verb 3
EOF

    [[ $COMPRESSION_ENABLED == "y" ]] && echo "compress $COMPRESSION_ALG" >>"$outfile"
}

function updateClientTemplateHead() {
    local tmpfile
    tmpfile=$(mktemp)
    writeClientTemplateHeader "$tmpfile"

    local tail_start
    tail_start=$(grep -n -m1 '^dev tun' $CLIENT_TEMPLATE | cut -d -f1)
    [[ -n $tail_start ]] && tail -n +"$tail_start" $CLIENT_TEMPLATE >>"$tmpfile"

    mv "$tmpfile" $CLIENT_TEMPLATE
}

function installOpenVPN() {
    initializeVariables
    installQuestions
    detectNetworkInterface
    installOpenVPNPackages
    detectNoGroup
    removeEasyRsaFolder
    installEasyRSA
    setupEasyRSA
    setupCertificates
    generateServerConfig
    prepareSystem
    configureAndStartService

    [[ $DNS == 2 ]] && installUnbound

    setupIptablesAndService
    createClientTemplate

	# Generate the custom client.ovpn
    newClient
    echo "If you want to add more clients, you simply need to run this script another time!"
}

function restartOrReloadServices() {
    # Iterate through known service names
    SERVICE_NAMES=(
        "openvpn-server@server"
        "openvpn@server"
        "openvpn-server"
        "openvpn"
    )

    local svc=""
    for s in "${SERVICE_NAMES[@]}"; do
        if systemctl list-unit-files --type=service | grep -q "^${s}.service"; then
            svc="$s"
            break
        fi
    done

    echo "Validating OpenVPN configuration..."
    if command -v openvpn >/dev/null 2>&1; then
        if openvpn --help 2>&1 | grep -q -- '--test-parse'; then
            openvpn --config $SERVER_CONF --test-parse || echo "Warning: Syntax error detected in configuration."
        else
            echo "Skipping syntax check — feature not supported by this build."
        fi
    else
        echo "OpenVPN executable not found in PATH."
    fi

    if [[ -n "$svc" ]]; then
        echo "Restarting systemd service: $svc"
        systemctl daemon-reload || true
        if ! systemctl restart "${svc}.service"; then
            echo "Could not restart $svc. Please review logs: journalctl -u ${svc}.service -n 200"
            logger -t restore_openvpn "Failed to restart $svc after restore"
            return 1
        fi
        echo "Service $svc restarted successfully."
        logger -t restore_openvpn "Service $svc restarted after restore"
    else
        echo "Suitable systemd unit for OpenVPN was not found."
    fi

    # Restart associated services
    for related_service in netfilter-persistent unbound; do
        if systemctl list-unit-files --type=service | grep -q "^${related_service}.service"; then
            systemctl restart "${related_service}.service" || echo "Could not restart ${related_service}."
        fi
    done
}

function newClient() {
    echo -e "\nTell me a name for the client.
The name must consist of alphanumeric characters and may include an underscore or a dash."

    # Validate client name
    until [[ $CLIENT =~ ^[a-zA-Z0-9_-]+$ ]]; do
        read -rp "Client name: " -e CLIENT
    done

    echo -e "\nDo you want to protect the configuration file with a password?
(e.g. encrypt the private key with a password)
   1) Add a passwordless client
   2) Use a password for the client"

    until [[ $PASS =~ ^[1-2]$ ]]; do
        read -rp "Select an option [1-2]: " -e -i 1 PASS
    done

    # Check if client already exists
    if grep -qE "/CN=$CLIENT\$" <(tail -n +2 "$EASYRSA_PKI/index.txt"); then
        echo -e "\nThe specified client CN already exists in easy-rsa, please choose another name."
        exit 1
    fi

    # Build client certificate
    cd "$EASYRSA_ROOT/" || exit 1
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa --batch build-client-full "$CLIENT" $([[ $PASS -eq 1 ]] && echo "nopass")

    echo "Client $CLIENT added."

    # Determine home directory
    if [[ -d "/home/$CLIENT" ]]; then
        homeDir="/home/$CLIENT"
    elif [[ $SUDO_USER && $SUDO_USER != "root" ]]; then
        homeDir="/home/$SUDO_USER"
    else
        homeDir="/root"
    fi

    # Determine TLS mode
    if grep -qs "^tls-crypt" "$SERVER_CONF"; then
        TLS_SIG="1"
    elif grep -qs "^tls-auth" "$SERVER_CONF"; then
        TLS_SIG="2"
    fi

    # Create client configuration
    local clientFile="$homeDir/$CLIENT.ovpn"
    cp "$CLIENT_TEMPLATE" "$clientFile"

    {
        echo "<ca>"
        cat "$EASYRSA_PKI/ca.crt"
        echo "</ca>"

        echo "<cert>"
        awk '/BEGIN/,/END CERTIFICATE/' "$EASYRSA_PKI/issued/$CLIENT.crt"
        echo "</cert>"

        echo "<key>"
        cat "$EASYRSA_PKI/private/$CLIENT.key"
        echo "</key>"

        case $TLS_SIG in
            1)
                echo "<tls-crypt>"
                cat "$OPENVPN_ROOT/tls-crypt.key"
                echo "</tls-crypt>"
                ;;
            2)
                echo "key-direction 1"
                echo "<tls-auth>"
                cat "$OPENVPN_ROOT/tls-auth.key"
                echo "</tls-auth>"
                ;;
        esac
    } >>"$clientFile"

    echo -e "\nThe configuration file has been written to $clientFile.
Download the .ovpn file and import it in your OpenVPN client."

    exit 0
}

function selectClient() {
    local CLIENTS=()
    local i=1

    if [[ -z "$EASYRSA_PKI" ]]; then
        echo "EASYRSA_PKI is not set"
        return 1
    fi

	if [[ ! -f "$EASYRSA_PKI/index.txt" ]]; then
		echo "Index file not found: $EASYRSA_PKI/index.txt"
		return 1
	fi

	shopt -s nullglob
	local certs=( "$EASYRSA_PKI/issued"/*.crt )
	shopt -u nullglob

	for CRT in "${certs[@]}"; do
		[[ -f "$CRT" ]] || continue

		local NAME
		NAME=$(basename "$CRT" .crt)

		[[ $NAME =~ ^server_[[:alnum:]]+$ ]] && continue
		[[ $NAME == "server" ]] && continue

		local KEY="$EASYRSA_PKI/private/${NAME}.key"
		[[ ! -f "$KEY" ]] && continue

		local SERIAL
		SERIAL=$(openssl x509 -serial -noout -in "$CRT" 2>/dev/null | cut -d= -f2)
		if [[ -f "$EASYRSA_PKI/index.txt" ]] && grep -qi "^R.*${SERIAL}" "$EASYRSA_PKI/index.txt" 2>/dev/null; then
			continue
		fi

		if ! openssl x509 -checkend 0 -noout -in "$CRT" >/dev/null 2>&1; then
			continue
		fi

		CLIENTS+=("$NAME")
	done

    if [[ ${#CLIENTS[@]} -eq 0 ]]; then
        echo "No available clients."
        return 1
    fi

    echo "Available clients:"
    for name in "${CLIENTS[@]}"; do
        printf "%d) %s\n" "$i" "$name"
        ((i++))
    done

    local choice input
    while true; do
        echo "Enter client numbers/ranges (e.g., 1 3-5 7),"
        echo "or 'all', or 'all except <numbers/ranges>'."
        read -rp "> " input

        choice=()

        if [[ "$input" =~ ^all$ ]]; then
            for ((n=1; n<=${#CLIENTS[@]}; n++)); do
                choice+=("$n")
            done
        elif [[ "$input" =~ ^all[[:space:]]+except[[:space:]]+(.+)$ ]]; then
            local exclude_str="${BASH_REMATCH[1]}"
            local exclude_nums=()
            for token in $exclude_str; do
                if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    local start=${BASH_REMATCH[1]}
                    local end=${BASH_REMATCH[2]}
                    if (( start <= end )); then
                        for ((n=start; n<=end; n++)); do
                            exclude_nums+=("$n")
                        done
                    fi
                elif [[ "$token" =~ ^[0-9]+$ ]]; then
                    exclude_nums+=("$token")
                else
                    echo "Invalid token in exclude list: $token"
                fi
            done
            for ((n=1; n<=${#CLIENTS[@]}; n++)); do
                local skip=false
                for ex in "${exclude_nums[@]}"; do
                    if (( n == ex )); then
                        skip=true
                        break
                    fi
                done
                if [[ $skip == false ]]; then
                    choice+=("$n")
                fi
            done
        else
            for token in $input; do
                if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    local start=${BASH_REMATCH[1]}
                    local end=${BASH_REMATCH[2]}
                    if (( start <= end )); then
                        for ((n=start; n<=end; n++)); do
                            choice+=("$n")
                        done
                    else
                        echo "Invalid range: $token"
                        choice=()
                        break
                    fi
                elif [[ "$token" =~ ^[0-9]+$ ]]; then
                    choice+=("$token")
                else
                    echo "Invalid input: $token"
                    choice=()
                    break
                fi
            done
        fi

        local valid=true
        for num in "${choice[@]}"; do
            if ! [[ "$num" =~ ^[0-9]+$ ]]; then
                echo "Invalid number: $num"
                valid=false
                break
            fi
            if (( num < 1 || num > ${#CLIENTS[@]} )); then
                echo "Invalid number: $num"
                valid=false
                break
            fi
        done

        $valid && break
    done

    mapfile -t choice < <(printf '%s\n' "${choice[@]}" | sort -n -u)

    SELECTED_CLIENTS=()
    for num in "${choice[@]}"; do
        SELECTED_CLIENTS+=("${CLIENTS[$((num-1))]}")
    done

    echo "Selected clients: ${SELECTED_CLIENTS[*]}"
}

function revokeClient() {
    if ! selectClient ; then
        return
    fi

    cd "$EASYRSA_ROOT/" || return

    for CLIENT in "${SELECTED_CLIENTS[@]}"; do
        ./easyrsa --batch revoke "$CLIENT"
        echo "Revoked: $CLIENT"
    done

    EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
    rm -f "$OPENVPN_ROOT/crl.pem"
    cp "$EASYRSA_PKI/crl.pem" "$OPENVPN_ROOT/crl.pem"
    chmod 644 "$OPENVPN_ROOT/crl.pem"

    for CLIENT in "${SELECTED_CLIENTS[@]}"; do
        find /home/ -maxdepth 2 -name "$CLIENT.ovpn" -delete
        rm -f "/root/$CLIENT.ovpn"
        sed -i "/^$CLIENT,.*/d" "$OPENVPN_ROOT/ipp.txt"
    done

    cp "$EASYRSA_PKI/index.txt{,.bk}"

    echo "Clients revoked: ${SELECTED_CLIENTS[*]}"

    # Ask if OpenVPN should be restarted now
    local answer
    read -rp "Do you want to restart OpenVPN now to apply changes? [y/N]: " answer
    case "$answer" in
        [yY][eE][sS]|[yY])
            restartOrReloadServices
            echo "OpenVPN restarted."
            ;;
        *)
            echo "OpenVPN restart skipped."
            ;;
    esac
}

function restoreClientConfig() {
    if ! selectClient ; then
        return
    fi

    if grep -qs "^tls-crypt" $SERVER_CONF; then
        TLS_SIG="1"
    elif grep -qs "^tls-auth" $SERVER_CONF; then
        TLS_SIG="2"
    fi

    for CLIENT in "${SELECTED_CLIENTS[@]}"; do
        # Determine home directory
        if [ -e "/home/${CLIENT}" ]; then
            homeDir="/home/${CLIENT}"
        elif [ "${SUDO_USER}" ]; then
            if [ "${SUDO_USER}" == "root" ]; then
                homeDir="/root"
            else
                homeDir="/home/${SUDO_USER}"
            fi
        else
            homeDir="/root"
        fi

        # Create client config
        cp $CLIENT_TEMPLATE "$homeDir/$CLIENT.ovpn"
        {
            echo "<ca>"
            cat "$EASYRSA_PKI/ca.crt"
            echo "</ca>"

            echo "<cert>"
            awk '/BEGIN/,/END CERTIFICATE/' "$EASYRSA_PKI/issued/$CLIENT.crt"
            echo "</cert>"

            echo "<key>"
            cat "$EASYRSA_PKI/private/$CLIENT.key"
            echo "</key>"

            case $TLS_SIG in
            1)
                echo "<tls-crypt>"
                cat "$OPENVPN_ROOT/tls-crypt.key"
                echo "</tls-crypt>"
                ;;
            2)
                echo "key-direction 1"
                echo "<tls-auth>"
                cat "$OPENVPN_ROOT/tls-auth.key"
                echo "</tls-auth>"
                ;;
            esac
        } >>"$homeDir/$CLIENT.ovpn"

        echo "Configuration restored: $homeDir/$CLIENT.ovpn"
    done
}

function removeUnbound() {
	# Remove OpenVPN-related config
	sed -i '/include: \/etc\/unbound\/openvpn.conf/d' $UNBOUND_CONF
	rm $UNBOUND_OPENVPN_CONF

	until [[ $REMOVE_UNBOUND =~ (y|n) ]]; do
		echo ""
		echo "If you were already using Unbound before installing OpenVPN, I removed the configuration related to OpenVPN."
		read -rp "Do you want to completely remove Unbound? [y/n]: " -e REMOVE_UNBOUND
	done

	if [[ $REMOVE_UNBOUND == 'y' ]]; then
		# Stop Unbound
		systemctl stop unbound

		if [[ $OS =~ (debian|ubuntu) ]]; then
			apt-get remove --purge -y unbound
		elif [[ $OS == 'arch' ]]; then
			pacman --noconfirm -R unbound
		elif [[ $OS =~ (centos|amzn|oracle) ]]; then
			yum remove -y unbound
		elif [[ $OS == 'fedora' ]]; then
			dnf remove -y unbound
		fi

		rm -rf "$UNBOUND_ROOT/"

		echo ""
		echo "Unbound removed!"
	else
		systemctl restart unbound
		echo ""
		echo "Unbound wasn't removed."
	fi
}

function backupOpenvpn() {
    local backup_dir="/var/backups/openvpn"
    local final_archive="$backup_dir/openvpn-backup-$(date +%F_%H-%M-%S).tar.gz"
    local tmp_dir
    mkdir -p "$backup_dir"
    tmp_dir=$(mktemp -d)

    rsync -a --exclude='easy-rsa' $OPENVPN_ROOT "$tmp_dir/etc/"
    [[ -d $EASYRSA_PKI ]] && mkdir -p "$tmp_dir$EASYRSA_ROOT" && cp -a $EASYRSA_PKI "$tmp_dir$EASYRSA_ROOT/"

    tar -czf $final_archive -C $tmp_dir etc
    rm -rf $tmp_dir
    echo "Backup created: $final_archive"
}

function detect_dns_choice() {
	local ipset="${DNS_IPS[*]}"

	if [[ "$ipset" == *"10.8.0.1"* ]]; then
		echo 2
	elif [[ "$ipset" == *"fd42:42:42:42::1"* ]]; then
		echo 2
	elif [[ "$ipset" == *"1.0.0.1"* && "$ipset" == *"1.1.1.1"* ]]; then
		echo 3
	elif [[ "$ipset" == *"9.9.9.9"* && "$ipset" == *"149.112.112.112"* ]]; then
		echo 4
	elif [[ "$ipset" == *"9.9.9.10"* && "$ipset" == *"149.112.112.10"* ]]; then
		echo 5
	elif [[ "$ipset" == *"80.67.169.40"* && "$ipset" == *"80.67.169.12"* ]]; then
		echo 6
	elif [[ "$ipset" == *"84.200.69.80"* && "$ipset" == *"84.200.70.40"* ]]; then
		echo 7
	elif [[ "$ipset" == *"208.67.222.222"* && "$ipset" == *"208.67.220.220"* ]]; then
		echo 8
	elif [[ "$ipset" == *"8.8.8.8"* && "$ipset" == *"8.8.4.4"* ]]; then
		echo 9
	elif [[ "$ipset" == *"77.88.8.8"* && "$ipset" == *"77.88.8.1"* ]]; then
		echo 10
	elif [[ "$ipset" == *"94.140.14.14"* && "$ipset" == *"94.140.15.15"* ]]; then
		echo 11
	elif [[ "$ipset" == *"45.90.28.167"* && "$ipset" == *"45.90.30.167"* ]]; then
		echo 12
	else
		echo 13 # custom
	fi
}

function reverseConfig() {

    # IPv6
    if grep -q '^server-ipv6' "$TMP_DIR$SERVER_CONF"; then
        IPV6_SUPPORT="y"
    else
        IPV6_SUPPORT="n"
    fi

	# Port
	PORT=$(grep -m1 '^port ' "$TMP_DIR$SERVER_CONF" | awk '{print $2}')
	if [[ "$PORT" == "1194" ]]; then
		PORT_CHOICE=1
	else
		PORT_CHOICE=2
	fi

    # Protocol
	PROTOCOL=$(grep -m1 '^proto ' "$TMP_DIR$SERVER_CONF" | awk '{print $2}')
	if [[ "$PROTOCOL" =~ udp ]]; then
		PROTOCOL="udp"
		PROTOCOL_CHOICE=1
	else
		PROTOCOL="tcp"
		PROTOCOL_CHOICE=2
	fi

    # Endpoint
    ENDPOINT_FROM_BACKUP=$(grep -m1 '^remote ' "$TMP_DIR$CLIENT_TEMPLATE" | awk '{print $2}')

    # DNS detection
    DNS_IPS=($(grep 'push "dhcp-option DNS ' "$TMP_DIR$SERVER_CONF" | sed -E 's/.*DNS ([^"]+)".*/\1/'))

    DNS=$(detect_dns_choice)
    if [[ $DNS -eq 13 ]]; then
        DNS1="${DNS_IPS[0]}"
        DNS2="${DNS_IPS[1]}"
    fi

	# Initialize ENDPOINT from environment or backup if not set
	ENDPOINT="${ENDPOINT:-$ENDPOINT_FROM_BACKUP}"

	if [[ "$ENDPOINT" != "$ENDPOINT_FROM_BACKUP" ]]; then
		echo "Server endpoint has changed — configuration and rules need to be updated."
		NEED_MIGRATION="1"
	else
		NEED_MIGRATION="2"
		# Structured output for automation (key=value pairs)
		echo "IPV6_SUPPORT=$IPV6_SUPPORT"
		echo "PORT=$PORT"
		echo "PORT_CHOICE=$PORT_CHOICE"
		echo "PROTOCOL=$PROTOCOL"
		echo "PROTOCOL_CHOICE=$PROTOCOL_CHOICE"
		echo "ENDPOINT_FROM_BACKUP=$ENDPOINT_FROM_BACKUP"
		echo "ENDPOINT=$ENDPOINT"
		echo "DNS=$DNS"
		if [[ $DNS -eq 13 ]]; then
			echo "DNS1=$DNS1"
			echo "DNS2=$DNS2"
		fi
		echo "NEED_MIGRATION=$NEED_MIGRATION"
	fi
}

function restoreOpenvpn() {
	echo "Choose restore mode:"
	echo "   1) Clean install with backup config"
	echo "   2) Restore files on existing system"
	until [[ $RESTORE_MODE =~ ^[1-2]$ ]]; do
		read -rp "Mode [1-2]: " RESTORE_MODE
	done

	read -e -p "Specify path to backup file (.tar.gz): " RESTORE_FILE
	if [[ ! -f $RESTORE_FILE ]]; then
		echo "File not found!"
		return 1
	fi

	TMP_DIR=$(mktemp -d)
	tar -xzf $RESTORE_FILE -C $TMP_DIR
	if [[ $? -ne 0 ]]; then
		echo "Error extracting backup."
		rm -rf $TMP_DIR
		return 1
	fi

	BACKUP_SERVER_CONF="$TMP_DIR$OPENVPN_ROOT/server.conf"
	if [[ ! -f "$BACKUP_SERVER_CONF" ]]; then
		echo "[!] File server.conf not found in backup. Cannot proceed with restore."
		rm -rf $TMP_DIR
		return 1
	fi

	if [[ $RESTORE_MODE == "1" ]]; then
		# Clean install: install packages, restore config
		echo "[*] Performing clean install restore..."
		initializeVariables
		reverseConfig
		if [[ $NEED_MIGRATION == "1" ]]; then
			askServerIP
			askIPv6
			askPort
			askProtocol
			askDNS
		fi
		detectNetworkInterface
		installOpenVPNPackages
		detectNoGroup
		mkdir -p $OPENVPN_ROOT
		cp -a "$TMP_DIR$OPENVPN_ROOT/." "$OPENVPN_ROOT/"
		updateServerConfigHead
		installEasyRSA
		prepareSystem
		configureAndStartService
		[[ $DNS == 2 ]] && installUnbound
		setupIptablesAndService
		updateClientTemplateHead
	else
		# Restore files on existing system
		BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
		tar -czf "/root/openvpn_before_restore_$BACKUP_DATE.tar.gz" $OPENVPN_ROOT 2>/dev/null
		echo "Backup created: /root/openvpn_before_restore_$BACKUP_DATE.tar.gz"
		cp -a "$TMP_DIR$OPENVPN_ROOT/." "$OPENVPN_ROOT/"
		if [[ ! -x "$EASYRSA_ROOT/easyrsa" || ! -d $EASYRSA_PKI || ! -s "$EASYRSA_ROOT/easyrsa" ]]; then
			echo "[*] Easy-RSA not found, not executable, or damaged in target directory. Installing fresh copy..."
			installEasyRSA
			if [[ $? -ne 0 ]]; then
				echo "[!] Error downloading Easy-RSA"
				rm -rf $TMP_DIR
				return 1
			fi
		fi
		PORT=$(grep -E '^port ' $BACKUP_SERVER_CONF | awk '{print $2}')
		PROTO=$(grep -E '^proto ' $BACKUP_SERVER_CONF | awk '{print $2}')
		echo "[*] Checking iptables rules..."
		if ! iptables -C INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT 2>/dev/null; then
			iptables -I INPUT -p "$PROTO" --dport "$PORT" -j ACCEPT
			iptables-save > "$IPTABLES_ROOT/rules.v4"
			echo "[+] Added rule for port $PORT/$PROTO."
		else
			echo "[*] Rule for port $PORT/$PROTO already exists."
		fi
	fi

	rm -rf $TMP_DIR
	restartOrReloadServices
	echo "Restore complete. Verify service status and logs."
	echo "If something went wrong, you can rollback using the backup created before restore:"
	if [[ $RESTORE_MODE == "1" ]]; then
		echo "Rollback: tar -xzf /var/backups/openvpn/openvpn-backup-*.tar.gz -C /"
	elif [[ $RESTORE_MODE == "2" ]]; then
		echo "Rollback: tar -xzf /root/openvpn_before_restore_$BACKUP_DATE.tar.gz -C /"
	fi
	return 0
}

function removeOpenVPN() {
    echo ""
    read -rp "Do you really want to remove OpenVPN? [y/n]: " -e -i n REMOVE
    if [[ $REMOVE == 'y' ]]; then
        # Get OpenVPN port from the configuration
        PORT=$(grep '^port ' $SERVER_CONF | cut -d " " -f 2)
        PROTOCOL=$(grep '^proto ' $SERVER_CONF | cut -d " " -f 2)

        # Stop OpenVPN
        if [[ $OS =~ (fedora|arch|centos|oracle) ]]; then
            systemctl disable openvpn-server@server
            systemctl stop openvpn-server@server
            # Remove customised service
            rm /etc/systemd/system/openvpn-server@.service
            elif [[ $OS == "ubuntu" ]] && [[ $VERSION_ID == "16.04" ]]; then
            systemctl disable openvpn
            systemctl stop openvpn
        else
            systemctl disable openvpn@server
            systemctl stop openvpn@server
            # Remove customised service
            rm /etc/systemd/system/openvpn\@.service
        fi

        # Remove the iptables rules related to the script
        systemctl stop iptables-openvpn
        # Cleanup
        systemctl disable iptables-openvpn
        rm /etc/systemd/system/iptables-openvpn.service
        systemctl daemon-reload
        rm $ADD_OPENVPN_RULES
        rm $RM_OPENVPN_RULES

        # SELinux
        if hash sestatus 2>/dev/null; then
            if sestatus | grep "Current mode" | grep -qs "enforcing"; then
                if [[ $PORT != '1194' ]]; then
                    semanage port -d -t openvpn_port_t -p "$PROTOCOL" "$PORT"
                fi
            fi
        fi

        if [[ $OS =~ (debian|ubuntu) ]]; then
            apt-get remove --purge -y openvpn
            if [[ -e /etc/apt/sources.list.d/openvpn.list ]]; then
                rm /etc/apt/sources.list.d/openvpn.list
                apt-get update
            fi
            elif [[ $OS == 'arch' ]]; then
            pacman --noconfirm -R openvpn
            elif [[ $OS =~ (centos|amzn|oracle) ]]; then
            yum remove -y openvpn
            elif [[ $OS == 'fedora' ]]; then
            dnf remove -y openvpn
        fi

        # Cleanup
        find /home/ -maxdepth 2 -name "*.ovpn" -delete
        find /root/ -maxdepth 1 -name "*.ovpn" -delete
        rm -rf $OPENVPN_ROOT
        rm -rf /usr/share/doc/openvpn*
        rm -f /etc/sysctl.d/99-openvpn.conf
        rm -rf /var/log/openvpn

        # Unbound
        if [[ -e $UNBOUND_OPENVPN_CONF ]]; then
            removeUnbound
        fi
        echo ""
        echo "OpenVPN removed!"
    else
        echo ""
        echo "Removal aborted!"
    fi
}

function activeConnections() {
    tail /var/log/openvpn/status.log -f
}

function manageMenu() {
    echo "Welcome to OpenVPN-install!"
    echo "The git repository is available at: https://github.com/angristan/openvpn-install"
    echo ""
    echo "It looks like OpenVPN is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new user"
    echo "   2) Revoke existing user"
    echo "   3) Restore user configuration"
    echo "   4) Active connections"
    echo "   5) Run speedtest"
    echo "   6) Backup OpenVPN"
    echo "   7) Restore OpenVPN"
    echo "   8) Restart OpenVPN"
    echo "   9) Remove OpenVPN"
    echo "   10) Exit"
    until [[ $MENU_OPTION =~ ^[0-9]+$ ]]; do
        read -rp "Select an option [1-10]: " MENU_OPTION
    done

    case $MENU_OPTION in
        1) newClient ;;
        2) revokeClient ;;
        3) restoreClientConfig ;;
        4) activeConnections ;;
        5) runSpeedtest ;;
        6) backupOpenvpn ;;
        7) restoreOpenvpn ;;
        8) restartOrReloadServices ;;
        9) removeOpenVPN ;;
        10) exit 0 ;;
    esac
}

function startUpMenu() {

    if [[ -e $SERVER_CONF && $AUTO_INSTALL != "y" ]]; then
        installOpenVPN
    else
        echo "Welcome to OpenVPN-install!"
        echo "The git repository is available at: https://github.com/angristan/openvpn-install"
        echo ""
        echo "It looks like OpenVPN is already installed."
        echo ""
        echo "What do you want to do?"
        echo "   1) Install OpenVPN"
        echo "   2) Restore OpenVPN"
        echo "   3) Exit"
        until [[ $MENU_OPTION =~ ^[1-3]$ ]]; do
            read -rp "Select an option [1-3]: " MENU_OPTION
        done

        case $MENU_OPTION in
            1) installOpenVPN ;;
            2) restoreOpenvpn ;;
            3) exit 0 ;;
        esac
    fi
}

# Check for root, TUN, OS...
initialCheck

# Check if OpenVPN is already installed
if [[ -e $SERVER_CONF && $AUTO_INSTALL != "y" ]]; then
    manageMenu
else
    startUpMenu
fi
