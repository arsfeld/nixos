#!/usr/bin/env python3

import argparse
import json
import os
import socket
import subprocess
import time
import urllib.request
import urllib.parse
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Dict, Any, Optional, List
from pathlib import Path

# Read the dashboard HTML file
DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Router Dashboard</title>
    <link href="https://cdn.lineicons.com/4.0/lineicons.css" rel="stylesheet" />
    <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #0f0f0f 0%, #1a1a1a 100%);
            color: #e0e0e0;
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 1400px;
            width: 100%;
            margin: 0 auto;
        }

        .header {
            text-align: center;
            margin-bottom: 30px;
        }
        
        .system-stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 16px;
            padding: 24px;
        }
        
        .stat-card {
            text-align: center;
            padding: 16px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.08);
        }
        
        .stat-label {
            font-size: 0.85rem;
            color: #888;
            margin-bottom: 8px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .stat-value {
            font-size: 1.8rem;
            font-weight: 600;
            background: linear-gradient(135deg, #4a9eff 0%, #00d4ff 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .stat-value.status-online {
            background: linear-gradient(135deg, #4ade80 0%, #22c55e 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .stat-value.status-offline {
            background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .stat-value.status-partial {
            background: linear-gradient(135deg, #fbbf24 0%, #f59e0b 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        
        .stat-sub {
            font-size: 0.9rem;
            color: #aaa;
            margin-top: 4px;
        }
        
        .network-info {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 40px;
        }
        
        .network-info h3 {
            font-size: 1.2rem;
            margin-bottom: 16px;
            color: #fff;
        }
        
        .network-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 16px;
        }
        
        .network-item {
            display: flex;
            justify-content: space-between;
            padding: 12px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            font-size: 0.9rem;
        }
        
        .network-label {
            color: #888;
        }
        
        .network-value {
            color: #fff;
            font-family: 'Courier New', monospace;
        }
        
        .clients-section {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 40px;
        }
        
        .dns-stats-section {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 16px;
            padding: 24px;
            margin-bottom: 40px;
        }
        
        .dns-stats-section h3 {
            font-size: 1.2rem;
            margin-bottom: 20px;
            color: #fff;
        }
        
        .dns-stats-section h4 {
            font-size: 1rem;
            margin-bottom: 12px;
            color: #bbb;
        }
        
        .dns-stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }
        
        .dns-stat-card {
            text-align: center;
            padding: 16px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.08);
        }
        
        .dns-top-section {
            display: grid;
            grid-template-columns: 1fr;
            gap: 20px;
        }
        
        .dns-top-clients {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 12px;
            padding: 16px;
        }
        
        .dns-top-list {
            display: flex;
            flex-direction: column;
            gap: 8px;
        }
        
        .dns-client-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 8px;
            background: rgba(255, 255, 255, 0.03);
            border-radius: 6px;
            font-size: 0.9rem;
        }
        
        .dns-client-name {
            color: #e0e0e0;
            flex: 1;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
        
        .dns-client-count {
            color: #4a9eff;
            font-weight: 500;
            margin-left: 12px;
        }
        
        .block-lists {
            display: flex;
            flex-wrap: wrap;
            gap: 6px;
            justify-content: center;
            margin-top: 8px;
        }
        
        .block-list-item {
            padding: 4px 8px;
            background: rgba(239, 68, 68, 0.2);
            border: 1px solid rgba(239, 68, 68, 0.3);
            border-radius: 12px;
            font-size: 0.75rem;
            color: #fca5a5;
        }
        
        .clients-section h3 {
            font-size: 1.2rem;
            margin-bottom: 20px;
            color: #fff;
        }
        
        .clients-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        
        .clients-title {
            font-size: 1.2rem;
            color: #fff;
        }
        
        .sort-controls {
            display: flex;
            gap: 8px;
        }
        
        .sort-btn {
            padding: 6px 12px;
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 6px;
            color: #888;
            font-size: 0.85rem;
            cursor: pointer;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            gap: 4px;
        }
        
        .sort-btn:hover {
            background: rgba(255, 255, 255, 0.08);
            border-color: rgba(255, 255, 255, 0.2);
            color: #fff;
        }
        
        .sort-btn.active {
            background: rgba(74, 158, 255, 0.2);
            border-color: #4a9eff;
            color: #4a9eff;
        }
        
        .sort-btn i {
            font-size: 0.7rem;
            opacity: 0.7;
        }
        
        .sort-btn.active i {
            opacity: 1;
        }
        
        .sort-btn.desc i {
            transform: rotate(180deg);
        }
        
        .clients-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 12px;
        }
        
        .client-item {
            display: flex;
            align-items: center;
            padding: 12px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            transition: all 0.2s ease;
        }
        
        .client-item:hover {
            background: rgba(255, 255, 255, 0.08);
            transform: translateX(4px);
        }
        
        .client-icon {
            font-size: 1.2rem;
            margin-right: 12px;
            min-width: 24px;
            text-align: center;
            color: #4a9eff;
            opacity: 0.6;
        }
        
        .client-info {
            flex: 1;
            min-width: 0;
        }
        
        .client-name {
            color: #fff;
            font-weight: 500;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        
        .client-details {
            color: #888;
            font-size: 0.85rem;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        
        .client-bandwidth {
            margin-left: auto;
            padding: 0 8px;
            text-align: right;
            min-width: 100px;
        }
        
        .bandwidth-label {
            font-size: 0.7rem;
            color: #666;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        
        .bandwidth-value {
            font-size: 0.75rem;
            color: #4a9eff;
            font-family: 'Courier New', monospace;
        }
        
        .bandwidth-value.active {
            color: #4ade80;
            font-weight: 500;
        }
        
        .client-state-indicator {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-left: 8px;
            background: #666;
            box-shadow: 0 0 4px rgba(0, 0, 0, 0.5);
            transition: all 0.3s ease;
            flex-shrink: 0;
        }
        
        .client-state-indicator.reachable {
            background: #4ade80;
            box-shadow: 0 0 8px #4ade80, 0 0 12px #4ade80;
            animation: pulse-green 2s infinite;
        }
        
        .client-state-indicator.stale {
            background: #fbbf24;
            box-shadow: 0 0 6px #fbbf24;
        }
        
        .client-state-indicator.failed,
        .client-state-indicator.unknown {
            background: #666;
            box-shadow: none;
        }
        
        @keyframes pulse-green {
            0%, 100% { 
                box-shadow: 0 0 8px #4ade80, 0 0 12px #4ade80;
                opacity: 1;
            }
            50% { 
                box-shadow: 0 0 12px #4ade80, 0 0 20px #4ade80;
                opacity: 0.8;
            }
        }

        h1 {
            font-size: 3rem;
            font-weight: 300;
            letter-spacing: -1px;
            margin-bottom: 10px;
            background: linear-gradient(135deg, #4a9eff 0%, #00d4ff 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .subtitle {
            font-size: 1.2rem;
            color: #888;
            font-weight: 300;
        }
        
        .timing-info {
            margin-top: 15px;
            padding: 10px 20px;
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 8px;
            font-size: 0.85rem;
            display: inline-block;
        }
        
        .timing-label {
            color: #888;
            margin-right: 8px;
        }
        
        .timing-value {
            color: #4a9eff;
            font-weight: 500;
            margin-right: 12px;
        }
        
        .timing-value.slow {
            color: #fbbf24;
        }
        
        .timing-value.very-slow {
            color: #ef4444;
        }
        
        .timing-details {
            color: #666;
            font-size: 0.8rem;
        }
        
        .timing-details span {
            margin: 0 4px;
        }

        .services-title {
            font-size: 1.2rem;
            margin-top: 40px;
            margin-bottom: 20px;
            color: #fff;
            padding-left: 8px;
        }
        
        .services-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
            gap: 12px;
            margin-bottom: 40px;
        }

        .service-card {
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 12px;
            padding: 16px;
            text-align: center;
            transition: all 0.2s ease;
            text-decoration: none;
            display: block;
        }

        .service-card:hover {
            transform: translateY(-2px);
            background: rgba(255, 255, 255, 0.08);
            border-color: rgba(255, 255, 255, 0.2);
        }

        .service-icon {
            font-size: 1.6rem;
            margin-bottom: 8px;
            display: block;
            opacity: 0.8;
            color: #4a9eff;
        }

        .service-name {
            color: #e0e0e0;
            font-size: 0.9rem;
            font-weight: 500;
        }

        .loading {
            animation: pulse 2s infinite;
        }
        
        @keyframes pulse {
            0%, 100% { opacity: 0.6; }
            50% { opacity: 1; }
        }
        
        @media (max-width: 768px) {
            h1 {
                font-size: 2rem;
            }
            .subtitle {
                font-size: 1rem;
            }
            .grid {
                grid-template-columns: 1fr;
            }
            .system-stats {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Router Dashboard</h1>
            <p class="subtitle">Network Services & Monitoring</p>
            <div class="timing-info" id="timing-info" style="display: none;">
                <span class="timing-label">Response:</span>
                <span class="timing-value" id="timing-value">--ms</span>
                <span class="timing-details" id="timing-details"></span>
            </div>
        </div>

        <!-- System Statistics -->
        <div class="system-stats">
            <div class="stat-card">
                <div class="stat-label">Internet</div>
                <div class="stat-value loading" id="connectivity-status">--</div>
                <div class="stat-sub" id="connectivity-ping">-- ms avg</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Uptime</div>
                <div class="stat-value loading" id="uptime">--</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">CPU Load</div>
                <div class="stat-value loading" id="cpu-load">--</div>
                <div class="stat-sub" id="cpu-info">-- cores</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Memory</div>
                <div class="stat-value loading" id="memory-percent">--%</div>
                <div class="stat-sub" id="memory-info">--</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Connected Clients</div>
                <div class="stat-value loading" id="client-count">--</div>
                <div class="stat-sub">Active devices</div>
            </div>
        </div>

        <!-- Network Information -->
        <div class="network-info">
            <h3>Network Topology</h3>
            <div class="network-grid">
                <div class="network-item">
                    <span class="network-label">WAN Address:</span>
                    <span class="network-value loading" id="wan-ip">--</span>
                </div>
                <div class="network-item">
                    <span class="network-label">LAN Network:</span>
                    <span class="network-value loading" id="lan-network">--</span>
                </div>
                <div class="network-item">
                    <span class="network-label">Bridge (br-lan):</span>
                    <span class="network-value" id="br-lan-stats">RX: -- / TX: --</span>
                </div>
                <div class="network-item">
                    <span class="network-label">Tailscale:</span>
                    <span class="network-value" id="tailscale-stats">RX: -- / TX: --</span>
                </div>
            </div>
        </div>

        <!-- Connected Clients -->
        <div class="clients-section" x-data="clientsApp" x-init="init()">
            <div class="clients-header">
                <h3 class="clients-title">Connected Devices (<span x-text="clients.length">0</span>)</h3>
                <div class="sort-controls">
                    <button 
                        class="sort-btn" 
                        :class="{ 'active': sortField === 'name', 'desc': sortField === 'name' && sortDirection === 'desc' }"
                        @click="setSortField('name')">
                        <span>Name</span>
                        <i class="lni lni-chevron-up"></i>
                    </button>
                    <button 
                        class="sort-btn" 
                        :class="{ 'active': sortField === 'bandwidth', 'desc': sortField === 'bandwidth' && sortDirection === 'desc' }"
                        @click="setSortField('bandwidth')">
                        <span>Bandwidth</span>
                        <i class="lni lni-chevron-up"></i>
                    </button>
                    <button 
                        class="sort-btn" 
                        :class="{ 'active': sortField === 'status', 'desc': sortField === 'status' && sortDirection === 'desc' }"
                        @click="setSortField('status')">
                        <span>Status</span>
                        <i class="lni lni-chevron-up"></i>
                    </button>
                </div>
            </div>
            <div class="clients-grid">
                <template x-for="client in sortedClients" :key="client.ip">
                    <div class="client-item">
                        <i class="lni client-icon" :class="client.icon || 'lni-mobile'"></i>
                        <div class="client-info">
                            <div class="client-name" x-text="getClientName(client)"></div>
                            <div class="client-details">
                                <span x-text="client.ip"></span> • <span x-text="client.mac"></span>
                            </div>
                        </div>
                        <div class="client-bandwidth">
                            <div>
                                <span class="bandwidth-label">↓</span>
                                <span class="bandwidth-value" 
                                      :class="{ 'active': (client.bandwidth_rx_bps || 0) > 1000 }"
                                      x-text="client.bandwidth_rx_formatted || '0 bps'"></span>
                            </div>
                            <div>
                                <span class="bandwidth-label">↑</span>
                                <span class="bandwidth-value" 
                                      :class="{ 'active': (client.bandwidth_tx_bps || 0) > 1000 }"
                                      x-text="client.bandwidth_tx_formatted || '0 bps'"></span>
                            </div>
                        </div>
                        <div class="client-state-indicator" 
                             :class="(client.state || 'unknown').toLowerCase()" 
                             :title="client.state || 'unknown'"></div>
                    </div>
                </template>
            </div>
        </div>

        <!-- DNS Statistics -->
        <div class="dns-stats-section">
            <h3>DNS Statistics (Blocky)</h3>
            <div class="dns-stats-grid">
                <div class="dns-stat-card">
                    <div class="stat-label">Total Queries</div>
                    <div class="stat-value" id="dns-total-queries">--</div>
                    <div class="stat-sub" id="dns-queries-rate">-- q/min</div>
                </div>
                <div class="dns-stat-card">
                    <div class="stat-label">Blocked</div>
                    <div class="stat-value" id="dns-blocked-percent">--%</div>
                    <div class="stat-sub" id="dns-blocked-count">-- queries</div>
                </div>
                <div class="dns-stat-card">
                    <div class="stat-label">Cache Hit Rate</div>
                    <div class="stat-value" id="dns-cache-hit-rate">--%</div>
                </div>
                <div class="dns-stat-card">
                    <div class="stat-label">Block Lists</div>
                    <div class="block-lists" id="dns-block-lists">
                        <!-- Block lists will be added here -->
                    </div>
                </div>
            </div>
            <div class="dns-top-section">
                <div class="dns-top-clients">
                    <h4>Top Clients</h4>
                    <div id="dns-top-clients-list" class="dns-top-list">
                        <!-- Top clients will be added here -->
                    </div>
                </div>
            </div>
        </div>

        <!-- Services -->
        <h3 class="services-title">Services</h3>
        <div class="services-grid">
            <a href="/grafana/d/router-metrics/router-metrics?kiosk&theme=sapphire-dusk" class="service-card">
                <i class="lni lni-stats-up service-icon"></i>
                <div class="service-name">Metrics</div>
            </a>
            
            <a href="/grafana" class="service-card">
                <i class="lni lni-bar-chart service-icon"></i>
                <div class="service-name">Grafana</div>
            </a>
            
            <a href="/victoriametrics" class="service-card">
                <i class="lni lni-database service-icon"></i>
                <div class="service-name">VictoriaMetrics</div>
            </a>
            
            <a href="/alertmanager" class="service-card">
                <i class="lni lni-alarm service-icon"></i>
                <div class="service-name">Alertmanager</div>
            </a>
            
            <a href="/logs/" class="service-card">
                <i class="lni lni-files service-icon"></i>
                <div class="service-name">System Logs</div>
            </a>
            
            <a href="/vpn-manager" class="service-card">
                <i class="lni lni-shield service-icon"></i>
                <div class="service-name">VPN Manager</div>
            </a>
        </div>
    </div>

    <script>
        // Global metrics store to avoid duplicate API calls
        let metricsStore = {
            data: null,
            subscribers: [],
            
            subscribe(callback) {
                this.subscribers.push(callback);
            },
            
            update(data) {
                this.data = data;
                this.subscribers.forEach(callback => callback(data));
            }
        };
        
        // Alpine.js component for clients list
        document.addEventListener('alpine:init', () => {
            Alpine.data('clientsApp', () => ({
                clients: [],
                sortField: 'name',
                sortDirection: 'asc',
                
                init() {
                    // Subscribe to metrics updates
                    metricsStore.subscribe((data) => {
                        if (data.clients && data.clients.clients) {
                            this.clients = data.clients.clients;
                        }
                    });
                },
                
                get sortedClients() {
                    return [...this.clients].sort((a, b) => {
                        let compareValue = 0;
                        
                        switch (this.sortField) {
                            case 'name':
                                const nameA = this.getClientName(a).toLowerCase();
                                const nameB = this.getClientName(b).toLowerCase();
                                compareValue = nameA.localeCompare(nameB);
                                break;
                                
                            case 'bandwidth':
                                const bwA = (a.bandwidth_rx_bps || 0) + (a.bandwidth_tx_bps || 0);
                                const bwB = (b.bandwidth_rx_bps || 0) + (b.bandwidth_tx_bps || 0);
                                compareValue = bwB - bwA; // Higher first by default
                                break;
                                
                            case 'status':
                                const statusOrder = { 'reachable': 3, 'stale': 2, 'failed': 1, 'unknown': 0 };
                                const stateA = (a.state || 'unknown').toLowerCase();
                                const stateB = (b.state || 'unknown').toLowerCase();
                                compareValue = (statusOrder[stateB] || 0) - (statusOrder[stateA] || 0);
                                break;
                        }
                        
                        return this.sortDirection === 'asc' ? compareValue : -compareValue;
                    });
                },
                
                setSortField(field) {
                    if (this.sortField === field) {
                        // Toggle direction if clicking same field
                        this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
                    } else {
                        // New field, set default direction
                        this.sortField = field;
                        this.sortDirection = field === 'bandwidth' ? 'desc' : 'asc';
                    }
                },
                
                getClientName(client) {
                    return client.hostname && client.hostname !== 'unknown' 
                        ? client.hostname 
                        : client.mac.substring(0, 8).toUpperCase();
                }
            }));
        });
        
        // Function to fetch and update metrics (for non-Alpine parts)
        async function updateMetrics() {
            const startTime = Date.now();
            
            try {
                const response = await fetch('/api/metrics');
                const fetchTime = Date.now() - startTime;
                
                if (!response.ok) {
                    throw new Error('Failed to fetch metrics');
                }
                
                const data = await response.json();
                
                // Update the shared store for Alpine components
                metricsStore.update(data);
                
                // Display timing information
                const timingInfo = document.getElementById('timing-info');
                const timingValue = document.getElementById('timing-value');
                const timingDetails = document.getElementById('timing-details');
                
                if (timingInfo && timingValue && data._timings) {
                    timingInfo.style.display = 'inline-block';
                    const totalTime = data._timings.total || fetchTime;
                    timingValue.textContent = `${totalTime}ms`;
                    
                    // Color code based on response time
                    timingValue.classList.remove('slow', 'very-slow');
                    if (totalTime > 1000) {
                        timingValue.classList.add('very-slow');
                    } else if (totalTime > 500) {
                        timingValue.classList.add('slow');
                    }
                    
                    // Show detailed timings if not from cache
                    if (data._timings.details && !data._timings.from_cache) {
                        const slowest = Object.entries(data._timings.details)
                            .sort((a, b) => b[1] - a[1])
                            .slice(0, 3)
                            .map(([name, time]) => `${name}: ${time}ms`)
                            .join(' | ');
                        timingDetails.textContent = data._timings.from_cache ? '(cached)' : `Slowest: ${slowest}`;
                    } else {
                        timingDetails.textContent = data._timings.from_cache ? '(cached)' : '';
                    }
                }
                
                // Update connectivity status
                const connectivityEl = document.getElementById('connectivity-status');
                const connectivityPingEl = document.getElementById('connectivity-ping');
                if (connectivityEl && data.connectivity) {
                    connectivityEl.textContent = data.connectivity.status_text || 'Unknown';
                    connectivityEl.classList.remove('loading', 'status-online', 'status-offline', 'status-partial');
                    connectivityEl.classList.add(`status-${data.connectivity.status}`);
                    
                    if (connectivityPingEl) {
                        if (data.connectivity.avg_response_time !== null) {
                            connectivityPingEl.textContent = `${data.connectivity.avg_response_time} ms avg`;
                        } else {
                            connectivityPingEl.textContent = 'No response';
                        }
                    }
                }
                
                // Update uptime
                const uptimeEl = document.getElementById('uptime');
                if (uptimeEl && data.uptime) {
                    uptimeEl.textContent = data.uptime.formatted || '--';
                    uptimeEl.classList.remove('loading');
                }
                
                // Update CPU load
                const cpuLoadEl = document.getElementById('cpu-load');
                const cpuInfoEl = document.getElementById('cpu-info');
                if (cpuLoadEl && data.cpu) {
                    cpuLoadEl.textContent = data.cpu.load_1.toFixed(2);
                    cpuLoadEl.classList.remove('loading');
                    if (cpuInfoEl) {
                        cpuInfoEl.textContent = `${data.cpu.cores} cores | ${data.cpu.usage_percent}% usage`;
                    }
                }
                
                // Update memory
                const memPercentEl = document.getElementById('memory-percent');
                const memInfoEl = document.getElementById('memory-info');
                if (memPercentEl && data.memory) {
                    memPercentEl.textContent = `${data.memory.percent}%`;
                    memPercentEl.classList.remove('loading');
                    if (memInfoEl && data.memory.formatted) {
                        memInfoEl.textContent = `${data.memory.formatted.used} / ${data.memory.formatted.total}`;
                    }
                }
                
                // Update client count (only for the system stats card)
                const clientCountEl = document.getElementById('client-count');
                
                if (clientCountEl && data.clients) {
                    clientCountEl.textContent = data.clients.count;
                    clientCountEl.classList.remove('loading');
                }
                
                // Update network info
                const wanIpEl = document.getElementById('wan-ip');
                if (wanIpEl && data.network) {
                    wanIpEl.textContent = data.network.wan_ip || 'unknown';
                    wanIpEl.classList.remove('loading');
                }
                
                const lanNetworkEl = document.getElementById('lan-network');
                if (lanNetworkEl && data.network && data.network.lan_network) {
                    lanNetworkEl.textContent = data.network.lan_network.cidr || '10.1.1.0/24';
                    lanNetworkEl.classList.remove('loading');
                }
                
                // Update interface stats
                if (data.network && data.network.interfaces) {
                    const brLanEl = document.getElementById('br-lan-stats');
                    if (brLanEl && data.network.interfaces['br-lan']) {
                        const stats = data.network.interfaces['br-lan'];
                        brLanEl.textContent = `RX: ${stats.formatted.rx} / TX: ${stats.formatted.tx}`;
                    }
                    
                    const tailscaleEl = document.getElementById('tailscale-stats');
                    if (tailscaleEl && data.network.interfaces.tailscale0) {
                        const stats = data.network.interfaces.tailscale0;
                        tailscaleEl.textContent = `RX: ${stats.formatted.rx} / TX: ${stats.formatted.tx}`;
                    }
                }
                
                // Update DNS Statistics
                if (data.blocky && data.blocky.enabled) {
                    // Total queries
                    const dnsTotalEl = document.getElementById('dns-total-queries');
                    if (dnsTotalEl) {
                        dnsTotalEl.textContent = data.blocky.total_queries.toLocaleString();
                    }
                    
                    // Queries rate
                    const dnsRateEl = document.getElementById('dns-queries-rate');
                    if (dnsRateEl) {
                        dnsRateEl.textContent = `${data.blocky.queries_per_minute} q/min`;
                    }
                    
                    // Blocked percentage
                    const dnsBlockedPercentEl = document.getElementById('dns-blocked-percent');
                    if (dnsBlockedPercentEl) {
                        dnsBlockedPercentEl.textContent = `${data.blocky.block_percentage}%`;
                    }
                    
                    // Blocked count
                    const dnsBlockedCountEl = document.getElementById('dns-blocked-count');
                    if (dnsBlockedCountEl) {
                        dnsBlockedCountEl.textContent = `${data.blocky.blocked_queries.toLocaleString()} queries`;
                    }
                    
                    // Cache hit rate
                    const dnsCacheEl = document.getElementById('dns-cache-hit-rate');
                    if (dnsCacheEl) {
                        dnsCacheEl.textContent = `${data.blocky.cache_hit_rate}%`;
                    }
                    
                    // Block lists
                    const blockListsEl = document.getElementById('dns-block-lists');
                    if (blockListsEl && data.blocky.blocking_lists) {
                        blockListsEl.innerHTML = '';
                        for (const [list, count] of Object.entries(data.blocky.blocking_lists)) {
                            const item = document.createElement('div');
                            item.className = 'block-list-item';
                            item.textContent = `${list}: ${count}`;
                            blockListsEl.appendChild(item);
                        }
                    }
                    
                    // Top clients
                    const topClientsEl = document.getElementById('dns-top-clients-list');
                    if (topClientsEl && data.blocky.top_clients) {
                        topClientsEl.innerHTML = '';
                        data.blocky.top_clients.forEach(client => {
                            const item = document.createElement('div');
                            item.className = 'dns-client-item';
                            
                            const name = client.hostname && client.hostname !== 'unknown' 
                                ? client.hostname 
                                : client.ip;
                            
                            item.innerHTML = `
                                <span class="dns-client-name">${name}</span>
                                <span class="dns-client-count">${client.queries.toLocaleString()}</span>
                            `;
                            topClientsEl.appendChild(item);
                        });
                    }
                }
                
            } catch (error) {
                console.error('Error fetching metrics:', error);
                // On error, remove loading class but show error state
                document.querySelectorAll('.loading').forEach(el => {
                    el.classList.remove('loading');
                    if (!el.textContent || el.textContent === '--') {
                        el.textContent = 'N/A';
                    }
                });
            }
        }
        
        // Function to continuously update metrics with delay after completion
        async function updateMetricsContinuously() {
            await updateMetrics();
            // Wait 5 seconds after the request completes before starting the next one
            setTimeout(updateMetricsContinuously, 5000);
        }
        
        // Start the update cycle
        updateMetricsContinuously();
    </script>
</body>
</html>
"""

class MetricsCache:
    """Simple time-based cache for metrics"""
    def __init__(self, ttl_seconds=10):
        self.cache = {}
        self.ttl = ttl_seconds
        self.lock = threading.Lock()
    
    def get(self, key):
        with self.lock:
            if key in self.cache:
                value, timestamp = self.cache[key]
                if time.time() - timestamp < self.ttl:
                    return value
                del self.cache[key]
            return None
    
    def set(self, key, value):
        with self.lock:
            self.cache[key] = (value, time.time())

class HostnameCache:
    """Persistent hostname cache with async DNS resolution"""
    def __init__(self, cache_file='/tmp/hostname_cache.json'):
        self.cache = {}
        self.cache_file = cache_file
        self.lock = threading.Lock()
        self.resolution_queue = []
        self.last_resolution = {}
        self.load_cache()
        # Start background hostname resolution thread
        self.resolver_thread = threading.Thread(target=self._background_resolver, daemon=True)
        self.resolver_thread.start()
    
    def load_cache(self):
        """Load hostname cache from disk"""
        try:
            with open(self.cache_file, 'r') as f:
                data = json.load(f)
                # Convert to format: {ip: {'hostname': str, 'timestamp': float}}
                self.cache = data if isinstance(data, dict) else {}
        except:
            self.cache = {}
    
    def save_cache(self):
        """Save hostname cache to disk"""
        try:
            with self.lock:
                with open(self.cache_file, 'w') as f:
                    json.dump(self.cache, f)
        except:
            pass
    
    def get(self, ip, mac=None):
        """Get hostname for IP, queue for resolution if not cached"""
        with self.lock:
            # Check cache first
            if ip in self.cache and 'hostname' in self.cache[ip]:
                hostname = self.cache[ip]['hostname']
                if hostname and hostname != 'unknown' and hostname != ip:
                    # Refresh old entries slowly (older than 1 hour)
                    if time.time() - self.cache[ip].get('timestamp', 0) > 3600:
                        if ip not in self.resolution_queue:
                            self.resolution_queue.append(ip)
                    return hostname
            
            # Queue for resolution if not recently attempted
            if ip not in self.last_resolution or time.time() - self.last_resolution[ip] > 60:
                if ip not in self.resolution_queue:
                    self.resolution_queue.append(ip)
                self.last_resolution[ip] = time.time()
            
            # Return IP as fallback
            return ip
    
    def set(self, ip, hostname):
        """Set hostname for IP"""
        with self.lock:
            self.cache[ip] = {
                'hostname': hostname,
                'timestamp': time.time()
            }
    
    def _background_resolver(self):
        """Background thread to resolve hostnames slowly"""
        while True:
            try:
                if self.resolution_queue:
                    with self.lock:
                        if self.resolution_queue:
                            ip = self.resolution_queue.pop(0)
                        else:
                            ip = None
                    
                    if ip:
                        # Try DNS resolution (outside lock to avoid blocking)
                        try:
                            hostname = socket.gethostbyaddr(ip)[0].split('.')[0]
                            if hostname and hostname != ip:
                                self.set(ip, hostname)
                                self.save_cache()
                        except:
                            # Failed resolution, cache as unknown
                            self.set(ip, ip)
                
                # Sleep between resolutions to avoid overloading
                time.sleep(0.5)
            except:
                time.sleep(1)

# Global cache instances
metrics_cache = MetricsCache(ttl_seconds=5)  # Cache metrics for 5 seconds
connectivity_cache = MetricsCache(ttl_seconds=30)  # Cache connectivity for 30 seconds
blocky_cache = MetricsCache(ttl_seconds=10)  # Cache Blocky stats for 10 seconds
hostname_cache = HostnameCache()  # Persistent hostname cache

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            # Serve the dashboard HTML
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(DASHBOARD_HTML.encode())
        elif self.path == '/api/metrics':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            metrics = self.get_system_metrics()
            self.wfile.write(json.dumps(metrics).encode())
        else:
            self.send_error(404)
    
    def log_message(self, format, *args):
        # Suppress default logging
        pass
    
    def get_system_metrics(self) -> Dict[str, Any]:
        """Fetch all metrics concurrently for better performance"""
        start_time = time.time()
        
        # Check if we have cached metrics
        cached = metrics_cache.get('all_metrics')
        if cached:
            cached['_timings'] = {'total': 0, 'from_cache': True}
            return cached
        
        results = {}
        timings = {}
        
        # Use ThreadPoolExecutor for concurrent fetching
        with ThreadPoolExecutor(max_workers=8) as executor:
            # Submit all tasks with timing wrappers
            task_starts = {}
            futures = {}
            
            for name, func in [
                ('uptime', self.get_uptime),
                ('cpu', self.get_cpu_info),
                ('memory', self.get_memory_info),
                ('network', self.get_network_info),
                ('clients', self.get_connected_clients),
                ('connectivity', self.get_connectivity_cached),
                ('blocky', self.get_blocky_stats_cached)
            ]:
                task_starts[name] = time.time()
                futures[executor.submit(func)] = name
            
            for future in as_completed(futures):
                key = futures[future]
                try:
                    results[key] = future.result(timeout=3)
                    timings[key] = round((time.time() - task_starts[key]) * 1000, 1)  # ms
                except Exception as e:
                    print(f"Error getting {key}: {e}")
                    results[key] = {}
                    timings[key] = -1  # Mark as error
        
        total_time = round((time.time() - start_time) * 1000, 1)  # ms
        results['timestamp'] = int(time.time())
        results['_timings'] = {
            'total': total_time,
            'details': timings,
            'from_cache': False
        }
        
        # Cache the complete result (but without timings)
        cache_data = {k: v for k, v in results.items() if k != '_timings'}
        metrics_cache.set('all_metrics', cache_data)
        
        return results
    
    def get_uptime(self) -> Dict[str, Any]:
        try:
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.readline().split()[0])
            
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            
            if days > 0:
                formatted = f"{days}d {hours}h {minutes}m"
            elif hours > 0:
                formatted = f"{hours}h {minutes}m"
            else:
                formatted = f"{minutes}m"
            
            return {
                'seconds': int(uptime_seconds),
                'formatted': formatted
            }
        except:
            return {'seconds': 0, 'formatted': 'unknown'}
    
    def get_cpu_info(self) -> Dict[str, Any]:
        try:
            # Get load averages
            with open('/proc/loadavg', 'r') as f:
                loads = f.readline().split()[:3]
                load_1, load_5, load_15 = map(float, loads)
            
            # Get CPU count
            cpu_count = os.cpu_count() or 1
            
            # Get CPU usage from /proc/stat
            with open('/proc/stat', 'r') as f:
                cpu_line = f.readline()
                cpu_times = list(map(int, cpu_line.split()[1:8]))
            
            idle = cpu_times[3] + cpu_times[4]
            total = sum(cpu_times)
            
            # Store current values for next calculation
            if not hasattr(self, '_last_cpu'):
                self._last_cpu = {'total': total, 'idle': idle}
                usage = 0.0
            else:
                total_diff = total - self._last_cpu['total']
                idle_diff = idle - self._last_cpu['idle']
                usage = 100.0 * (1.0 - (idle_diff / total_diff)) if total_diff > 0 else 0.0
                self._last_cpu = {'total': total, 'idle': idle}
            
            return {
                'load_1': load_1,
                'load_5': load_5,
                'load_15': load_15,
                'cores': cpu_count,
                'usage_percent': round(usage, 1)
            }
        except:
            return {
                'load_1': 0.0,
                'load_5': 0.0,
                'load_15': 0.0,
                'cores': 1,
                'usage_percent': 0.0
            }
    
    def get_memory_info(self) -> Dict[str, Any]:
        try:
            meminfo = {}
            with open('/proc/meminfo', 'r') as f:
                for line in f:
                    parts = line.split(':')
                    if len(parts) == 2:
                        key = parts[0].strip()
                        value = int(parts[1].strip().split()[0]) * 1024  # Convert KB to bytes
                        meminfo[key] = value
            
            total = meminfo.get('MemTotal', 0)
            available = meminfo.get('MemAvailable', 0)
            used = total - available
            percent = (used / total * 100) if total > 0 else 0
            
            return {
                'total_bytes': total,
                'used_bytes': used,
                'available_bytes': available,
                'percent': round(percent, 1),
                'formatted': {
                    'total': self.format_bytes(total),
                    'used': self.format_bytes(used),
                    'available': self.format_bytes(available)
                }
            }
        except:
            return {
                'total_bytes': 0,
                'used_bytes': 0,
                'available_bytes': 0,
                'percent': 0,
                'formatted': {
                    'total': '0 B',
                    'used': '0 B',
                    'available': '0 B'
                }
            }
    
    def get_network_info(self) -> Dict[str, Any]:
        info = {
            'wan_ip': self.get_wan_ip(),
            'lan_network': self.get_lan_network(),
            'interfaces': self.get_interface_stats()
        }
        return info
    
    def get_wan_ip(self) -> str:
        # Try to get WAN IP from configured WAN interface
        try:
            # First try ppp0 (PPPoE)
            result = subprocess.run(
                ['ip', '-4', 'addr', 'show', 'ppp0'],
                capture_output=True,
                text=True,
                timeout=1
            )
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if 'inet ' in line:
                        return line.split()[1].split('/')[0]
        except:
            pass
        
        # Try eth0 or other common WAN interfaces
        for iface in ['eth0', 'wan', 'enp1s0']:
            try:
                result = subprocess.run(
                    ['ip', '-4', 'addr', 'show', iface],
                    capture_output=True,
                    text=True,
                    timeout=1
                )
                if result.returncode == 0:
                    for line in result.stdout.split('\n'):
                        if 'inet ' in line and not line.strip().startswith('inet 10.') and not line.strip().startswith('inet 192.168.'):
                            return line.split()[1].split('/')[0]
            except:
                continue
        
        return 'unknown'
    
    def get_lan_network(self) -> Dict[str, Any]:
        try:
            # Get LAN network from br-lan interface
            result = subprocess.run(
                ['ip', '-4', 'addr', 'show', 'br-lan'],
                capture_output=True,
                text=True,
                timeout=1
            )
            
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if 'inet ' in line:
                        cidr = line.split()[1]
                        ip, prefix_len = cidr.split('/')
                        return {
                            'ip': ip,
                            'cidr': cidr,
                            'prefix_length': int(prefix_len)
                        }
        except:
            pass
        
        # Default fallback
        return {
            'ip': '10.1.1.1',
            'cidr': '10.1.1.0/24',
            'prefix_length': 24
        }
    
    def get_interface_stats(self) -> Dict[str, Any]:
        stats = {}
        try:
            with open('/proc/net/dev', 'r') as f:
                lines = f.readlines()[2:]  # Skip header lines
                
            for line in lines:
                if ':' in line:
                    iface, data = line.split(':', 1)
                    iface = iface.strip()
                    
                    # Only include relevant interfaces
                    if iface in ['br-lan', 'eth0', 'ppp0', 'tailscale0', 'enp1s0', 'enp2s0', 'enp3s0', 'enp4s0']:
                        values = data.split()
                        stats[iface] = {
                            'rx_bytes': int(values[0]),
                            'rx_packets': int(values[1]),
                            'tx_bytes': int(values[8]),
                            'tx_packets': int(values[9]),
                            'formatted': {
                                'rx': self.format_bytes(int(values[0])),
                                'tx': self.format_bytes(int(values[8]))
                            }
                        }
        except:
            pass
        
        return stats
    
    def get_device_type(self, mac: str, hostname: str = '') -> str:
        """Determine device type from MAC vendor and hostname patterns"""
        mac_upper = mac.upper().replace(':', '')
        hostname_lower = hostname.lower() if hostname else ''
        
        # Check hostname patterns first (more specific)
        if hostname_lower and hostname_lower != 'unknown':
            if 'iphone' in hostname_lower or 'ipad' in hostname_lower or 'ipod' in hostname_lower:
                return 'apple'
            elif 'android' in hostname_lower or 'galaxy' in hostname_lower or 'pixel' in hostname_lower or 'samsung' in hostname_lower:
                return 'android'
            elif 'macbook' in hostname_lower or 'imac' in hostname_lower or 'mac-' in hostname_lower or 'mbp' in hostname_lower:
                return 'laptop'
            elif 'chromecast' in hostname_lower or 'google-home' in hostname_lower or 'nest' in hostname_lower:
                return 'smart-speaker'
            elif 'echo' in hostname_lower or 'alexa' in hostname_lower:
                return 'smart-speaker'
            elif 'tv' in hostname_lower or 'roku' in hostname_lower or 'firetv' in hostname_lower or 'shield' in hostname_lower:
                return 'tv'
            elif 'playstation' in hostname_lower or 'ps4' in hostname_lower or 'ps5' in hostname_lower:
                return 'game-console'
            elif 'xbox' in hostname_lower:
                return 'game-console'
            elif 'switch' in hostname_lower or 'nintendo' in hostname_lower:
                return 'game-console'
            elif 'printer' in hostname_lower or 'print' in hostname_lower:
                return 'printer'
            elif 'nas' in hostname_lower or 'synology' in hostname_lower or 'qnap' in hostname_lower or 'storage' in hostname_lower:
                return 'server'
            elif 'raspberry' in hostname_lower or 'raspberrypi' in hostname_lower or 'rpi' in hostname_lower:
                return 'raspberry-pi'
            elif 'desktop' in hostname_lower or 'pc-' in hostname_lower or 'workstation' in hostname_lower:
                return 'desktop'
            elif 'laptop' in hostname_lower or 'notebook' in hostname_lower or 'thinkpad' in hostname_lower:
                return 'laptop'
            elif 'server' in hostname_lower or 'vm-' in hostname_lower:
                return 'server'
            elif 'camera' in hostname_lower or 'cam' in hostname_lower:
                return 'camera'
            elif 'watch' in hostname_lower:
                return 'watch'
        
        # Check MAC vendor prefixes - simpler approach
        if len(mac_upper) >= 6:
            oui = mac_upper[:6]
            
            # Apple - common prefixes
            apple_prefixes = ['3C22FB', '48A195', 'F0D1A9', '70ECE4', 'A8667F', '38F9D3', '1C1AC0', '6C4008', 
                             'A47733', '7014A6', '3CE072', 'B8E856', '70F087', '4C3275', '440010', 'A45E60',
                             'F0F61C', '98F0AB', 'DC415F', '30F7C5', '98CA33', '68D93C', 'D89E3F', '88E9FE',
                             'E0AC69', 'F8FF0B', '84A134', '406C8F', '58B035', 'F02475', '883955', 'F85971',
                             'BCE143', '5C9698', 'CE2BAD', '5CA6E6', 'D88C79', 'B2E983', 'D8D822', '508811',
                             '3C9BD6', '9EE84C', '7C4D8F', '5CCD5B', '74D83E']
            
            for prefix in apple_prefixes:
                if oui == prefix or mac_upper.startswith(prefix[:5]):
                    return 'apple'
            
            # Raspberry Pi
            if oui in ['B827EB', 'DC2632', 'E45F01', 'D8E743', '2C9E5F']:
                return 'raspberry-pi'
            
            # Samsung/Android devices 
            samsung_prefixes = ['5CA6E6', '3C9BD6', 'D88C79', '849DC4', 'CCB11A', '78D752', '94103A', 
                               'BC72B4', '40B895', 'F4D9FB', 'B86CE8', '001664']
            for prefix in samsung_prefixes:
                if oui == prefix or mac_upper.startswith(prefix[:5]):
                    return 'android'
            
            # Intel NICs (likely desktop/server)
            intel_prefixes = ['001E67', '00D861', 'F4D4B8', '7C5CF8', '3C9701', '5065F3', 'B4969']
            for prefix in intel_prefixes:
                if oui == prefix or mac_upper.startswith(prefix[:5]):
                    return 'desktop'
            
            # TP-Link (likely router/switch)
            if mac_upper.startswith(('98DAC', '50C7B', '8C210')):
                return 'router'
            
            # Gaming consoles
            if oui in ['0011D9', '001A11', '001422', '0018DD', '00192F', '001C62', '001D60', '001DD8']:
                return 'game-console'
            
            # Sony PlayStation
            if oui in ['000414', 'F84610', 'FC0FE6', 'BC6065', '28C78']:
                return 'game-console'
            
            # Microsoft Xbox
            if oui in ['7CBB8A', '30594', '28187', 'CC6683']:
                return 'game-console'
            
            # Nintendo
            if oui in ['0009BF', '001656', '0017AB', '001AE9', '001B7A', '001BEA']:
                return 'game-console'
            
            # Smart TVs
            if mac_upper.startswith(('0050F2', '00D9D1', '3CD923', 'FC0171')):
                return 'tv'
            
            # Printers
            if mac_upper.startswith(('001738', '001975', '002155', '002654')):
                return 'printer'
            
            # Google devices
            if mac_upper.startswith(('E063DA', '30B5F5')):
                return 'smart-speaker'
            
            # Check for randomized/private MAC addresses (local bit set)
            if len(mac_upper) >= 2:
                first_octet = int(mac_upper[:2], 16)
                # Check if local bit (bit 1 of first octet) is set - indicates randomized MAC
                if first_octet & 0x02:
                    # Try to guess based on other patterns
                    # Many Apple devices use randomized MACs starting with certain patterns
                    if mac_upper[:2] in ['02', '06', '0A', '0E', '12', '16', '1A', '1E', '22', '26', '2A', '2E', 
                                         '32', '36', '3A', '3E', '42', '46', '4A', '4E', '52', '56', '5A', '5E',
                                         '62', '66', '6A', '6E', '72', '76', '7A', '7E', '82', '86', '8A', '8E',
                                         '92', '96', '9A', '9E', 'A2', 'A6', 'AA', 'AE', 'B2', 'B6', 'BA', 'BE',
                                         'C2', 'C6', 'CA', 'CE', 'D2', 'D6', 'DA', 'DE', 'E2', 'E6', 'EA', 'EE',
                                         'F2', 'F6', 'FA', 'FE']:
                        # Without hostname, hard to identify randomized MACs
                        return 'generic'
        
        # Default fallback
        return 'generic'
    
    def get_device_icon(self, device_type: str) -> str:
        """Get Lineicon class for device type"""
        icons = {
            'apple': 'lni-mobile',  # Apple devices - use mobile icon
            'android': 'lni-android-original',  # Android has original variant
            'laptop': 'lni-laptop',
            'desktop': 'lni-display-alt',
            'tv': 'lni-display',
            'game-console': 'lni-game',
            'smart-speaker': 'lni-volume-high',
            'printer': 'lni-printer',
            'server': 'lni-server',
            'raspberry-pi': 'lni-code-alt',  # Use code icon for Pi
            'router': 'lni-network',  # Use network icon for router
            'camera': 'lni-camera',
            'watch': 'lni-timer',
            'tablet': 'lni-tab',
            'generic': 'lni-mobile'
        }
        return icons.get(device_type, 'lni-mobile')
    
    def get_connectivity_cached(self) -> Dict[str, Any]:
        """Cached version of connectivity check"""
        cached = connectivity_cache.get('connectivity')
        if cached:
            return cached
        
        result = self.check_connectivity()
        connectivity_cache.set('connectivity', result)
        return result
    
    def get_blocky_stats_cached(self) -> Dict[str, Any]:
        """Cached version of Blocky stats"""
        cached = blocky_cache.get('blocky_stats')
        if cached:
            return cached
        
        result = self.get_blocky_stats()
        blocky_cache.set('blocky_stats', result)
        return result
    
    def query_victoriametrics(self, query: str) -> Optional[Any]:
        """Query VictoriaMetrics and return the result"""
        try:
            url = f"http://localhost:8428/api/v1/query?query={urllib.parse.quote(query)}"
            with urllib.request.urlopen(url, timeout=2) as response:
                data = json.loads(response.read().decode())
                if data.get('status') == 'success' and data.get('data', {}).get('result'):
                    return data['data']['result']
                return None
        except Exception as e:
            print(f"Error querying VictoriaMetrics: {e}")
            return None
    
    def get_blocky_stats(self) -> Dict[str, Any]:
        """Get DNS statistics from Blocky via VictoriaMetrics - optimized with concurrent queries"""
        try:
            stats = {
                'enabled': False,
                'total_queries': 0,
                'blocked_queries': 0,
                'block_percentage': 0,
                'queries_per_minute': 0,
                'cache_hit_rate': 0,
                'top_clients': [],
                'top_blocked_domains': [],
                'blocking_lists': {}
            }
            
            # Check if Blocky is running first
            up_result = self.query_victoriametrics('blocky_build_info')
            if not up_result:
                return stats
            
            stats['enabled'] = True
            
            # Define all queries we need to make
            queries = {
                'total': 'sum(blocky_query_total)',
                'blocked': 'sum(blocky_response_total{response_type="BLOCKED"})',
                'qpm': 'sum(rate(blocky_query_total[5m])) * 60',
                'cache_hits': 'sum(blocky_cache_hits_total)',
                'cache_misses': 'sum(blocky_cache_misses_total)',
                'top_clients': 'topk(5, sum by (client) (blocky_query_total))',
                'blocking': 'sum by (reason) (blocky_response_total{response_type="BLOCKED"})'
            }
            
            # Execute all queries concurrently
            query_results = {}
            with ThreadPoolExecutor(max_workers=len(queries)) as executor:
                future_to_key = {executor.submit(self.query_victoriametrics, query): key 
                                for key, query in queries.items()}
                
                for future in as_completed(future_to_key):
                    key = future_to_key[future]
                    try:
                        query_results[key] = future.result(timeout=1)
                    except Exception as e:
                        print(f"Error querying {key}: {e}")
                        query_results[key] = None
            
            # Process results
            if query_results.get('total') and len(query_results['total']) > 0:
                stats['total_queries'] = int(float(query_results['total'][0]['value'][1]))
            
            if query_results.get('blocked') and len(query_results['blocked']) > 0:
                stats['blocked_queries'] = int(float(query_results['blocked'][0]['value'][1]))
            
            if stats['total_queries'] > 0:
                stats['block_percentage'] = round((stats['blocked_queries'] / stats['total_queries']) * 100, 1)
            
            if query_results.get('qpm') and len(query_results['qpm']) > 0:
                stats['queries_per_minute'] = round(float(query_results['qpm'][0]['value'][1]), 1)
            
            # Calculate cache hit rate
            if query_results.get('cache_hits') and query_results.get('cache_misses'):
                if len(query_results['cache_hits']) > 0 and len(query_results['cache_misses']) > 0:
                    hits = float(query_results['cache_hits'][0]['value'][1])
                    misses = float(query_results['cache_misses'][0]['value'][1])
                    total_cache = hits + misses
                    if total_cache > 0:
                        stats['cache_hit_rate'] = round((hits / total_cache) * 100, 1)
            
            # Process top clients (don't resolve hostnames here - too slow)
            if query_results.get('top_clients'):
                for item in query_results['top_clients'][:5]:
                    client_ip = item['metric'].get('client', 'unknown')
                    count = int(float(item['value'][1]))
                    stats['top_clients'].append({
                        'ip': client_ip,
                        'hostname': client_ip,  # Just use IP for speed
                        'queries': count
                    })
            
            # Process blocking lists
            if query_results.get('blocking'):
                for item in query_results['blocking']:
                    reason = item['metric'].get('reason', 'unknown')
                    count = int(float(item['value'][1]))
                    if 'BLOCKED' in reason and '(' in reason and ')' in reason:
                        list_name = reason.split('(')[1].rstrip(')')
                        stats['blocking_lists'][list_name] = count
            
            return stats
            
        except Exception as e:
            print(f"Error getting Blocky stats: {e}")
            return {
                'enabled': False,
                'error': str(e)
            }
    
    def ping_host(self, target: Dict[str, str]) -> Dict[str, Any]:
        """Ping a single host"""
        try:
            result = subprocess.run(
                ['ping', '-c', '1', '-W', '1', target['host']],
                capture_output=True,
                text=True,
                timeout=1.5
            )
            
            if result.returncode == 0:
                # Parse response time from ping output
                for line in result.stdout.split('\n'):
                    if 'time=' in line:
                        time_ms = float(line.split('time=')[1].split(' ')[0])
                        return {
                            'host': target['host'],
                            'name': target['name'],
                            'reachable': True,
                            'response_time': time_ms
                        }
            
            return {
                'host': target['host'],
                'name': target['name'],
                'reachable': False,
                'response_time': None
            }
        except Exception as e:
            return {
                'host': target['host'],
                'name': target['name'],
                'reachable': False,
                'response_time': None,
                'error': str(e)
            }
    
    def check_connectivity(self) -> Dict[str, Any]:
        """Check internet connectivity by pinging external hosts - optimized with parallel pings"""
        check_hosts = [
            {'host': '1.1.1.1', 'name': 'Cloudflare DNS'},
            {'host': '8.8.8.8', 'name': 'Google DNS'},
            {'host': '9.9.9.9', 'name': 'Quad9 DNS'}
        ]
        
        # Run pings in parallel
        results = []
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(self.ping_host, target) for target in check_hosts]
            for future in as_completed(futures):
                try:
                    results.append(future.result(timeout=2))
                except Exception as e:
                    print(f"Error in connectivity check: {e}")
        
        # Determine overall connectivity status
        reachable_count = sum(1 for r in results if r.get('reachable', False))
        if reachable_count == len(check_hosts):
            status = 'online'
            status_text = 'Connected'
        elif reachable_count > 0:
            status = 'partial'
            status_text = 'Partial Connectivity'
        else:
            status = 'offline'
            status_text = 'No Connection'
        
        # Calculate average response time
        response_times = [r['response_time'] for r in results if r.get('response_time') is not None]
        avg_response_time = sum(response_times) / len(response_times) if response_times else None
        
        return {
            'status': status,
            'status_text': status_text,
            'checks': results,
            'reachable_count': reachable_count,
            'total_checks': len(check_hosts),
            'avg_response_time': round(avg_response_time, 1) if avg_response_time else None
        }
    
    def get_connected_clients(self) -> Dict[str, Any]:
        """Get connected clients - with internal timing for debugging"""
        start = time.time()
        clients = []
        seen_macs = set()
        seen_ips = set()
        
        internal_timings = {}
        
        # Get bandwidth data from VictoriaMetrics
        bandwidth_data = self.get_client_bandwidth_rates()
        
        # First load all Kea lease data into a lookup dict
        kea_start = time.time()
        kea_data = {}
        try:
            lease_file = '/var/lib/kea/kea-leases4.csv'
            if os.path.exists(lease_file):
                with open(lease_file, 'r') as f:
                    lines = f.readlines()
                    if lines and lines[0].startswith('address,'):
                        lines = lines[1:]
                    
                    for line in lines:
                        parts = line.strip().split(',')
                        if len(parts) >= 9:
                            ip = parts[0]
                            mac = parts[1].lower()
                            hostname = parts[8] if parts[8] else ''
                            # Store all leases, even expired ones for hostname lookup
                            if mac and mac != '00:00:00:00:00:00':
                                if mac not in kea_data or (hostname and not kea_data.get(mac, {}).get('hostname')):
                                    kea_data[mac] = {'ip': ip, 'hostname': hostname}
                                    # Also cache the hostname if we have one
                                    if hostname and hostname != 'unknown':
                                        hostname_cache.set(ip, hostname)
        except:
            pass
        internal_timings['kea_load'] = round((time.time() - kea_start) * 1000, 1)
        
        # Try faster method: Get states from ip neigh with aggressive timeout
        arp_start = time.time()
        ip_states = {}
        try:
            # First try to get states from ip neigh with very short timeout
            result = subprocess.run(
                ['ip', '-o', 'neigh', 'show', 'dev', 'br-lan'],  # -o for one-line output
                capture_output=True,
                text=True,
                timeout=0.3  # Very short timeout
            )
            
            if result.returncode == 0 and result.stdout:
                for line in result.stdout.strip().split('\n'):
                    parts = line.split()
                    if len(parts) >= 4:
                        ip = parts[0]
                        # Find state - it's usually the last word
                        state = parts[-1] if parts[-1] in ['REACHABLE', 'STALE', 'DELAY', 'PROBE', 'FAILED', 'PERMANENT'] else 'STALE'
                        ip_states[ip] = state
        except subprocess.TimeoutExpired:
            print(f"ip neigh timed out after 0.3s, using fallback")
        except Exception as e:
            print(f"Error getting states from ip neigh: {e}")
        
        # Read ARP table from /proc/net/arp for comprehensive client list
        try:
            with open('/proc/net/arp', 'r') as f:
                lines = f.readlines()[1:]  # Skip header
                
            for line in lines:
                parts = line.split()
                if len(parts) >= 6:
                    ip = parts[0]
                    hw_type = parts[1]
                    flags = parts[2]
                    mac = parts[3].lower()
                    mask = parts[4]
                    device = parts[5]
                    
                    # Check if it's on br-lan
                    if device == 'br-lan' and mac != '00:00:00:00:00:00':
                        # Get state from ip_states if available, otherwise deduce from flags
                        if ip in ip_states:
                            state = ip_states[ip]
                        else:
                            # Fallback to flags-based detection
                            if flags == '0x0':
                                state = 'FAILED'
                            elif flags in ['0x2', '0x6']:
                                state = 'STALE'  # Default to STALE since we don't know for sure
                            else:
                                state = 'STALE'
                        
                        # Only include complete entries (not failed)
                        if flags != '0x0' and mac not in seen_macs:
                            # Try to get hostname from Kea data first, then hostname cache
                            hostname = ''
                            if mac in kea_data:
                                hostname = kea_data[mac].get('hostname', '')
                            
                            # If no hostname from DHCP, use the hostname cache
                            if not hostname or hostname == 'unknown':
                                hostname = hostname_cache.get(ip, mac)
                            
                            # Determine device type
                            device_type = self.get_device_type(mac, hostname)
                            icon = self.get_device_icon(device_type)
                            
                            # Get bandwidth info for this IP
                            bw_info = bandwidth_data.get(ip, {})
                            
                            clients.append({
                                'ip': ip,
                                'mac': mac,
                                'hostname': hostname if hostname else ip,
                                'device_type': device_type,
                                'icon': icon,
                                'source': 'arp',
                                'state': state,
                                'bandwidth_rx_bps': bw_info.get('rx_bps', 0),
                                'bandwidth_tx_bps': bw_info.get('tx_bps', 0),
                                'bandwidth_rx_formatted': bw_info.get('rx_formatted', '0 bps'),
                                'bandwidth_tx_formatted': bw_info.get('tx_formatted', '0 bps')
                            })
                            seen_macs.add(mac)
                            seen_ips.add(ip)
        except Exception as e:
            print(f"Error reading ARP table: {e}")
            # Fallback to ip command with very short timeout
            try:
                result = subprocess.run(
                    ['ip', 'neigh', 'show', 'dev', 'br-lan'],
                    capture_output=True,
                    text=True,
                    timeout=0.2  # Very short timeout
                )
                if result.returncode == 0 and result.stdout:
                    for line in result.stdout.strip().split('\n'):
                        if not line or 'FAILED' in line:
                            continue
                        parts = line.split()
                        if 'lladdr' in parts and len(parts) >= 3:
                            ip = parts[0]
                            try:
                                lladdr_index = parts.index('lladdr')
                                if lladdr_index + 1 < len(parts):
                                    mac = parts[lladdr_index + 1].lower()
                                    if mac not in seen_macs and mac != '00:00:00:00:00:00':
                                        bw_info = bandwidth_data.get(ip, {})
                                        clients.append({
                                            'ip': ip,
                                            'mac': mac,
                                            'hostname': ip,  # Just use IP for speed
                                            'source': 'arp',
                                            'state': 'REACHABLE',
                                            'bandwidth_rx_bps': bw_info.get('rx_bps', 0),
                                            'bandwidth_tx_bps': bw_info.get('tx_bps', 0),
                                            'bandwidth_rx_formatted': bw_info.get('rx_formatted', '0 bps'),
                                            'bandwidth_tx_formatted': bw_info.get('tx_formatted', '0 bps')
                                        })
                                        seen_macs.add(mac)
                                        seen_ips.add(ip)
                            except:
                                continue
            except:
                pass
        internal_timings['arp_table'] = round((time.time() - arp_start) * 1000, 1)
        
        # Add DHCP leases for any devices not in ARP (recently disconnected but lease still valid)
        lease_start = time.time()
        kea_leases = self.get_kea_leases()
        for lease in kea_leases:
            if lease['mac'] not in seen_macs and lease.get('ip') not in seen_ips:
                # Add bandwidth info for DHCP lease
                bw_info = bandwidth_data.get(lease['ip'], {})
                lease['bandwidth_rx_bps'] = bw_info.get('rx_bps', 0)
                lease['bandwidth_tx_bps'] = bw_info.get('tx_bps', 0)
                lease['bandwidth_rx_formatted'] = bw_info.get('rx_formatted', '0 bps')
                lease['bandwidth_tx_formatted'] = bw_info.get('tx_formatted', '0 bps')
                clients.append(lease)
                seen_macs.add(lease['mac'])
        internal_timings['kea_leases'] = round((time.time() - lease_start) * 1000, 1)
        
        # If still no clients, try connection tracking
        if len(clients) == 0:
            try:
                # Get the LAN network dynamically
                lan_info = self.get_lan_network()
                lan_prefix = lan_info['cidr'].rsplit('.', 1)[0] if lan_info else '10.1.1'
                router_ip = lan_info['ip'] if lan_info else '10.1.1.1'
                
                # Count unique source IPs from LAN network in conntrack
                result = subprocess.run(
                    ['conntrack', '-L'],
                    capture_output=True,
                    text=True,
                    timeout=2
                )
                if result.returncode == 0:
                    unique_ips = set()
                    for line in result.stdout.split('\n'):
                        if f'src={lan_prefix}.' in line:
                            # Extract source IP
                            parts = line.split()
                            for part in parts:
                                if part.startswith(f'src={lan_prefix}.'):
                                    ip = part[4:]
                                    if ip != router_ip:  # Exclude router itself
                                        unique_ips.add(ip)
                                    break
                    
                    # Add as unknown clients if we found any
                    for ip in unique_ips:
                        clients.append({
                            'ip': ip,
                            'mac': 'unknown',
                            'hostname': self.get_hostname_for_ip(ip),
                            'source': 'conntrack'
                        })
            except:
                pass
        
        total_time = round((time.time() - start) * 1000, 1)
        
        # Log if slow
        if total_time > 100:  # More than 100ms
            print(f"Slow get_connected_clients: {total_time}ms, breakdown: {internal_timings}")
        
        return {
            'count': len(clients),
            'clients': clients[:20],  # Limit to 20 for display
            '_debug_timing': total_time
        }
    
    def get_kea_leases(self):
        leases = []
        seen_macs = set()
        
        # Read Kea lease file directly (primary method for router)
        lease_file = '/var/lib/kea/kea-leases4.csv'
        
        try:
            if os.path.exists(lease_file):
                with open(lease_file, 'r') as f:
                    lines = f.readlines()
                    
                # Skip header line if present
                if lines and lines[0].startswith('address,'):
                    lines = lines[1:]
                
                # Parse CSV format: address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,user_context,pool_id
                for line in lines:
                    line = line.strip()
                    if not line:
                        continue
                    
                    parts = line.split(',')
                    if len(parts) >= 10:
                        # Check state field (index 9): 0=active, 1=declined, 2=expired-reclaimed
                        state = parts[9] if len(parts) > 9 else '0'
                        
                        # Only include active leases (state 0)
                        if state == '0':
                            ip = parts[0]
                            mac = parts[1].lower()
                            hostname = parts[8] if len(parts) > 8 and parts[8] else ''
                            
                            # Only add if we have valid IP and MAC, and haven't seen this MAC before
                            if ip and mac and not ip.startswith('#') and mac not in seen_macs:
                                seen_macs.add(mac)
                                # Cache hostname if we have one from DHCP
                                if hostname and hostname != 'unknown':
                                    hostname_cache.set(ip, hostname)
                                # Use cached hostname if no DHCP hostname
                                if not hostname or hostname == 'unknown':
                                    hostname = hostname_cache.get(ip, mac)
                                leases.append({
                                    'ip': ip,
                                    'mac': mac,
                                    'hostname': hostname if hostname else ip,
                                    'source': 'dhcp'
                                })
        except Exception as e:
            print(f"Error reading Kea leases: {e}")
        
        return leases
    
    def get_hostname_from_dhcp(self, ip: str, mac: str) -> str:
        """Try to get hostname from DHCP lease file"""
        try:
            lease_file = '/var/lib/kea/kea-leases4.csv'
            if os.path.exists(lease_file):
                with open(lease_file, 'r') as f:
                    for line in f:
                        parts = line.strip().split(',')
                        if len(parts) >= 9:
                            if parts[0] == ip or parts[1].lower() == mac.lower():
                                hostname = parts[8] if parts[8] else ''
                                if hostname:
                                    return hostname
        except:
            pass
        return ''
    
    def get_hostname_for_ip(self, ip: str) -> str:
        # DNS lookups are too slow - just return unknown
        # This was causing 5+ second delays
        return 'unknown'
    
    def format_bytes(self, bytes_val: int) -> str:
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f"{bytes_val:.1f} {unit}"
            bytes_val /= 1024.0
        return f"{bytes_val:.1f} PB"
    
    def format_bandwidth(self, bps: float) -> str:
        """Format bandwidth from bits per second to human readable format"""
        if bps < 1000:
            return f"{bps:.0f} bps"
        elif bps < 1000000:
            return f"{bps/1000:.1f} Kbps"
        elif bps < 1000000000:
            return f"{bps/1000000:.1f} Mbps"
        else:
            return f"{bps/1000000000:.1f} Gbps"
    
    def get_client_bandwidth_rates(self) -> Dict[str, Dict[str, Any]]:
        """Get bandwidth rates for all clients from VictoriaMetrics"""
        try:
            # Query for all client traffic rates
            query = 'client_traffic_rate_bps'
            result = self.query_victoriametrics(query)
            
            bandwidth_by_ip = {}
            
            if result:
                for item in result:
                    ip = item['metric'].get('ip', '')
                    direction = item['metric'].get('direction', '')
                    rate = float(item['value'][1])
                    
                    if ip not in bandwidth_by_ip:
                        bandwidth_by_ip[ip] = {'rx_bps': 0, 'tx_bps': 0}
                    
                    if direction == 'rx':
                        bandwidth_by_ip[ip]['rx_bps'] = rate
                    elif direction == 'tx':
                        bandwidth_by_ip[ip]['tx_bps'] = rate
            
            # Format the bandwidth for display
            for ip, bw in bandwidth_by_ip.items():
                bw['rx_formatted'] = self.format_bandwidth(bw['rx_bps'])
                bw['tx_formatted'] = self.format_bandwidth(bw['tx_bps'])
                bw['total_bps'] = bw['rx_bps'] + bw['tx_bps']
                bw['total_formatted'] = self.format_bandwidth(bw['total_bps'])
            
            return bandwidth_by_ip
            
        except Exception as e:
            print(f"Error getting client bandwidth rates: {e}")
            return {}

def main():
    parser = argparse.ArgumentParser(description='Router Dashboard and Metrics API Server')
    parser.add_argument('--host', default='localhost', 
                       help='Host to bind to (default: localhost, use 0.0.0.0 for all interfaces)')
    parser.add_argument('--port', type=int, default=8085,
                       help='Port to listen on (default: 8085)')
    parser.add_argument('--bind-all', action='store_true',
                       help='Bind to all interfaces (equivalent to --host 0.0.0.0)')
    
    args = parser.parse_args()
    
    # Override host if --bind-all is specified
    host = '0.0.0.0' if args.bind_all else args.host
    port = args.port
    
    server = HTTPServer((host, port), MetricsHandler)
    
    # Display appropriate URLs based on binding
    if host == '0.0.0.0':
        print(f"Router Dashboard and Metrics API server running on all interfaces, port {port}")
        print(f"  - Dashboard: http://<your-ip>:{port}/")
        print(f"  - Metrics API: http://<your-ip>:{port}/api/metrics")
        # Try to show actual IPs
        try:
            hostname = socket.gethostname()
            local_ips = socket.gethostbyname_ex(hostname)[2]
            for ip in local_ips:
                if not ip.startswith('127.'):
                    print(f"  - Available at: http://{ip}:{port}/")
        except:
            pass
    else:
        print(f"Router Dashboard and Metrics API server running on http://{host}:{port}")
        print(f"  - Dashboard: http://{host}:{port}/")
        print(f"  - Metrics API: http://{host}:{port}/api/metrics")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        server.shutdown()

if __name__ == '__main__':
    main()