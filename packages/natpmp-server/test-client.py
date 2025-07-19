#!/usr/bin/env python3
"""
Simple NAT-PMP test client for testing the server
"""

import socket
import struct
import sys
import time

NATPMP_PORT = 5351
NATPMP_VERSION = 0

OPCODE_INFO = 0
OPCODE_MAP_UDP = 1
OPCODE_MAP_TCP = 2

def send_info_request(server_addr, port=NATPMP_PORT):
    """Send an info request to get external IP"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3.0)
    
    # Build info request: version (1 byte) + opcode (1 byte)
    request = struct.pack('!BB', NATPMP_VERSION, OPCODE_INFO)
    
    try:
        sock.sendto(request, (server_addr, port))
        response, _ = sock.recvfrom(12)
        
        # Parse response
        version, opcode, result_code, epoch, ip_bytes = struct.unpack('!BBHI4s', response)
        
        if result_code == 0:
            ip = socket.inet_ntoa(ip_bytes)
            print(f"External IP: {ip}")
            print(f"Server epoch: {epoch}")
            return True
        else:
            print(f"Error: Result code {result_code}")
            return False
            
    except socket.timeout:
        print("Error: Request timed out")
        return False
    finally:
        sock.close()

def send_mapping_request(server_addr, internal_port, external_port=0, protocol='tcp', lifetime=3600, port=NATPMP_PORT):
    """Send a port mapping request"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3.0)
    
    opcode = OPCODE_MAP_TCP if protocol == 'tcp' else OPCODE_MAP_UDP
    
    # Build mapping request
    request = struct.pack('!BBHHHI', 
                         NATPMP_VERSION, 
                         opcode,
                         0,  # reserved
                         internal_port,
                         external_port,
                         lifetime)
    
    try:
        sock.sendto(request, (server_addr, port))
        response, _ = sock.recvfrom(16)
        
        # Parse response
        (version, resp_opcode, reserved, result_code, epoch, 
         int_port, ext_port, lifetime_granted) = struct.unpack('!BBHHIHHI', response)
        
        if result_code == 0:
            print(f"Mapping created:")
            print(f"  Internal port: {int_port}")
            print(f"  External port: {ext_port}")
            print(f"  Lifetime: {lifetime_granted} seconds")
            return True
        else:
            print(f"Error: Result code {result_code}")
            return False
            
    except socket.timeout:
        print("Error: Request timed out")
        return False
    finally:
        sock.close()

def main():
    if len(sys.argv) < 2:
        print("Usage: test-client.py <server-ip> [command]")
        print("Commands:")
        print("  info - Get external IP (default)")
        print("  map <internal-port> [external-port] [tcp|udp] [lifetime]")
        sys.exit(1)
    
    server = sys.argv[1]
    port = NATPMP_PORT
    
    # Check for custom port
    if ':' in server:
        server, port_str = server.split(':')
        port = int(port_str)
    
    if len(sys.argv) == 2 or sys.argv[2] == 'info':
        send_info_request(server, port)
    elif sys.argv[2] == 'map':
        if len(sys.argv) < 4:
            print("Error: map command requires internal port")
            sys.exit(1)
        
        internal_port = int(sys.argv[3])
        external_port = int(sys.argv[4]) if len(sys.argv) > 4 else 0
        protocol = sys.argv[5] if len(sys.argv) > 5 else 'tcp'
        lifetime = int(sys.argv[6]) if len(sys.argv) > 6 else 3600
        
        send_mapping_request(server, internal_port, external_port, protocol, lifetime, port)
    else:
        print(f"Unknown command: {sys.argv[2]}")
        sys.exit(1)

if __name__ == '__main__':
    main()