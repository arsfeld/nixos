#!/usr/bin/env python3
"""
Enhanced VPN Manager for NixOS Router
Manages commercial VPN services (Mullvad, ProtonVPN, etc.) and per-client routing
"""

import json
import subprocess
import re
import os
import tempfile
import base64
import configparser
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple
import streamlit as st
import pandas as pd


class VPNProviderManager:
    """Manage commercial VPN provider configurations"""
    
    @staticmethod
    def parse_wireguard_config(config_content: str) -> Dict:
        """Parse a WireGuard configuration file content"""
        config = configparser.ConfigParser()
        config.read_string(config_content)
        
        result = {}
        
        # Parse Interface section
        if 'Interface' in config:
            result['interface'] = dict(config['Interface'])
        
        # Parse Peer section
        if 'Peer' in config:
            result['peer'] = dict(config['Peer'])
        
        return result
    
    @staticmethod
    def apply_wireguard_config(interface_name: str, config: Dict) -> bool:
        """Apply a parsed WireGuard configuration to an interface"""
        try:
            # Remove existing interface if it exists
            subprocess.run(['ip', 'link', 'delete', interface_name], 
                         capture_output=True, stderr=subprocess.DEVNULL)
            
            # Create new interface
            subprocess.run(['ip', 'link', 'add', 'dev', interface_name, 'type', 'wireguard'], 
                         check=True)
            
            # Set private key
            if 'interface' in config and 'privatekey' in config['interface']:
                with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
                    f.write(config['interface']['privatekey'])
                    keyfile = f.name
                
                subprocess.run(['wg', 'set', interface_name, 'private-key', keyfile], check=True)
                os.unlink(keyfile)
            
            # Set address
            if 'interface' in config and 'address' in config['interface']:
                addresses = config['interface']['address'].split(',')
                for addr in addresses:
                    subprocess.run(['ip', 'address', 'add', addr.strip(), 'dev', interface_name], 
                                 check=True)
            
            # Set DNS (optional - for information only)
            if 'interface' in config and 'dns' in config['interface']:
                st.info(f"DNS servers configured: {config['interface']['dns']}")
            
            # Add peer
            if 'peer' in config:
                peer = config['peer']
                cmd = ['wg', 'set', interface_name, 'peer', peer['publickey']]
                
                if 'allowedips' in peer:
                    cmd.extend(['allowed-ips', peer['allowedips']])
                
                if 'endpoint' in peer:
                    cmd.extend(['endpoint', peer['endpoint']])
                
                if 'presharedkey' in peer:
                    with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
                        f.write(peer['presharedkey'])
                        psk_file = f.name
                    cmd.extend(['preshared-key', psk_file])
                    subprocess.run(cmd, check=True)
                    os.unlink(psk_file)
                else:
                    subprocess.run(cmd, check=True)
            
            # Bring up interface
            subprocess.run(['ip', 'link', 'set', 'up', 'dev', interface_name], check=True)
            
            # Add routing if needed
            if 'peer' in config and 'allowedips' in config['peer']:
                if config['peer']['allowedips'] == '0.0.0.0/0, ::/0':
                    # Route all traffic through VPN
                    subprocess.run(['ip', 'route', 'add', 'default', 'dev', interface_name, 
                                  'table', '100'], capture_output=True)
                    subprocess.run(['ip', 'rule', 'add', 'fwmark', '0x100', 'table', '100'], 
                                  capture_output=True)
            
            return True
            
        except Exception as e:
            st.error(f"Failed to apply configuration: {e}")
            return False
    
    @staticmethod
    def get_interfaces() -> List[str]:
        """Get list of WireGuard interfaces"""
        try:
            result = subprocess.run(['wg', 'show', 'interfaces'], 
                                  capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip().split()
            return []
        except:
            return []
    
    @staticmethod
    def get_interface_status(interface: str) -> Dict:
        """Get status of a WireGuard interface"""
        try:
            # Check if interface exists
            link_result = subprocess.run(['ip', 'link', 'show', interface],
                                        capture_output=True, text=True)
            is_up = 'state UP' in link_result.stdout
            
            # Get WireGuard details
            wg_result = subprocess.run(['wg', 'show', interface],
                                      capture_output=True, text=True)
            
            peers = []
            current_peer = None
            
            for line in wg_result.stdout.split('\n'):
                if line.startswith('peer:'):
                    if current_peer:
                        peers.append(current_peer)
                    current_peer = {'public_key': line.split('peer:')[1].strip()}
                elif current_peer and 'endpoint:' in line:
                    current_peer['endpoint'] = line.split('endpoint:')[1].strip()
                elif current_peer and 'latest handshake:' in line:
                    current_peer['handshake'] = line.split('latest handshake:')[1].strip()
                elif current_peer and 'transfer:' in line:
                    current_peer['transfer'] = line.split('transfer:')[1].strip()
            
            if current_peer:
                peers.append(current_peer)
            
            return {
                'exists': True,
                'up': is_up,
                'peers': peers,
                'peer_count': len(peers)
            }
        except Exception as e:
            return {'exists': False, 'up': False, 'peers': [], 'error': str(e)}
    
    @staticmethod
    def stop_interface(interface: str) -> bool:
        """Stop and remove a WireGuard interface"""
        try:
            subprocess.run(['ip', 'link', 'set', 'down', 'dev', interface], check=True)
            subprocess.run(['ip', 'link', 'delete', interface], check=True)
            return True
        except Exception as e:
            st.error(f"Failed to stop interface: {e}")
            return False


class ClientDiscovery:
    """Discover network clients from ARP table and DHCP leases"""
    
    @staticmethod
    def get_arp_entries() -> List[Dict]:
        """Parse ARP table to get connected clients"""
        try:
            result = subprocess.run(['ip', 'neigh'], capture_output=True, text=True)
            clients = []
            
            for line in result.stdout.strip().split('\n'):
                match = re.match(r'(\S+)\s+dev\s+(\S+)\s+lladdr\s+(\S+)\s+(\S+)', line)
                if match:
                    ip, interface, mac, state = match.groups()
                    if interface in ['br-lan', 'eth0', 'lan']:
                        clients.append({
                            'ip': ip,
                            'mac': mac.upper(),
                            'interface': interface,
                            'online': state in ['REACHABLE', 'STALE', 'DELAY', 'PROBE']
                        })
            
            return clients
        except Exception as e:
            st.error(f"Failed to get ARP entries: {e}")
            return []
    
    @staticmethod
    def get_dhcp_leases() -> Dict[str, str]:
        """Parse DHCP leases to get hostnames"""
        hostname_map = {}
        
        # Try dnsmasq leases
        dnsmasq_lease = Path('/var/lib/misc/dnsmasq.leases')
        if dnsmasq_lease.exists():
            try:
                with open(dnsmasq_lease) as f:
                    for line in f:
                        parts = line.strip().split()
                        if len(parts) >= 4:
                            mac = parts[1].upper()
                            hostname = parts[3] if parts[3] != '*' else ''
                            if hostname:
                                hostname_map[mac] = hostname
            except Exception as e:
                st.warning(f"Failed to read dnsmasq leases: {e}")
        
        # Try Kea leases
        kea_lease = Path('/var/lib/kea/kea-leases4.csv')
        if kea_lease.exists():
            try:
                df = pd.read_csv(kea_lease)
                for _, row in df.iterrows():
                    if 'hwaddr' in row and 'hostname' in row:
                        mac = row['hwaddr'].upper()
                        hostname = row['hostname']
                        if pd.notna(hostname):
                            hostname_map[mac] = hostname
            except Exception as e:
                st.warning(f"Failed to read Kea leases: {e}")
        
        return hostname_map


class VPNState:
    """Manage VPN state persistence"""
    
    def __init__(self, state_file: Path = Path('/var/lib/vpn-manager/state.json')):
        self.state_file = state_file
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.load()
    
    def load(self):
        """Load state from JSON file"""
        if self.state_file.exists():
            try:
                with open(self.state_file) as f:
                    self.data = json.load(f)
            except:
                self.data = {'clients': {}, 'vpn_configs': {}}
        else:
            self.data = {'clients': {}, 'vpn_configs': {}}
    
    def save(self):
        """Save state to JSON file"""
        with open(self.state_file, 'w') as f:
            json.dump(self.data, f, indent=2)
    
    def get_client_vpn_status(self, mac: str) -> bool:
        """Get VPN status for a client"""
        return self.data['clients'].get(mac, {}).get('vpn_enabled', False)
    
    def set_client_vpn_status(self, mac: str, enabled: bool):
        """Set VPN status for a client"""
        if mac not in self.data['clients']:
            self.data['clients'][mac] = {}
        self.data['clients'][mac]['vpn_enabled'] = enabled
        self.data['clients'][mac]['updated_at'] = datetime.now().isoformat()
        self.save()
    
    def get_client_name(self, mac: str) -> Optional[str]:
        """Get custom name for a client"""
        return self.data['clients'].get(mac, {}).get('name')
    
    def set_client_name(self, mac: str, name: str):
        """Set custom name for a client"""
        if mac not in self.data['clients']:
            self.data['clients'][mac] = {}
        self.data['clients'][mac]['name'] = name
        self.save()
    
    def get_vpn_config(self, name: str) -> Optional[Dict]:
        """Get VPN configuration"""
        return self.data.get('vpn_configs', {}).get(name)
    
    def set_vpn_config(self, name: str, config: Dict):
        """Save VPN configuration"""
        if 'vpn_configs' not in self.data:
            self.data['vpn_configs'] = {}
        self.data['vpn_configs'][name] = config
        self.save()


class NFTManager:
    """Generate and apply nftables rules for VPN routing"""
    
    @staticmethod
    def generate_rules(vpn_clients: List[str], vpn_interface: str = 'wg0') -> str:
        """Generate nftables rules for VPN clients"""
        if not vpn_clients:
            return ""
        
        rules = []
        rules.append("#!/usr/sbin/nft -f")
        rules.append("")
        rules.append("# VPN Client Routing Rules")
        rules.append("# Generated by VPN Manager")
        rules.append("")
        rules.append("table ip vpn_manager {")
        rules.append("    chain prerouting {")
        rules.append("        type filter hook prerouting priority mangle;")
        rules.append("")
        
        # Mark packets from VPN clients
        for i, client_ip in enumerate(vpn_clients, start=100):
            rules.append(f"        ip saddr {client_ip} meta mark set 0x{i:02x}")
        
        rules.append("    }")
        rules.append("")
        rules.append("    chain postrouting {")
        rules.append("        type nat hook postrouting priority srcnat;")
        rules.append("")
        
        # NAT through VPN interface
        for i in range(100, 100 + len(vpn_clients)):
            rules.append(f"        meta mark 0x{i:02x} oifname \"{vpn_interface}\" masquerade")
        
        rules.append("    }")
        rules.append("}")
        
        return "\n".join(rules)
    
    @staticmethod
    def apply_rules(rules: str):
        """Apply nftables rules"""
        try:
            rules_file = Path('/tmp/vpn-manager-rules.nft')
            with open(rules_file, 'w') as f:
                f.write(rules)
            
            result = subprocess.run(['nft', '-f', str(rules_file)], 
                                  capture_output=True, text=True)
            if result.returncode != 0:
                st.error(f"Failed to apply NFT rules: {result.stderr}")
            else:
                st.success("NFT rules applied successfully")
        except Exception as e:
            st.error(f"Failed to apply NFT rules: {e}")


def main():
    st.set_page_config(
        page_title="VPN Manager",
        page_icon="🔒",
        layout="wide"
    )
    
    st.title("🔒 Router VPN Manager")
    st.markdown("Configure commercial VPN providers and manage per-client routing")
    
    # Initialize components
    discovery = ClientDiscovery()
    state = VPNState()
    nft = NFTManager()
    vpn = VPNProviderManager()
    
    # Create tabs
    tab1, tab2, tab3 = st.tabs(["VPN Configuration", "Client Routing", "Active Connections"])
    
    with tab1:
        st.header("Commercial VPN Provider Setup")
        
        # Get current interfaces
        interfaces = vpn.get_interfaces()
        
        col1, col2 = st.columns([2, 1])
        
        with col1:
            interface_name = st.text_input("Interface Name", value="wg0",
                                         help="Name for the VPN interface (e.g., wg0, mullvad, proton)")
        
        with col2:
            if st.button("🔄 Refresh Status"):
                st.rerun()
        
        # Check if interface exists
        if interface_name in interfaces:
            status = vpn.get_interface_status(interface_name)
            
            col1, col2, col3 = st.columns(3)
            with col1:
                if status['up']:
                    st.success(f"✅ {interface_name} is UP")
                else:
                    st.error(f"❌ {interface_name} is DOWN")
            with col2:
                if status['peers']:
                    st.metric("VPN Server", status['peers'][0].get('endpoint', 'N/A').split(':')[0])
                else:
                    st.metric("VPN Server", "Not connected")
            with col3:
                if st.button("🛑 Disconnect VPN", type="secondary"):
                    if vpn.stop_interface(interface_name):
                        st.success("VPN disconnected")
                        st.rerun()
        
        st.divider()
        
        # VPN Provider Selection
        st.subheader("Setup Commercial VPN")
        
        st.info("""
        **How to get WireGuard configuration files:**
        - **Mullvad**: Login to mullvad.net → WireGuard configuration → Download
        - **ProtonVPN**: Login to account.protonvpn.com → Downloads → WireGuard configuration
        - **PIA**: Login to privateinternetaccess.com → Download WireGuard configs
        - **NordVPN**: Use NordVPN app to generate WireGuard credentials
        - **Custom**: Use any standard WireGuard .conf file
        """)
        
        # Configuration input methods
        config_method = st.radio("Configuration Method", 
                                ["Upload .conf file", "Paste configuration"])
        
        config_content = None
        
        if config_method == "Upload .conf file":
            uploaded_file = st.file_uploader("Upload WireGuard Configuration", 
                                            type=['conf', 'txt'],
                                            help="Upload your provider's WireGuard .conf file")
            if uploaded_file:
                config_content = uploaded_file.read().decode('utf-8')
                st.success(f"Loaded configuration: {uploaded_file.name}")
        
        else:  # Paste configuration
            config_content = st.text_area("Paste WireGuard Configuration", 
                                         height=300,
                                         placeholder="""[Interface]
PrivateKey = your_private_key_here
Address = 10.x.x.x/32
DNS = x.x.x.x

[Peer]
PublicKey = server_public_key_here
Endpoint = server.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0""")
        
        # Parse and apply configuration
        if config_content and st.button("🚀 Connect to VPN", type="primary"):
            # Parse the configuration
            parsed_config = vpn.parse_wireguard_config(config_content)
            
            if parsed_config:
                # Show parsed configuration
                with st.expander("Configuration Details", expanded=True):
                    if 'interface' in parsed_config:
                        st.write("**Interface Settings:**")
                        for key, value in parsed_config['interface'].items():
                            if key.lower() != 'privatekey':
                                st.text(f"  {key}: {value}")
                            else:
                                st.text(f"  {key}: [hidden]")
                    
                    if 'peer' in parsed_config:
                        st.write("**VPN Server:**")
                        for key, value in parsed_config['peer'].items():
                            if key.lower() not in ['privatekey', 'presharedkey']:
                                st.text(f"  {key}: {value}")
                
                # Apply configuration
                if vpn.apply_wireguard_config(interface_name, parsed_config):
                    st.success(f"✅ Connected to VPN on interface {interface_name}")
                    
                    # Save configuration for future use
                    state.set_vpn_config(interface_name, {
                        'configured_at': datetime.now().isoformat(),
                        'server': parsed_config.get('peer', {}).get('endpoint', 'Unknown')
                    })
                    
                    st.rerun()
                else:
                    st.error("Failed to connect to VPN. Check the configuration and try again.")
            else:
                st.error("Failed to parse configuration. Please check the format.")
        
        # Show saved configurations
        if st.checkbox("Show saved VPN configurations"):
            saved_configs = state.data.get('vpn_configs', {})
            if saved_configs:
                for name, config in saved_configs.items():
                    st.text(f"{name}: {config.get('server', 'N/A')} - Configured: {config.get('configured_at', 'Unknown')}")
    
    with tab2:
        st.header("📱 Client Routing")
        
        # Get current clients
        arp_clients = discovery.get_arp_entries()
        dhcp_hostnames = discovery.get_dhcp_leases()
        
        # Get VPN interface to use
        vpn_interfaces = vpn.get_interfaces()
        if vpn_interfaces:
            vpn_interface = st.selectbox("Route through VPN interface:", vpn_interfaces)
        else:
            st.warning("No VPN interfaces configured. Please configure a VPN connection first in the VPN Configuration tab.")
            vpn_interface = "wg0"
        
        # Build client list
        clients_data = []
        for client in arp_clients:
            mac = client['mac']
            hostname = dhcp_hostnames.get(mac, '')
            custom_name = state.get_client_name(mac)
            display_name = custom_name or hostname or 'Unknown'
            
            clients_data.append({
                'Name': display_name,
                'IP': client['ip'],
                'MAC': mac,
                'Status': '🟢' if client['online'] else '🔴',
                'VPN': state.get_client_vpn_status(mac),
                'mac_raw': mac
            })
        
        if not clients_data:
            st.warning("No clients found. Make sure you have proper permissions to read ARP table.")
        else:
            # Display clients in a table
            col1, col2, col3, col4, col5, col6 = st.columns([3, 2, 3, 1, 1, 2])
            with col1:
                st.markdown("**Name**")
            with col2:
                st.markdown("**IP Address**")
            with col3:
                st.markdown("**MAC Address**")
            with col4:
                st.markdown("**Status**")
            with col5:
                st.markdown("**VPN**")
            with col6:
                st.markdown("**Actions**")
            
            st.divider()
            
            # Track VPN-enabled clients
            vpn_enabled_ips = []
            
            # Display each client
            for idx, client in enumerate(clients_data):
                col1, col2, col3, col4, col5, col6 = st.columns([3, 2, 3, 1, 1, 2])
                
                unique_key = f"{client['mac_raw']}_{client['IP']}_{idx}"
                
                with col1:
                    new_name = st.text_input("Name", value=client['Name'], 
                                            key=f"name_{unique_key}", 
                                            label_visibility="collapsed")
                    if new_name != client['Name']:
                        state.set_client_name(client['mac_raw'], new_name)
                
                with col2:
                    st.text(client['IP'])
                
                with col3:
                    st.code(client['MAC'], language=None)
                
                with col4:
                    st.text(client['Status'])
                
                with col5:
                    vpn_enabled = st.toggle("VPN", value=client['VPN'], 
                                           key=f"vpn_{unique_key}", 
                                           label_visibility="collapsed")
                    if vpn_enabled != client['VPN']:
                        state.set_client_vpn_status(client['mac_raw'], vpn_enabled)
                        st.rerun()
                    
                    if vpn_enabled:
                        vpn_enabled_ips.append(client['IP'])
                
                with col6:
                    if st.button("ℹ️ Info", key=f"info_{unique_key}"):
                        st.info(f"MAC: {client['MAC']}\nIP: {client['IP']}")
            
            st.divider()
            
            # Statistics
            col1, col2, col3 = st.columns(3)
            with col1:
                st.metric("Total Clients", len(clients_data))
            with col2:
                online_count = sum(1 for c in clients_data if c['Status'] == '🟢')
                st.metric("Online", online_count)
            with col3:
                vpn_count = sum(1 for c in clients_data if c['VPN'])
                st.metric("VPN Enabled", vpn_count)
            
            # Apply NFT rules button
            if st.button("🔧 Apply VPN Routing Rules", type="primary"):
                if vpn_enabled_ips:
                    rules = nft.generate_rules(vpn_enabled_ips, vpn_interface)
                    st.code(rules, language="bash")
                    
                    if st.checkbox("Confirm apply rules"):
                        nft.apply_rules(rules)
                else:
                    st.info("No clients have VPN enabled")
    
    with tab3:
        st.header("Active VPN Connections")
        
        # Show all WireGuard interfaces and their connections
        interfaces = vpn.get_interfaces()
        
        if not interfaces:
            st.info("No active VPN connections")
        else:
            for interface in interfaces:
                status = vpn.get_interface_status(interface)
                
                with st.expander(f"Interface: {interface}", expanded=True):
                    if status['up']:
                        st.success(f"✅ Interface is UP")
                    else:
                        st.warning(f"⚠️ Interface is DOWN")
                    
                    if status['peers']:
                        st.subheader("Connected Peers")
                        
                        peer_data = []
                        for peer in status['peers']:
                            handshake = peer.get('handshake', 'Never')
                            if handshake != 'Never':
                                # Parse handshake time to determine if active
                                if 'minute' in handshake or 'second' in handshake:
                                    status_icon = '🟢'
                                else:
                                    status_icon = '🟡'
                            else:
                                status_icon = '🔴'
                            
                            peer_data.append({
                                'Status': status_icon,
                                'Public Key': peer['public_key'][:24] + '...',
                                'Endpoint': peer.get('endpoint', 'N/A'),
                                'Last Handshake': handshake,
                                'Data Transfer': peer.get('transfer', 'N/A')
                            })
                        
                        df = pd.DataFrame(peer_data)
                        st.dataframe(df, use_container_width=True, hide_index=True)
                    else:
                        st.info("No peers connected")


if __name__ == "__main__":
    main()