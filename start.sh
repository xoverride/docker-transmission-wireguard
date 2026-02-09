#! /bin/bash

# Exit on error
set -e

VETH_IP_1=${VETH_IP_1:-10.10.13.36}
VETH_IP_2=${VETH_IP_2:-10.10.13.37}

if [[ -n "$REVISION" ]]; then
  echo "Image revision: $REVISION"
fi

echo "Current public IP is:"
curl --silent -w "\n" ipecho.net/plain

if ip netns ls | grep -q "physical"
then
    # Dangling network from previous run, clean up
    echo "Clean up dangling network namespaces"
    ip netns delete physical
fi

# Grab information from the default interface set up in the container
GW=$(/sbin/ip route list match 0.0.0.0 | awk '{print $3}')
INT=$(/sbin/ip route list match 0.0.0.0 | awk '{print $5}')
INT_IP=$(ip -f inet addr show "$INT" | awk '/inet / {print $2}')
INT_BRD=$(ip -f inet addr show "$INT" | awk '/inet / {print $4}')

echo "Found default container interface, will use this in setup:"
echo "Interface: $INT"
echo "Gateway: $GW"
echo "Interface address: $INT_IP"
echo "Interface broadcast: $INT_BRD"

# Override DNS to Cloudflare unless SKIP_DNS_OVERRIDE is set to true (case insensitive)
if [ -z "${SKIP_DNS_OVERRIDE}" ] || ! [[ "${SKIP_DNS_OVERRIDE,,}" == "true" ]]; then
  echo "Overriding DNS to Cloudflare"
  echo "nameserver 1.1.1.1" > /etc/resolv.conf
else
  echo "Skipping DNS override due to SKIP_DNS_OVERRIDE=${SKIP_DNS_OVERRIDE}"
fi

echo "DNS config:"
cat /etc/resolv.conf

# Disable IPv6 in the default namespace to prevent leaks outside the VPN tunnel
sysctl -w net.ipv6.conf.all.disable_ipv6=1

# Create a "physical" network namespace and move our eth0 there
ip netns ls
ip netns add physical
ip link set eth0 netns physical

# Restore IP and route configuration for the default interface (needed for both paths)
ip -n physical addr add "$INT_IP" dev "$INT" brd "$INT_BRD"
ip -n physical link set "$INT" up
ip -n physical route add default via "$GW" dev "$INT"

# Detect kernel WireGuard support
USE_USERSPACE=false
if ! ip -n physical link add wg-test type wireguard 2>/dev/null; then
  USE_USERSPACE=true
  echo "Kernel WireGuard module not available, will use wireguard-go (userspace)"
else
  ip -n physical link delete wg-test 2>/dev/null
  echo "Kernel WireGuard module available"
fi

# Parse WireGuard config
address=$(grep -i "^[[:space:]]*Address" "$CONFIG_FILE" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]' | cut -d, -f1)
stripped_config_file=$(mktemp)
wg-quick strip "$CONFIG_FILE" > "$stripped_config_file"
echo "Will use wg config from $stripped_config_file"

setup_veth() {
  # Create a veth link pair, one interface in each namespace
  ip link add veth1 type veth peer name veth2 netns physical

  # Set their IPs, CIDR with only two addresses to limit ip route ranges
  ip addr add "${VETH_IP_1}/31" dev veth1
  ip -n physical addr add "${VETH_IP_2}/31" dev veth2

  # Start the veth interfaces
  ip link set veth1 up
  ip -n physical link set veth2 up
}

if [ "$USE_USERSPACE" = "true" ]; then
  #
  # wireguard-go (userspace) path
  #
  # Veth pair must be created BEFORE wg0 so we can route the endpoint through it
  setup_veth
  VETH_DONE=true

  # Extract the WireGuard endpoint from the config
  endpoint_line=$(grep -i "^[[:space:]]*Endpoint" "$CONFIG_FILE" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
  # Strip port — handle both IPv4:port and [IPv6]:port
  if [[ "$endpoint_line" == \[* ]]; then
    endpoint_host=$(echo "$endpoint_line" | sed 's/^\[//;s/\]:.*//')
  else
    endpoint_host=$(echo "$endpoint_line" | cut -d: -f1)
  fi

  # Resolve hostname to IP if needed (resolve from physical namespace which has internet)
  if [[ "$endpoint_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    endpoint_ip="$endpoint_host"
  else
    echo "Resolving endpoint hostname: $endpoint_host"
    endpoint_ip=$(ip netns exec physical getent ahostsv4 "$endpoint_host" | head -1 | awk '{print $1}')
    echo "Resolved to: $endpoint_ip"
  fi

  # Add a specific route for the WireGuard endpoint through the veth pair
  # This prevents a routing loop when the default route goes via wg0
  ip route add "$endpoint_ip/32" via "$VETH_IP_2" dev veth1
  echo "Added endpoint route: $endpoint_ip via $VETH_IP_2 dev veth1"

  # Enable IP forwarding in the physical namespace so it can forward WireGuard traffic
  ip netns exec physical sysctl -w net.ipv4.ip_forward=1
  # MASQUERADE so return traffic from the endpoint routes back through the veth pair
  ip netns exec physical iptables -t nat -A POSTROUTING -o "$INT" -j MASQUERADE

  # Start wireguard-go (creates TUN device wg0 in the default namespace)
  WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go wireguard-go wg0
  echo "wireguard-go started"

  # Configure wg0
  ip addr add "$address" dev wg0
  wg setconf wg0 "$stripped_config_file"
  ip link set wg0 up
  ip route add default dev wg0
else
  #
  # Kernel WireGuard path (original logic)
  #
  # Create wireguard interface in physical namespace and move it to the default namespace
  ip -n physical link add wg0 type wireguard
  ip -n physical link set wg0 netns 1

  # Configure wg0
  ip addr add "$address" dev wg0
  wg setconf wg0 "$stripped_config_file"
  ip link set wg0 up
  ip route add default dev wg0

  VETH_DONE=false
fi

#
# Wireguard interface is now set up and should be connected
#
echo "Wireguard is up - new IP:"
curl --silent -w "\n" ipecho.net/plain

# Create veth pair if not already done (kernel path)
if [ "$VETH_DONE" = "false" ]; then
  setup_veth
fi

# Generate runtime nginx config with correct veth IP and start reverse proxy
NGINX_RUNTIME_CONF=$(mktemp)
sed "s/10.10.13.36/${VETH_IP_1}/" /opt/nginx/server.conf > "$NGINX_RUNTIME_CONF"
ip netns exec physical nginx -c "$NGINX_RUNTIME_CONF"

# Make sure TRANSMISSION_HOME exists and create/update settings.json
mkdir -p "$TRANSMISSION_HOME"
python3 /opt/transmission/updateSettings.py /opt/transmission/default-settings.json "${TRANSMISSION_HOME}/settings.json" || exit 1

# Support running Transmission as non-root (and set permissions on folders)
. /opt/transmission/userSetup.sh

exec su --preserve-environment "${RUN_AS}" -s /bin/bash -c "/usr/bin/transmission-daemon --foreground -g ${TRANSMISSION_HOME}"
