#!/usr/bin/env python3
import socket
import struct
import time
import sys

def send_natpmp_request(router_ip, opcode, internal_port=0, external_port=0, lifetime=3600):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    
    if opcode == 0:  # Get external IP
        request = struct.pack('!BB', 0, 0)  # version 0, opcode 0
    elif opcode in [1, 2]:  # Map UDP or TCP
        request = struct.pack('!BBHHHL', 
            0,  # version
            opcode,  # opcode
            0,  # reserved
            internal_port,
            external_port,
            lifetime
        )
    else:
        raise ValueError("Invalid opcode")
    
    print(f"Sending request to {router_ip}:5351")
    print(f"Request bytes: {request.hex()}")
    sock.sendto(request, (router_ip, 5351))
    
    try:
        response, addr = sock.recvfrom(1024)
        print(f"Response from {addr}: {response.hex()}")
        
        if len(response) >= 8:
            version, opcode_resp, result_code, epoch = struct.unpack('!BBHI', response[:8])
            print(f"Version: {version}, Opcode: {opcode_resp}, Result: {result_code}, Epoch: {epoch}")
            
            if opcode == 0 and len(response) >= 12:
                ip_bytes = response[8:12]
                ip = ".".join(str(b) for b in ip_bytes)
                print(f"External IP: {ip}")
            elif opcode in [1, 2] and len(response) >= 16:
                internal_port, external_port, lifetime = struct.unpack('!HHL', response[8:16])
                print(f"Mapping: Internal port {internal_port} -> External port {external_port} for {lifetime} seconds")
        
        return response
    except socket.timeout:
        print("Request timed out")
        return None

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 test-natpmp.py <router_ip> <command>")
        print("Commands:")
        print("  info - Get external IP")
        print("  map <internal_port> <external_port> <tcp|udp> [lifetime] - Create port mapping")
        sys.exit(1)
    
    router_ip = sys.argv[1]
    command = sys.argv[2]
    
    if command == "info":
        send_natpmp_request(router_ip, 0)
    elif command == "map" and len(sys.argv) >= 6:
        internal_port = int(sys.argv[3])
        external_port = int(sys.argv[4])
        protocol = sys.argv[5]
        lifetime = int(sys.argv[6]) if len(sys.argv) > 6 else 3600
        
        opcode = 1 if protocol == "udp" else 2
        send_natpmp_request(router_ip, opcode, internal_port, external_port, lifetime)
    else:
        print("Invalid command")