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
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {
            darkMode: 'class',
            theme: {
                extend: {
                    colors: {
                        gray: {
                            900: '#0f0f0f',
                            800: '#1a1a1a',
                            700: '#2a2a2a',
                        }
                    }
                }
            }
        }
    </script>
    <script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js"></script>
    <style>
        /* Minimal custom styles */
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: linear-gradient(135deg, #0f0f0f 0%, #1a1a1a 100%);
        }
    </style>
</head>
<body class="dark min-h-screen text-gray-200 p-5">
    <div class="max-w-[1400px] w-full mx-auto">
        <div class="text-center mb-8">
            <h1 class="text-5xl font-light tracking-tight mb-2 bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent">Router Dashboard</h1>
            <p class="text-lg text-gray-400 font-light">Network Services & Monitoring</p>
        </div>

        <!-- System Statistics -->
        <div x-data="statsApp" x-init="init()" class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4 mb-10 p-6 bg-gray-900/30 border border-gray-800 rounded-2xl backdrop-blur-sm">
            <!-- Internet Status Card -->
            <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-xl p-4 text-center hover:bg-gray-800/70 transition-colors">
                <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Internet</div>
                <div class="text-2xl font-bold bg-gradient-to-r bg-clip-text text-transparent"
                     :class="getConnectivityClasses()"
                     x-text="stats.connectivity.status_text || '--'">--</div>
                <div class="text-xs text-gray-500 mt-1" 
                     x-text="stats.connectivity.ping || '-- ms avg'">-- ms avg</div>
            </div>
            
            <!-- Uptime Card -->
            <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-xl p-4 text-center hover:bg-gray-800/70 transition-colors">
                <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Uptime</div>
                <div class="text-2xl font-bold bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent"
                     :class="{ 'animate-pulse': loading }"
                     x-text="stats.uptime || '--'">--</div>
            </div>
            
            <!-- CPU Load Card -->
            <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-xl p-4 text-center hover:bg-gray-800/70 transition-colors">
                <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">CPU Load</div>
                <div class="text-2xl font-bold bg-gradient-to-r bg-clip-text text-transparent"
                     :class="getCpuLoadClasses()"
                     x-text="stats.cpu.load || '--'">--</div>
                <div class="text-xs text-gray-500 mt-1" 
                     x-text="stats.cpu.info || '-- cores'">-- cores</div>
            </div>
            
            <!-- Memory Card -->
            <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-xl p-4 text-center hover:bg-gray-800/70 transition-colors">
                <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Memory</div>
                <div class="text-2xl font-bold bg-gradient-to-r bg-clip-text text-transparent"
                     :class="getMemoryClasses()"
                     x-text="stats.memory.percent || '--%'">--%</div>
                <div class="text-xs text-gray-500 mt-1" 
                     x-text="stats.memory.info || '--'">--</div>
            </div>
            
            <!-- Connected Clients Card -->
            <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-xl p-4 text-center hover:bg-gray-800/70 transition-colors">
                <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Connected Clients</div>
                <div class="text-2xl font-bold bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent"
                     :class="{ 'animate-pulse': loading }"
                     x-text="stats.clientCount || '--'">--</div>
                <div class="text-xs text-gray-500 mt-1">Active devices</div>
            </div>
        </div>

        <!-- Network Information -->
        <div x-data="networkApp" x-init="init()" class="bg-gray-900/30 border border-gray-800 rounded-2xl backdrop-blur-sm p-6 mb-10">
            <h3 class="text-lg font-semibold text-white mb-4 flex items-center">
                <i class="lni lni-network text-cyan-400 mr-2"></i>
                Network Topology
            </h3>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="flex justify-between items-center p-3 bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg hover:bg-gray-800/70 transition-colors">
                    <span class="text-sm text-gray-400 flex items-center">
                        <i class="lni lni-world text-blue-400 mr-2 text-xs"></i>
                        WAN Address:
                    </span>
                    <span class="text-sm font-mono text-white" 
                          :class="{ 'animate-pulse': loading }"
                          x-text="network.wanIp">--</span>
                </div>
                <div class="flex justify-between items-center p-3 bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg hover:bg-gray-800/70 transition-colors">
                    <span class="text-sm text-gray-400 flex items-center">
                        <i class="lni lni-home text-green-400 mr-2 text-xs"></i>
                        LAN Network:
                    </span>
                    <span class="text-sm font-mono text-white"
                          :class="{ 'animate-pulse': loading }"
                          x-text="network.lanNetwork">--</span>
                </div>
                <div class="flex justify-between items-center p-3 bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg hover:bg-gray-800/70 transition-colors group">
                    <span class="text-sm text-gray-400 flex items-center">
                        <i class="lni lni-bridge text-purple-400 mr-2 text-xs"></i>
                        Bridge (br-lan):
                    </span>
                    <div class="text-sm font-mono flex items-center">
                        <i class="lni lni-download text-cyan-400 mr-1 text-xs"></i>
                        <span class="text-cyan-400" x-text="network.interfaces.brLan.rx">--</span>
                        <span class="text-gray-500 mx-2">/</span>
                        <i class="lni lni-upload text-emerald-400 mr-1 text-xs"></i>
                        <span class="text-emerald-400" x-text="network.interfaces.brLan.tx">--</span>
                    </div>
                </div>
                <div class="flex justify-between items-center p-3 bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg hover:bg-gray-800/70 transition-colors group">
                    <span class="text-sm text-gray-400 flex items-center">
                        <i class="lni lni-shield text-orange-400 mr-2 text-xs"></i>
                        Tailscale:
                    </span>
                    <div class="text-sm font-mono flex items-center">
                        <i class="lni lni-download text-cyan-400 mr-1 text-xs"></i>
                        <span class="text-cyan-400" x-text="network.interfaces.tailscale.rx">--</span>
                        <span class="text-gray-500 mx-2">/</span>
                        <i class="lni lni-upload text-emerald-400 mr-1 text-xs"></i>
                        <span class="text-emerald-400" x-text="network.interfaces.tailscale.tx">--</span>
                    </div>
                </div>
            </div>
        </div>

        <!-- Connected Devices -->
        <div x-data="clientsApp" x-init="init()" class="bg-gray-900/30 border border-gray-800 rounded-2xl backdrop-blur-sm p-6 mb-10">
            <div class="flex justify-between items-center mb-5">
                <h3 class="text-lg font-semibold text-white flex items-center">
                    <i class="lni lni-users text-cyan-400 mr-2"></i>
                    Connected Devices (<span x-text="clients.length">0</span>)
                </h3>
                <div class="flex gap-2">
                    <button 
                        class="px-3 py-1.5 text-xs font-medium rounded-md border transition-all duration-200 flex items-center gap-1"
                        :class="sortField === 'name' 
                            ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400' 
                            : 'bg-gray-800/50 border-gray-700/50 text-gray-400 hover:bg-gray-700/50 hover:text-white'"
                        @click="setSortField('name')">
                        <span>Name</span>
                        <i class="lni lni-chevron-up text-[10px]" 
                           :class="{ 'rotate-180': sortField === 'name' && sortDirection === 'desc' }"></i>
                    </button>
                    <button 
                        class="px-3 py-1.5 text-xs font-medium rounded-md border transition-all duration-200 flex items-center gap-1"
                        :class="sortField === 'bandwidth' 
                            ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400' 
                            : 'bg-gray-800/50 border-gray-700/50 text-gray-400 hover:bg-gray-700/50 hover:text-white'"
                        @click="setSortField('bandwidth')">
                        <span>Bandwidth</span>
                        <i class="lni lni-chevron-up text-[10px]" 
                           :class="{ 'rotate-180': sortField === 'bandwidth' && sortDirection === 'desc' }"></i>
                    </button>
                    <button 
                        class="px-3 py-1.5 text-xs font-medium rounded-md border transition-all duration-200 flex items-center gap-1"
                        :class="sortField === 'status' 
                            ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400' 
                            : 'bg-gray-800/50 border-gray-700/50 text-gray-400 hover:bg-gray-700/50 hover:text-white'"
                        @click="setSortField('status')">
                        <span>Status</span>
                        <i class="lni lni-chevron-up text-[10px]" 
                           :class="{ 'rotate-180': sortField === 'status' && sortDirection === 'desc' }"></i>
                    </button>
                </div>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-3 2xl:grid-cols-4 gap-3">
                <template x-for="client in sortedClients" :key="client.ip">
                    <div class="flex items-center p-3 bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg hover:bg-gray-800/70 hover:translate-x-0.5 transition-all duration-200">
                        <i class="lni text-xl mr-3 text-cyan-400 opacity-60" :class="client.icon || 'lni-mobile'"></i>
                        <div class="flex-1 min-w-0">
                            <div class="font-medium text-white text-sm truncate" x-text="getClientName(client)"></div>
                            <div class="text-xs text-gray-400 truncate">
                                <span x-text="client.ip"></span>
                            </div>
                        </div>
                        <div class="ml-auto pl-3 text-right min-w-[90px]">
                            <div class="flex items-center justify-end gap-1 text-xs">
                                <i class="lni lni-download text-cyan-400 text-[10px]"></i>
                                <span class="font-mono text-[11px]" 
                                      :class="(client.bandwidth_rx_bps || 0) > 1000 ? 'text-cyan-400 font-semibold' : 'text-gray-500'"
                                      x-text="client.bandwidth_rx_formatted || '0 bps'"></span>
                            </div>
                            <div class="flex items-center justify-end gap-1 text-xs">
                                <i class="lni lni-upload text-emerald-400 text-[10px]"></i>
                                <span class="font-mono text-[11px]" 
                                      :class="(client.bandwidth_tx_bps || 0) > 1000 ? 'text-emerald-400 font-semibold' : 'text-gray-500'"
                                      x-text="client.bandwidth_tx_formatted || '0 bps'"></span>
                            </div>
                        </div>
                        <div class="ml-2 w-2 h-2 rounded-full flex-shrink-0"
                             :class="{
                                'bg-green-400 shadow-[0_0_8px_rgba(74,222,128,0.6)] animate-pulse': (client.state || '').toLowerCase() === 'reachable',
                                'bg-yellow-400 shadow-[0_0_6px_rgba(251,191,36,0.6)]': (client.state || '').toLowerCase() === 'stale',
                                'bg-gray-600': (client.state || '').toLowerCase() === 'failed' || (client.state || '').toLowerCase() === 'unknown'
                             }"
                             :title="client.state || 'unknown'"></div>
                    </div>
                </template>
            </div>
        </div>

        <!-- DNS Statistics -->
        <div x-data="dnsApp" x-init="init()" class="bg-gray-900/30 border border-gray-800 rounded-2xl backdrop-blur-sm p-6 mb-10">
            <h3 class="text-lg font-semibold text-white mb-4 flex items-center">
                <i class="lni lni-shield-check text-cyan-400 mr-2"></i>
                DNS Statistics (Blocky)
            </h3>
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
                <!-- Total Queries -->
                <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg p-4 hover:bg-gray-800/70 transition-colors">
                    <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Total Queries</div>
                    <div class="text-2xl font-bold bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent" 
                         :class="{ 'animate-pulse': loading }"
                         x-text="formatNumber(stats.totalQueries)">--</div>
                    <div class="text-xs text-gray-500 mt-1" x-text="stats.queriesRate">-- q/min</div>
                </div>
                <!-- Blocked -->
                <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg p-4 hover:bg-gray-800/70 transition-colors">
                    <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Blocked</div>
                    <div class="text-2xl font-bold bg-gradient-to-r bg-clip-text text-transparent" 
                         :class="getBlockedGradient()"
                         x-text="stats.blockedPercent">--%</div>
                    <div class="text-xs text-gray-500 mt-1" x-text="formatNumber(stats.blockedQueries) + ' queries'">-- queries</div>
                </div>
                <!-- Cache Hit Rate -->
                <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg p-4 hover:bg-gray-800/70 transition-colors">
                    <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Cache Hit Rate</div>
                    <div class="text-2xl font-bold bg-gradient-to-r bg-clip-text text-transparent"
                         :class="getCacheGradient()"
                         x-text="stats.cacheHitRate">--%</div>
                </div>
                <!-- Block Lists -->
                <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg p-4 hover:bg-gray-800/70 transition-colors">
                    <div class="text-xs font-medium text-gray-400 uppercase tracking-wider mb-2">Block Lists</div>
                    <div class="flex flex-wrap gap-1 justify-center mt-2">
                        <template x-for="(count, list) in stats.blockingLists" :key="list">
                            <div class="px-2 py-1 bg-red-500/20 border border-red-500/30 rounded-full text-[10px] text-red-300">
                                <span x-text="`${list}: ${formatNumber(count)}`"></span>
                            </div>
                        </template>
                        <div x-show="Object.keys(stats.blockingLists).length === 0" 
                             class="text-xs text-gray-500">No data</div>
                    </div>
                </div>
            </div>
            <!-- Top Clients -->
            <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg p-4">
                <h4 class="text-sm font-medium text-gray-300 mb-3 flex items-center">
                    <i class="lni lni-users text-purple-400 mr-2 text-xs"></i>
                    Top DNS Clients
                </h4>
                <div class="space-y-2">
                    <template x-for="client in stats.topClients" :key="client.ip">
                        <div class="flex justify-between items-center p-2 bg-gray-700/30 rounded-md hover:bg-gray-700/50 transition-colors">
                            <span class="text-sm text-gray-200 truncate flex-1" x-text="client.hostname || client.ip"></span>
                            <span class="text-sm font-mono text-cyan-400 ml-3" x-text="formatNumber(client.queries)"></span>
                        </div>
                    </template>
                    <div x-show="stats.topClients.length === 0" 
                         class="text-center text-sm text-gray-500 py-2">No DNS data available</div>
                </div>
            </div>
        </div>

        <!-- Services -->
        <div x-data="servicesApp" x-init="init()" class="bg-gray-900/30 border border-gray-800 rounded-2xl backdrop-blur-sm p-6 mb-10">
            <h3 class="text-lg font-semibold text-white mb-4 flex items-center">
                <i class="lni lni-apps text-cyan-400 mr-2"></i>
                Services
            </h3>
            <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-3">
                <template x-for="service in services" :key="service.name">
                    <a :href="service.url" 
                       class="group bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-xl p-4 text-center hover:bg-gray-800/70 hover:border-cyan-500/50 hover:scale-105 transition-all duration-200 block">
                        <i class="lni text-2xl mb-2 block text-cyan-400 opacity-80 group-hover:opacity-100 transition-opacity" 
                           :class="service.icon"></i>
                        <div class="text-xs font-medium text-gray-300 group-hover:text-white transition-colors" 
                             x-text="service.name"></div>
                    </a>
                </template>
            </div>
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
        
        // Alpine.js components
        document.addEventListener('alpine:init', () => {
            // Stats component for top cards
            Alpine.data('statsApp', () => ({
                loading: true,
                stats: {
                    connectivity: {
                        status: null,
                        status_text: '--',
                        ping: '-- ms avg'
                    },
                    uptime: '--',
                    cpu: {
                        load: '--',
                        info: '-- cores'
                    },
                    memory: {
                        percent: '--%',
                        info: '--'
                    },
                    clientCount: '--'
                },
                
                init() {
                    // Subscribe to metrics updates
                    metricsStore.subscribe((data) => {
                        this.updateStats(data);
                    });
                },
                
                updateStats(data) {
                    this.loading = false;
                    
                    // Update connectivity
                    if (data.connectivity) {
                        this.stats.connectivity.status = data.connectivity.status;
                        this.stats.connectivity.status_text = data.connectivity.status_text || 'Unknown';
                        this.stats.connectivity.ping = data.connectivity.avg_response_time !== null 
                            ? `${data.connectivity.avg_response_time} ms avg` 
                            : 'No response';
                    }
                    
                    // Update uptime
                    if (data.uptime) {
                        this.stats.uptime = data.uptime.formatted || '--';
                    }
                    
                    // Update CPU
                    if (data.cpu) {
                        this.stats.cpu.load = data.cpu.load_1 ? data.cpu.load_1.toFixed(2) : '--';
                        this.stats.cpu.info = `${data.cpu.cores || '--'} cores | ${data.cpu.usage_percent || '--'}% usage`;
                    }
                    
                    // Update memory
                    if (data.memory) {
                        this.stats.memory.percent = `${data.memory.percent || '--'}%`;
                        if (data.memory.formatted) {
                            this.stats.memory.info = `${data.memory.formatted.used} / ${data.memory.formatted.total}`;
                        }
                    }
                    
                    // Update client count
                    if (data.clients) {
                        this.stats.clientCount = data.clients.count || 0;
                    }
                },
                
                getConnectivityClasses() {
                    const status = this.stats.connectivity.status;
                    if (this.loading) return 'from-cyan-400 to-blue-500 animate-pulse';
                    
                    switch(status) {
                        case 'online':
                            return 'from-green-400 to-emerald-500';
                        case 'offline':
                            return 'from-red-400 to-rose-500';
                        case 'partial':
                            return 'from-amber-400 to-yellow-500';
                        default:
                            return 'from-cyan-400 to-blue-500';
                    }
                },
                
                getCpuLoadClasses() {
                    if (this.loading) return 'from-cyan-400 to-blue-500 animate-pulse';
                    
                    const load = parseFloat(this.stats.cpu.load);
                    if (isNaN(load)) return 'from-cyan-400 to-blue-500';
                    
                    // Assuming 4 cores average, adjust thresholds
                    if (load > 8) return 'from-red-400 to-rose-500';
                    if (load > 4) return 'from-amber-400 to-yellow-500';
                    if (load > 2) return 'from-cyan-400 to-blue-500';
                    return 'from-green-400 to-emerald-500';
                },
                
                getMemoryClasses() {
                    if (this.loading) return 'from-cyan-400 to-blue-500 animate-pulse';
                    
                    const percent = parseFloat(this.stats.memory.percent);
                    if (isNaN(percent)) return 'from-cyan-400 to-blue-500';
                    
                    if (percent > 90) return 'from-red-400 to-rose-500';
                    if (percent > 75) return 'from-amber-400 to-yellow-500';
                    if (percent > 50) return 'from-cyan-400 to-blue-500';
                    return 'from-green-400 to-emerald-500';
                }
            }));
            
            // Network component
            Alpine.data('networkApp', () => ({
                loading: true,
                network: {
                    wanIp: '--',
                    lanNetwork: '--',
                    interfaces: {
                        brLan: {
                            rx: 'RX: --',
                            tx: 'TX: --'
                        },
                        tailscale: {
                            rx: 'RX: --',
                            tx: 'TX: --'
                        }
                    }
                },
                
                init() {
                    // Subscribe to metrics updates
                    metricsStore.subscribe((data) => {
                        this.updateNetwork(data);
                    });
                },
                
                updateNetwork(data) {
                    this.loading = false;
                    
                    if (data.network) {
                        // Update WAN IP
                        this.network.wanIp = data.network.wan_ip || 'unknown';
                        
                        // Update LAN Network
                        if (data.network.lan_network) {
                            this.network.lanNetwork = data.network.lan_network.cidr || '10.1.1.0/24';
                        }
                        
                        // Update interface stats
                        if (data.network.interfaces) {
                            if (data.network.interfaces['br-lan']) {
                                const stats = data.network.interfaces['br-lan'];
                                this.network.interfaces.brLan.rx = `RX: ${stats.formatted.rx}`;
                                this.network.interfaces.brLan.tx = `TX: ${stats.formatted.tx}`;
                            }
                            
                            if (data.network.interfaces.tailscale0) {
                                const stats = data.network.interfaces.tailscale0;
                                this.network.interfaces.tailscale.rx = `RX: ${stats.formatted.rx}`;
                                this.network.interfaces.tailscale.tx = `TX: ${stats.formatted.tx}`;
                            }
                        }
                    }
                }
            }));
            
            // Clients component
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
            
            // DNS Statistics component
            Alpine.data('dnsApp', () => ({
                loading: true,
                stats: {
                    totalQueries: 0,
                    blockedQueries: 0,
                    blockedPercent: '--%',
                    queriesRate: '-- q/min',
                    cacheHitRate: '--%',
                    topClients: [],
                    blockingLists: {}
                },
                
                init() {
                    // Subscribe to metrics updates
                    metricsStore.subscribe((data) => {
                        this.updateStats(data);
                    });
                },
                
                updateStats(data) {
                    this.loading = false;
                    
                    if (data.blocky && data.blocky.enabled) {
                        this.stats.totalQueries = data.blocky.total_queries || 0;
                        this.stats.blockedQueries = data.blocky.blocked_queries || 0;
                        this.stats.blockedPercent = `${data.blocky.block_percentage || 0}%`;
                        this.stats.queriesRate = `${data.blocky.queries_per_minute || 0} q/min`;
                        this.stats.cacheHitRate = `${data.blocky.cache_hit_rate || 0}%`;
                        this.stats.topClients = data.blocky.top_clients || [];
                        this.stats.blockingLists = data.blocky.blocking_lists || {};
                    }
                },
                
                formatNumber(num) {
                    if (num === undefined || num === null) return '--';
                    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
                    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
                    return num.toLocaleString();
                },
                
                getBlockedGradient() {
                    if (this.loading) return 'from-cyan-400 to-blue-500 animate-pulse';
                    
                    const percent = parseFloat(this.stats.blockedPercent);
                    if (isNaN(percent)) return 'from-cyan-400 to-blue-500';
                    
                    if (percent > 50) return 'from-red-400 to-rose-500';
                    if (percent > 30) return 'from-amber-400 to-yellow-500';
                    if (percent > 10) return 'from-cyan-400 to-blue-500';
                    return 'from-green-400 to-emerald-500';
                },
                
                getCacheGradient() {
                    if (this.loading) return 'from-cyan-400 to-blue-500 animate-pulse';
                    
                    const percent = parseFloat(this.stats.cacheHitRate);
                    if (isNaN(percent)) return 'from-cyan-400 to-blue-500';
                    
                    if (percent > 80) return 'from-green-400 to-emerald-500';
                    if (percent > 60) return 'from-cyan-400 to-blue-500';
                    if (percent > 40) return 'from-amber-400 to-yellow-500';
                    return 'from-red-400 to-rose-500';
                }
            }));
            
            // Services component
            Alpine.data('servicesApp', () => ({
                services: [
                    {
                        name: 'Metrics',
                        icon: 'lni-stats-up',
                        url: '/grafana/d/router-metrics/router-metrics?kiosk&theme=sapphire-dusk'
                    },
                    {
                        name: 'Grafana',
                        icon: 'lni-bar-chart',
                        url: '/grafana'
                    },
                    {
                        name: 'VictoriaMetrics',
                        icon: 'lni-database',
                        url: '/victoriametrics'
                    },
                    {
                        name: 'Alertmanager',
                        icon: 'lni-alarm',
                        url: '/alertmanager'
                    },
                    {
                        name: 'System Logs',
                        icon: 'lni-files',
                        url: '/logs/'
                    },
                    {
                        name: 'VPN Manager',
                        icon: 'lni-shield',
                        url: '/vpn-manager'
                    }
                ],
                
                init() {
                    // Services are static, no need to subscribe to updates
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

class ClientInfoCache:
    """Cache for client information from network-metrics-exporter"""
    def __init__(self, ttl_seconds=30):
        self.cache = {}
        self.ttl = ttl_seconds
        self.lock = threading.Lock()
        self.last_update = 0
    
    def get_clients(self):
        """Get client information from VictoriaMetrics"""
        with self.lock:
            # Check if cache is still valid
            if time.time() - self.last_update < self.ttl and self.cache:
                return self.cache
            
            try:
                # Query client status from network-metrics-exporter
                clients = {}
                
                # Get client status (online/offline)
                status_query = 'client_status'
                url = f"http://localhost:8428/api/v1/query?query={urllib.parse.quote(status_query)}"
                with urllib.request.urlopen(url, timeout=2) as response:
                    data = json.loads(response.read().decode())
                    if data.get('status') == 'success' and data.get('data', {}).get('result'):
                        for item in data['data']['result']:
                            metric = item['metric']
                            ip = metric.get('ip', '')
                            if ip:
                                clients[ip] = {
                                    'ip': ip,
                                    'hostname': metric.get('client', 'unknown'),
                                    'device_type': metric.get('device_type', 'unknown'),
                                    'status': float(item['value'][1]) > 0
                                }
                
                # Get active connections per client
                conn_query = 'client_active_connections'
                url = f"http://localhost:8428/api/v1/query?query={urllib.parse.quote(conn_query)}"
                with urllib.request.urlopen(url, timeout=2) as response:
                    data = json.loads(response.read().decode())
                    if data.get('status') == 'success' and data.get('data', {}).get('result'):
                        for item in data['data']['result']:
                            ip = item['metric'].get('ip', '')
                            if ip and ip in clients:
                                clients[ip]['connections'] = int(float(item['value'][1]))
                
                self.cache = clients
                self.last_update = time.time()
                return clients
            except Exception as e:
                print(f"Error getting client info from metrics: {e}")
                return self.cache  # Return stale cache on error

# Global cache instances
metrics_cache = MetricsCache(ttl_seconds=5)  # Cache metrics for 5 seconds
connectivity_cache = MetricsCache(ttl_seconds=30)  # Cache connectivity for 30 seconds
blocky_cache = MetricsCache(ttl_seconds=10)  # Cache Blocky stats for 10 seconds
client_info_cache = ClientInfoCache(ttl_seconds=30)  # Cache client info from network-metrics-exporter

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
    
    def get_device_type_from_exporter(self, ip: str) -> str:
        """Get device type from network-metrics-exporter data"""
        clients = client_info_cache.get_clients()
        if ip in clients:
            return clients[ip].get('device_type', 'unknown')
        return 'unknown'
    
    def get_device_icon(self, device_type: str) -> str:
        """Get Lineicon class for device type"""
        icons = {
            'phone': 'lni-mobile',
            'tablet': 'lni-tab',
            'laptop': 'lni-laptop',
            'computer': 'lni-display-alt',
            'desktop': 'lni-display-alt',
            'media': 'lni-display',
            'tv': 'lni-display',
            'gaming': 'lni-game',
            'game-console': 'lni-game',
            'iot': 'lni-volume-high',
            'smart-speaker': 'lni-volume-high',
            'printer': 'lni-printer',
            'server': 'lni-server',
            'network': 'lni-network',
            'router': 'lni-network',
            'camera': 'lni-camera',
            'watch': 'lni-timer',
            'unknown': 'lni-help',
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
        """Get connected clients from network-metrics-exporter and ARP table"""
        start = time.time()
        clients = []
        seen_ips = set()
        
        # Get bandwidth data from VictoriaMetrics
        bandwidth_data = self.get_client_bandwidth_rates()
        
        # Get client info from network-metrics-exporter
        exporter_clients = client_info_cache.get_clients()
        
        # Read ARP table for MAC addresses and state
        arp_data = {}
        try:
            with open('/proc/net/arp', 'r') as f:
                lines = f.readlines()[1:]  # Skip header
                
            for line in lines:
                parts = line.split()
                if len(parts) >= 6:
                    ip = parts[0]
                    flags = parts[2]
                    mac = parts[3].lower()
                    device = parts[5]
                    
                    # Check if it's on br-lan
                    if device == 'br-lan' and mac != '00:00:00:00:00:00' and flags != '0x0':
                        arp_data[ip] = {
                            'mac': mac,
                            'state': 'REACHABLE' if flags in ['0x2', '0x6'] else 'STALE'
                        }
        except Exception as e:
            print(f"Error reading ARP table: {e}")
        
        # Combine data from all sources
        for ip, arp_info in arp_data.items():
            # Get hostname and device type from exporter
            if ip in exporter_clients:
                hostname = exporter_clients[ip].get('hostname', 'unknown')
                device_type = exporter_clients[ip].get('device_type', 'unknown')
                status = exporter_clients[ip].get('status', False)
            else:
                # Fallback to IP as hostname
                hostname = ip
                device_type = 'unknown'
                status = True  # Assume online if in ARP table
            
            # Get bandwidth info
            bw_info = bandwidth_data.get(ip, {})
            
            # Determine state - prefer ARP state, but mark as 'FAILED' if offline in exporter
            state = arp_info['state']
            if not status:
                state = 'FAILED'
            
            clients.append({
                'ip': ip,
                'mac': arp_info['mac'],
                'hostname': hostname,
                'device_type': device_type,
                'icon': self.get_device_icon(device_type),
                'source': 'arp',
                'state': state,
                'bandwidth_rx_bps': bw_info.get('rx_bps', 0),
                'bandwidth_tx_bps': bw_info.get('tx_bps', 0),
                'bandwidth_rx_formatted': bw_info.get('rx_formatted', '0 bps'),
                'bandwidth_tx_formatted': bw_info.get('tx_formatted', '0 bps')
            })
            seen_ips.add(ip)
        
        # Add any clients from exporter that aren't in ARP (recently disconnected)
        for ip, client_info in exporter_clients.items():
            if ip not in seen_ips:
                bw_info = bandwidth_data.get(ip, {})
                clients.append({
                    'ip': ip,
                    'mac': 'unknown',
                    'hostname': client_info.get('hostname', ip),
                    'device_type': client_info.get('device_type', 'unknown'),
                    'icon': self.get_device_icon(client_info.get('device_type', 'unknown')),
                    'source': 'exporter',
                    'state': 'STALE' if client_info.get('status') else 'FAILED',
                    'bandwidth_rx_bps': bw_info.get('rx_bps', 0),
                    'bandwidth_tx_bps': bw_info.get('tx_bps', 0),
                    'bandwidth_rx_formatted': bw_info.get('rx_formatted', '0 bps'),
                    'bandwidth_tx_formatted': bw_info.get('tx_formatted', '0 bps')
                })
                seen_ips.add(ip)
        
        total_time = round((time.time() - start) * 1000, 1)
        
        # Log if slow
        if total_time > 100:  # More than 100ms
            print(f"get_connected_clients took: {total_time}ms")
        
        return {
            'count': len(clients),
            'clients': clients[:20],  # Limit to 20 for display
            '_debug_timing': total_time
        }
    
    
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