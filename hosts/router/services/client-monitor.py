#!/usr/bin/env python3

import json
import os
import time
import subprocess
import socket
from pathlib import Path
from typing import Dict, Set
import urllib.request
import urllib.parse

# Configuration
STATE_FILE = '/var/lib/router-client-monitor/known_clients.json'
NTFY_TOPIC = 'arsfeld-router'
NTFY_URL = f'https://ntfy.sh/{NTFY_TOPIC}'
CHECK_INTERVAL = 60  # Check every 60 seconds
COOLDOWN_PERIOD = 3600  # Don't re-notify about same client for 1 hour

class ClientMonitor:
    def __init__(self):
        self.state_dir = Path(STATE_FILE).parent
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.known_clients = self.load_state()
        self.last_notification = {}  # Track last notification time per MAC
    
    def load_state(self) -> Dict:
        """Load known clients from state file"""
        if os.path.exists(STATE_FILE):
            try:
                with open(STATE_FILE, 'r') as f:
                    return json.load(f)
            except:
                return {}
        return {}
    
    def save_state(self):
        """Save known clients to state file"""
        try:
            with open(STATE_FILE, 'w') as f:
                json.dump(self.known_clients, f, indent=2)
        except Exception as e:
            print(f"Error saving state: {e}")
    
    def get_current_clients(self) -> Dict[str, Dict]:
        """Get current clients from Kea DHCP and ARP table"""
        clients = {}
        
        # Read Kea DHCP leases
        lease_file = '/var/lib/kea/kea-leases4.csv'
        try:
            if os.path.exists(lease_file):
                with open(lease_file, 'r') as f:
                    lines = f.readlines()
                
                # Skip header if present
                if lines and lines[0].startswith('address,'):
                    lines = lines[1:]
                
                for line in lines:
                    line = line.strip()
                    if not line:
                        continue
                    
                    parts = line.split(',')
                    if len(parts) >= 10:
                        state = parts[9]
                        # Only active leases (state 0)
                        if state == '0':
                            ip = parts[0]
                            mac = parts[1].lower()
                            hostname = parts[8] if len(parts) > 8 and parts[8] else ''
                            
                            if ip and mac and mac != '00:00:00:00:00:00':
                                clients[mac] = {
                                    'ip': ip,
                                    'hostname': hostname or self.get_hostname(ip),
                                    'source': 'dhcp',
                                    'first_seen': int(time.time())
                                }
        except Exception as e:
            print(f"Error reading Kea leases: {e}")
        
        # Also check ARP table for devices not in DHCP
        try:
            result = subprocess.run(
                ['ip', 'neigh', 'show', 'dev', 'br-lan'],
                capture_output=True,
                text=True,
                timeout=5
            )
            
            if result.returncode == 0:
                for line in result.stdout.strip().split('\n'):
                    if not line:
                        continue
                    parts = line.split()
                    if len(parts) >= 5:
                        ip = parts[0]
                        # Find MAC and state
                        mac = None
                        state = None
                        for i, part in enumerate(parts):
                            if part == 'lladdr' and i + 1 < len(parts):
                                mac = parts[i + 1].lower()
                            elif part in ['REACHABLE', 'STALE', 'PERMANENT', 'DELAY', 'PROBE']:
                                state = part
                        
                        # Add if not already in DHCP and is active
                        if mac and mac not in clients and state in ['REACHABLE', 'STALE', 'PERMANENT', 'DELAY']:
                            if mac != '00:00:00:00:00:00' and not mac.startswith('ff:'):
                                clients[mac] = {
                                    'ip': ip,
                                    'hostname': self.get_hostname(ip),
                                    'source': 'arp',
                                    'first_seen': int(time.time())
                                }
        except Exception as e:
            print(f"Error reading ARP table: {e}")
        
        return clients
    
    def get_hostname(self, ip: str) -> str:
        """Try to resolve hostname for IP"""
        try:
            hostname = socket.gethostbyaddr(ip)[0]
            # Return short hostname (remove domain)
            return hostname.split('.')[0]
        except:
            return ''
    
    def get_vendor(self, mac: str) -> str:
        """Get vendor name from MAC address OUI"""
        # Simple OUI lookup - in production, use a proper OUI database
        oui = mac[:8].upper().replace(':', '')
        
        # Common vendor prefixes (simplified)
        vendors = {
            '00178': 'Apple',
            '001FF': 'Apple',
            'A4773': 'Apple',
            '00E04': 'Cisco',
            '001DD': 'Dell',
            '0017E': 'HP',
            '00508': 'Samsung',
            '5CCD5': 'Nintendo',
            '00041': 'Sony',
            'B827E': 'Raspberry Pi',
            'DC253': 'Raspberry Pi',
            '001E0': 'Intel',
            '00D86': 'Intel',
            '94103': 'Samsung',
            '00166': 'Samsung',
        }
        
        for prefix, vendor in vendors.items():
            if oui.startswith(prefix):
                return vendor
        
        return 'Unknown'
    
    def send_notification(self, title: str, message: str, priority: str = 'default', tags: str = ''):
        """Send notification via ntfy.sh"""
        try:
            data = message.encode('utf-8')
            headers = {
                'Title': title,
                'Priority': priority,
            }
            if tags:
                headers['Tags'] = tags
            
            req = urllib.request.Request(NTFY_URL, data=data, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status == 200:
                    print(f"Notification sent: {title}")
                    return True
        except Exception as e:
            print(f"Failed to send notification: {e}")
        return False
    
    def format_client_info(self, mac: str, client_info: Dict) -> str:
        """Format client information for notification"""
        hostname = client_info.get('hostname', 'Unknown')
        ip = client_info.get('ip', 'Unknown')
        vendor = self.get_vendor(mac)
        source = client_info.get('source', 'unknown').upper()
        
        msg = f"IP: {ip}\nMAC: {mac}"
        if hostname and hostname != 'Unknown':
            msg = f"Device: {hostname}\n{msg}"
        if vendor != 'Unknown':
            msg += f"\nVendor: {vendor}"
        msg += f"\nDetected via: {source}"
        
        return msg
    
    def monitor_loop(self):
        """Main monitoring loop"""
        print(f"Starting client monitor - checking every {CHECK_INTERVAL} seconds")
        print(f"Notifications will be sent to: {NTFY_URL}")
        
        # Initial scan - don't notify for existing clients
        current_clients = self.get_current_clients()
        for mac, info in current_clients.items():
            if mac not in self.known_clients:
                self.known_clients[mac] = info
                print(f"Initial client discovered: {mac} ({info.get('hostname', 'Unknown')})")
        self.save_state()
        
        while True:
            try:
                time.sleep(CHECK_INTERVAL)
                
                # Get current clients
                current_clients = self.get_current_clients()
                current_time = int(time.time())
                
                # Check for new clients
                new_clients = []
                for mac, info in current_clients.items():
                    if mac not in self.known_clients:
                        # New client detected
                        self.known_clients[mac] = info
                        new_clients.append((mac, info))
                    else:
                        # Update info for existing client
                        self.known_clients[mac].update(info)
                
                # Send notifications for new clients
                for mac, info in new_clients:
                    # Check cooldown period
                    last_notif = self.last_notification.get(mac, 0)
                    if current_time - last_notif >= COOLDOWN_PERIOD:
                        hostname = info.get('hostname', 'Unknown')
                        title = f"🆕 New device connected: {hostname if hostname != 'Unknown' else mac[:8]}"
                        message = self.format_client_info(mac, info)
                        
                        # Send notification
                        if self.send_notification(title, message, priority='default', tags='computer,new'):
                            self.last_notification[mac] = current_time
                            print(f"New client notification sent: {mac} ({hostname})")
                    else:
                        remaining = COOLDOWN_PERIOD - (current_time - last_notif)
                        print(f"New client {mac} in cooldown period ({remaining}s remaining)")
                
                # Check for disconnected clients (optional)
                disconnected = []
                for mac in list(self.known_clients.keys()):
                    if mac not in current_clients:
                        # Client disconnected - keep in known_clients but mark as offline
                        if self.known_clients[mac].get('online', True):
                            self.known_clients[mac]['online'] = False
                            self.known_clients[mac]['last_seen'] = current_time
                            disconnected.append(mac)
                    else:
                        self.known_clients[mac]['online'] = True
                
                # Optional: Send disconnect notifications for important devices
                # for mac in disconnected:
                #     info = self.known_clients[mac]
                #     hostname = info.get('hostname', 'Unknown')
                #     # Only notify for named devices
                #     if hostname != 'Unknown' and hostname != '':
                #         title = f"📵 Device disconnected: {hostname}"
                #         message = f"Device {hostname} ({mac}) has disconnected"
                #         self.send_notification(title, message, priority='low', tags='warning')
                
                # Save state
                if new_clients or disconnected:
                    self.save_state()
                
                # Print summary
                online_count = len(current_clients)
                print(f"[{time.strftime('%H:%M:%S')}] Active clients: {online_count}, New: {len(new_clients)}, Total known: {len(self.known_clients)}")
                
            except KeyboardInterrupt:
                print("\nShutting down client monitor...")
                break
            except Exception as e:
                print(f"Error in monitor loop: {e}")
                time.sleep(10)  # Wait a bit before retrying

def main():
    monitor = ClientMonitor()
    monitor.monitor_loop()

if __name__ == '__main__':
    main()