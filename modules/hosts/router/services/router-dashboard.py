#!/usr/bin/env python3

import argparse
import json
import logging
import os
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.parse
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Dict, Any, Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stderr)
    ]
)
logger = logging.getLogger('router-dashboard')

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
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
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
                        :class="allGraphsExpanded 
                            ? 'bg-purple-500/20 border-purple-500/50 text-purple-400' 
                            : 'bg-gray-800/50 border-gray-700/50 text-gray-400 hover:bg-gray-700/50 hover:text-white'"
                        @click="toggleAllGraphs()">
                        <i class="lni lni-stats-up text-[10px]"></i>
                        <span x-text="allGraphsExpanded ? 'Hide All Graphs' : 'Show All Graphs'">Show All Graphs</span>
                    </button>
                    <button 
                        x-show="Object.keys(expandedGraphs).filter(ip => expandedGraphs[ip]).length > 0"
                        class="px-3 py-1.5 text-xs font-medium rounded-md border transition-all duration-200 flex items-center gap-1"
                        :class="useUnifiedScale 
                            ? 'bg-blue-500/20 border-blue-500/50 text-blue-400' 
                            : 'bg-gray-800/50 border-gray-700/50 text-gray-400 hover:bg-gray-700/50 hover:text-white'"
                        @click="toggleUnifiedScale()">
                        <i class="lni lni-ruler text-[10px]"></i>
                        <span x-text="useUnifiedScale ? 'Unified Scale' : 'Auto Scale'">Unified Scale</span>
                    </button>
                    <select 
                        x-show="Object.keys(expandedGraphs).filter(ip => expandedGraphs[ip]).length > 0"
                        x-model="timeRange"
                        @change="onTimeRangeChange()"
                        class="px-3 py-1.5 text-xs font-medium rounded-md border bg-gray-800/50 border-gray-700/50 text-gray-300 hover:bg-gray-700/50 hover:text-white transition-all duration-200 cursor-pointer">
                        <template x-for="range in availableTimeRanges" :key="range.value">
                            <option :value="range.value" x-text="range.label"></option>
                        </template>
                    </select>
                    <div class="w-px bg-gray-700"></div>
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
                    <div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg overflow-hidden">
                        <!-- Client info row -->
                        <div class="flex items-center p-3 hover:bg-gray-800/70 transition-all duration-200">
                            <i class="lni text-xl mr-3 text-cyan-400 opacity-60" :class="client.icon || 'lni-mobile'"></i>
                            <div class="flex-1 min-w-0">
                                <div class="font-medium text-white text-sm truncate" x-text="getClientName(client)"></div>
                                <div class="text-xs text-gray-400 truncate">
                                    <span x-text="client.ip"></span>
                                    <span class="text-gray-500" x-show="client.mac && client.mac !== 'unknown'"> • <span x-text="client.mac.toUpperCase()"></span></span>
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
                            <!-- Graph toggle button -->
                            <button class="ml-3 p-1.5 rounded-md bg-gray-700/50 hover:bg-gray-700 transition-colors"
                                    :class="{'bg-cyan-500/20 border-cyan-500/50': expandedGraphs[client.ip]}"
                                    @click="toggleClientGraph(client.ip)">
                                <i class="lni lni-stats-up text-sm" 
                                   :class="expandedGraphs[client.ip] ? 'text-cyan-400' : 'text-gray-400'"></i>
                            </button>
                            <div class="ml-2 w-2 h-2 rounded-full flex-shrink-0"
                                 :class="{
                                    'bg-green-400 shadow-[0_0_8px_rgba(74,222,128,0.6)] animate-pulse': (client.state || '').toLowerCase() === 'reachable',
                                    'bg-yellow-400 shadow-[0_0_6px_rgba(251,191,36,0.6)]': (client.state || '').toLowerCase() === 'stale',
                                    'bg-gray-600': (client.state || '').toLowerCase() === 'failed' || (client.state || '').toLowerCase() === 'unknown'
                                 }"
                                 :title="client.state || 'unknown'"></div>
                        </div>
                        <!-- Expandable graph section - spans full width of card -->
                        <div x-show="expandedGraphs[client.ip]" 
                             x-transition:enter="transition ease-out duration-300"
                             x-transition:enter-start="opacity-0 transform scale-95"
                             x-transition:enter-end="opacity-100 transform scale-100"
                             x-transition:leave="transition ease-in duration-200"
                             x-transition:leave-start="opacity-100 transform scale-100"
                             x-transition:leave-end="opacity-0 transform scale-95"
                             class="border-t border-gray-700/50 p-4 bg-gray-900/50">
                            <div class="flex justify-between items-center mb-2">
                                <div class="text-xs text-gray-400">Auto-refreshing every 5 seconds</div>
                                <button @click="refreshChart(client.ip)" 
                                        class="px-2 py-1 text-xs bg-gray-700/50 hover:bg-gray-700 border border-gray-600 rounded transition-colors flex items-center gap-1">
                                    <i class="lni lni-reload text-[10px]"></i>
                                    <span>Refresh Now</span>
                                </button>
                            </div>
                            <div class="h-48 relative">
                                <canvas :id="'bandwidth-chart-' + client.ip.replace(/\\./g, '-')"></canvas>
                                <div x-show="loadingGraphs[client.ip]" 
                                     class="absolute inset-0 flex items-center justify-center bg-gray-900/75">
                                    <div class="text-cyan-400">
                                        <i class="lni lni-spinner-arrow animate-spin text-2xl"></i>
                                        <p class="text-xs mt-2">Loading bandwidth history...</p>
                                    </div>
                                </div>
                            </div>
                        </div>
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
        
        // Chart instances stored outside of Alpine's reactive scope to prevent conflicts
        const chartInstances = {};
        
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
                sortField: 'bandwidth',
                sortDirection: 'desc',
                expandedGraphs: {},
                // charts: {}, // Removed - now using external chartInstances
                allGraphsExpanded: false,
                loadingGraphs: {},
                updateInterval: null,  // Store interval ID for cleanup
                useUnifiedScale: true,  // Use same scale for all charts
                unifiedMaxValue: 0,  // Maximum value across all charts
                timeRange: '10m',  // Default time range for charts
                availableTimeRanges: [
                    { value: '5m', label: '5 min' },
                    { value: '10m', label: '10 min' },
                    { value: '30m', label: '30 min' },
                    { value: '1h', label: '1 hour' },
                    { value: '3h', label: '3 hours' },
                    { value: '6h', label: '6 hours' },
                    { value: '12h', label: '12 hours' },
                    { value: '24h', label: '24 hours' },
                    { value: '48h', label: '2 days' },
                    { value: '72h', label: '3 days' },
                    { value: '168h', label: '1 week' }
                ],
                
                init() {
                    // Subscribe to metrics updates
                    metricsStore.subscribe((data) => {
                        if (data.clients && data.clients.clients) {
                            this.clients = data.clients.clients;
                        }
                    });
                    
                    // Set up periodic chart updates (every 5 seconds)
                    this.updateInterval = setInterval(() => {
                        this.updateAllCharts();
                    }, 5000);
                    
                    // Cleanup on component destroy
                    this.$watch('$destroy', () => {
                        if (this.updateInterval) {
                            clearInterval(this.updateInterval);
                        }
                        // Destroy all charts
                        Object.keys(chartInstances).forEach(ip => {
                            if (chartInstances[ip]) {
                                try {
                                    chartInstances[ip].destroy();
                                } catch (e) {
                                    console.warn(`Error destroying chart for ${ip}:`, e);
                                }
                                delete chartInstances[ip];
                            }
                        });
                    });
                },
                
                calculateUnifiedScale(allHistories) {
                    // Calculate the maximum value across all charts
                    let maxValue = 0;
                    
                    for (const history of Object.values(allHistories)) {
                        if (!history || history.error) continue;
                        
                        // Find max in rx data
                        if (history.rx && Array.isArray(history.rx)) {
                            const maxRx = Math.max(...history.rx.filter(v => !isNaN(v)));
                            if (!isNaN(maxRx)) maxValue = Math.max(maxValue, maxRx);
                        }
                        
                        // Find max in tx data
                        if (history.tx && Array.isArray(history.tx)) {
                            const maxTx = Math.max(...history.tx.filter(v => !isNaN(v)));
                            if (!isNaN(maxTx)) maxValue = Math.max(maxValue, maxTx);
                        }
                    }
                    
                    // Add 10% padding to the top
                    this.unifiedMaxValue = maxValue * 1.1;
                    
                    // Round up to nice values for better readability
                    if (this.unifiedMaxValue > 1000000000) {
                        // Round up to nearest 100 Mbps for Gbps range
                        this.unifiedMaxValue = Math.ceil(this.unifiedMaxValue / 100000000) * 100000000;
                    } else if (this.unifiedMaxValue > 1000000) {
                        // Round up to nearest 10 Mbps for Mbps range
                        this.unifiedMaxValue = Math.ceil(this.unifiedMaxValue / 10000000) * 10000000;
                    } else if (this.unifiedMaxValue > 1000) {
                        // Round up to nearest 100 Kbps for Kbps range
                        this.unifiedMaxValue = Math.ceil(this.unifiedMaxValue / 100000) * 100000;
                    }
                    
                    console.log(`[SCALE] Unified max value: ${formatBandwidth(this.unifiedMaxValue)}`);
                },
                
                updateChartScale(chart) {
                    // Update chart's y-axis scale
                    if (this.useUnifiedScale && this.unifiedMaxValue > 0) {
                        chart.options.scales.y.max = this.unifiedMaxValue;
                        chart.options.scales.y.min = 0;
                    } else {
                        // Auto scale
                        delete chart.options.scales.y.max;
                        delete chart.options.scales.y.min;
                    }
                },
                
                async updateAllCharts() {
                    // Update all visible charts with latest data
                    const expandedIps = Object.keys(this.expandedGraphs).filter(ip => this.expandedGraphs[ip]);
                    
                    if (expandedIps.length === 0) return;
                    
                    try {
                        // Batch fetch only the histories we need with time range
                        const response = await fetch(`/api/client-histories?ips=${expandedIps.join(',')}&duration=${this.timeRange}`);
                        if (!response.ok) {
                            console.error('Failed to fetch batch histories');
                            return;
                        }
                        
                        const allHistories = await response.json();
                        
                        // Calculate unified scale if enabled
                        if (this.useUnifiedScale) {
                            this.calculateUnifiedScale(allHistories);
                        }
                        
                        // Update each chart with its data
                        for (const ip of expandedIps) {
                            const history = allHistories[ip];
                            if (!history || history.error) continue;
                            
                            const chart = chartInstances[ip];
                            if (!chart || chart._destroyed) continue;
                            
                            // Clear existing data
                            chart.data.labels.length = 0;
                            chart.data.datasets[0].data.length = 0;
                            chart.data.datasets[1].data.length = 0;
                            
                            // Add new data
                            chart.data.labels.push(...history.labels);
                            chart.data.datasets[0].data.push(...history.rx);
                            chart.data.datasets[1].data.push(...history.tx);
                            
                            // Update scale if unified
                            this.updateChartScale(chart);
                            
                            // Update chart without animation for smooth updates
                            chart.update('none');
                        }
                    } catch (error) {
                        console.error('Error updating charts:', error);
                        // Fallback to individual updates
                        for (const ip of expandedIps) {
                            if (chartInstances[ip] && !chartInstances[ip]._destroyed) {
                                await this.updateChartData(ip);
                            }
                        }
                    }
                },
                
                async updateChartData(ip) {
                    // Update chart with latest data without recreating it
                    try {
                        const response = await fetch(`/api/client-histories?ips=${ip}&duration=${this.timeRange}`);
                        if (!response.ok) return;
                        
                        const histories = await response.json();
                        const history = histories[ip];
                        if (!history || history.error) return;
                        
                        const chart = chartInstances[ip];
                        if (!chart || chart._destroyed) return;
                        
                        // Clear existing data
                        chart.data.labels.length = 0;
                        chart.data.datasets[0].data.length = 0;
                        chart.data.datasets[1].data.length = 0;
                        
                        // Add new data
                        chart.data.labels.push(...history.labels);
                        chart.data.datasets[0].data.push(...history.rx);
                        chart.data.datasets[1].data.push(...history.tx);
                        
                        // Update chart without animation for smooth updates
                        chart.update('none');
                    } catch (error) {
                        console.error(`Error updating chart for ${ip}:`, error);
                    }
                },
                
                async refreshChart(ip) {
                    console.log(`[REFRESH] Manual refresh requested for IP: ${ip}`);
                    
                    try {
                        // Fetch fresh data using batch endpoint with time range
                        const response = await fetch(`/api/client-histories?ips=${ip}&duration=${this.timeRange}`);
                        if (!response.ok) {
                            console.error('Failed to refresh chart for IP:', ip);
                            return;
                        }
                        
                        const histories = await response.json();
                        const history = histories[ip];
                        if (!history || history.error) {
                            console.error('No valid history data for IP:', ip);
                            return;
                        }
                        
                        if (chartInstances[ip] && !chartInstances[ip]._destroyed) {
                            // Update existing chart
                            const chart = chartInstances[ip];
                            
                            // Clear and update data
                            chart.data.labels.length = 0;
                            chart.data.datasets[0].data.length = 0;
                            chart.data.datasets[1].data.length = 0;
                            
                            chart.data.labels.push(...history.labels);
                            chart.data.datasets[0].data.push(...history.rx);
                            chart.data.datasets[1].data.push(...history.tx);
                            
                            // Force update with animation for manual refresh
                            chart.update();
                        } else {
                            // Chart doesn't exist, create it
                            this.fetchAndCreateChart(ip);
                        }
                    } catch (error) {
                        console.error('Error refreshing chart for IP:', ip, error);
                    }
                },
                
                toggleClientGraph(ip) {
                    console.log(`[TOGGLE] Toggling graph for IP: ${ip}, current state: ${this.expandedGraphs[ip]}`);
                    this.expandedGraphs[ip] = !this.expandedGraphs[ip];
                    
                    if (this.expandedGraphs[ip]) {
                        console.log(`[TOGGLE] Expanding graph for IP: ${ip}`);
                        // Use Alpine's nextTick to ensure DOM is ready
                        this.$nextTick(() => {
                            // Additional delay for transition to complete
                            setTimeout(() => {
                                console.log(`[TOGGLE] Creating chart for IP: ${ip}`);
                                this.fetchAndCreateChart(ip);
                            }, 100);
                        });
                    } else if (chartInstances[ip]) {
                        console.log(`[TOGGLE] Collapsing graph for IP: ${ip}, destroying chart`);
                        // Destroy chart when closing
                        try {
                            chartInstances[ip].destroy();
                            console.log(`[TOGGLE] Successfully destroyed chart for IP: ${ip}`);
                        } catch (e) {
                            console.warn(`[TOGGLE] Error destroying chart for IP: ${ip}:`, e);
                        }
                        delete chartInstances[ip];
                        delete this.loadingGraphs[ip];
                    }
                },
                
                createChartFromData(ip, history) {
                    const canvasId = 'bandwidth-chart-' + ip.replace(/\\./g, '-');
                    const canvas = document.getElementById(canvasId);
                    console.log(`[CREATE] Creating chart for IP: ${ip}, canvas: ${canvasId}, exists: ${!!canvas}`);
                    
                    if (!canvas) {
                        console.error(`[CREATE] Canvas not found for IP: ${ip}, ID: ${canvasId}`);
                        return;
                    }
                    
                    // Destroy existing chart if any
                    if (chartInstances[ip]) {
                        console.log(`[CREATE] Destroying existing chart for IP: ${ip} before creating new one`);
                        chartInstances[ip].destroy();
                        delete chartInstances[ip];
                    }
                    
                    // Calculate scale for this chart if unified scale is enabled
                    const scaleOptions = {};
                    if (this.useUnifiedScale && this.unifiedMaxValue > 0) {
                        scaleOptions.max = this.unifiedMaxValue;
                        scaleOptions.min = 0;
                    }
                    
                    // Create new chart with provided data
                    try {
                        chartInstances[ip] = new Chart(canvas, {
                        type: 'line',
                        data: {
                            labels: history.labels,
                            datasets: [
                                {
                                    label: 'Download',
                                    data: history.rx,
                                    borderColor: 'rgb(34, 211, 238)',
                                    backgroundColor: 'rgba(34, 211, 238, 0.1)',
                                    borderWidth: 2,
                                    tension: 0.4,
                                    fill: true
                                },
                                {
                                    label: 'Upload',
                                    data: history.tx,
                                    borderColor: 'rgb(52, 211, 153)',
                                    backgroundColor: 'rgba(52, 211, 153, 0.1)',
                                    borderWidth: 2,
                                    tension: 0.4,
                                    fill: true
                                }
                            ]
                        },
                        options: {
                            responsive: true,
                            maintainAspectRatio: false,
                            interaction: {
                                intersect: false,
                                mode: 'index'
                            },
                            plugins: {
                                legend: {
                                    display: true,
                                    position: 'top',
                                    labels: {
                                        color: '#9CA3AF',
                                        font: {
                                            size: 11
                                        },
                                        boxWidth: 12,
                                        boxHeight: 12
                                    }
                                },
                                tooltip: {
                                    callbacks: {
                                        label: function(context) {
                                            let label = context.dataset.label || '';
                                            if (label) {
                                                label += ': ';
                                            }
                                            label += formatBandwidth(context.parsed.y);
                                            return label;
                                        }
                                    }
                                }
                            },
                            scales: {
                                x: {
                                    display: true,
                                    grid: {
                                        color: 'rgba(255, 255, 255, 0.05)',
                                        drawBorder: false
                                    },
                                    ticks: {
                                        color: '#6B7280',
                                        font: {
                                            size: 10
                                        },
                                        maxRotation: 0,
                                        autoSkip: true,
                                        maxTicksLimit: 8
                                    }
                                },
                                y: {
                                    display: true,
                                    grid: {
                                        color: 'rgba(255, 255, 255, 0.05)',
                                        drawBorder: false
                                    },
                                    ticks: {
                                        color: '#6B7280',
                                        font: {
                                            size: 10
                                        },
                                        callback: function(value) {
                                            return formatBandwidth(value);
                                        }
                                    },
                                    ...scaleOptions  // Apply unified scale if set
                                }
                            }
                        }
                    });
                        console.log(`[CREATE] Successfully created chart for IP: ${ip}`);
                    } catch (error) {
                        console.error(`[CREATE] Failed to create chart for IP: ${ip}:`, error);
                        delete chartInstances[ip];
                    }
                },
                
                async fetchAndCreateChart(ip) {
                    const canvasId = 'bandwidth-chart-' + ip.replace(/\\./g, '-');
                    const canvas = document.getElementById(canvasId);
                    console.log(`[FETCH_CREATE] Starting chart creation for IP: ${ip}, canvas: ${canvasId}`);
                    
                    if (!canvas) {
                        console.error(`[FETCH_CREATE] Canvas not found for IP: ${ip}, ID: ${canvasId}`);
                        return;
                    }
                    
                    // Mark as just created to skip immediate updates
                    this.justCreatedCharts = this.justCreatedCharts || {};
                    this.justCreatedCharts[ip] = true;
                    setTimeout(() => {
                        delete this.justCreatedCharts[ip];
                        console.log(`[FETCH_CREATE] Chart for ${ip} is now ready for updates`);
                    }, 5000); // Wait 5 seconds before allowing updates
                    
                    // Show loading state
                    this.loadingGraphs[ip] = true;
                    
                    try {
                        // If unified scale is enabled and we need to calculate it
                        let ips = ip;
                        if (this.useUnifiedScale) {
                            // Get all expanded IPs to calculate unified scale
                            const expandedIps = Object.keys(this.expandedGraphs).filter(ip => this.expandedGraphs[ip]);
                            if (expandedIps.length > 0) {
                                ips = expandedIps.join(',');
                            }
                        }
                        
                        // Fetch history from server with time range
                        const response = await fetch(`/api/client-histories?ips=${ips}&duration=${this.timeRange}`);
                        
                        // Check if response is OK
                        if (!response.ok) {
                            console.error('Failed to fetch history for IP:', ip, 'Status:', response.status);
                            this.loadingGraphs[ip] = false;
                            return;
                        }
                        
                        const histories = await response.json();
                        
                        // Calculate unified scale if needed
                        if (this.useUnifiedScale && Object.keys(histories).length > 0) {
                            this.calculateUnifiedScale(histories);
                        }
                        
                        const history = histories[ip];
                        
                        if (!history || history.error) {
                            console.error('Error fetching history for IP:', ip, history?.error || 'No data');
                            this.loadingGraphs[ip] = false;
                            return;
                        }
                        
                        // Destroy existing chart if any
                        if (chartInstances[ip]) {
                            chartInstances[ip].destroy();
                            delete chartInstances[ip];
                        }
                        
                        // Create new chart with server data
                        chartInstances[ip] = new Chart(canvas, {
                            type: 'line',
                            data: {
                                labels: history.labels,
                                datasets: [
                                    {
                                        label: 'Download',
                                        data: history.rx,
                                        borderColor: 'rgb(34, 211, 238)',
                                        backgroundColor: 'rgba(34, 211, 238, 0.1)',
                                        borderWidth: 2,
                                        tension: 0.4,
                                        fill: true
                                    },
                                    {
                                        label: 'Upload',
                                        data: history.tx,
                                        borderColor: 'rgb(52, 211, 153)',
                                        backgroundColor: 'rgba(52, 211, 153, 0.1)',
                                        borderWidth: 2,
                                        tension: 0.4,
                                        fill: true
                                    }
                                ]
                            },
                        options: {
                            responsive: true,
                            maintainAspectRatio: false,
                            interaction: {
                                intersect: false,
                                mode: 'index'
                            },
                            plugins: {
                                legend: {
                                    display: true,
                                    position: 'top',
                                    labels: {
                                        color: '#9CA3AF',
                                        font: {
                                            size: 11
                                        },
                                        boxWidth: 12,
                                        boxHeight: 12
                                    }
                                },
                                tooltip: {
                                    callbacks: {
                                        label: function(context) {
                                            let label = context.dataset.label || '';
                                            if (label) {
                                                label += ': ';
                                            }
                                            label += formatBandwidth(context.parsed.y);
                                            return label;
                                        }
                                    }
                                }
                            },
                            scales: {
                                x: {
                                    display: true,
                                    grid: {
                                        color: 'rgba(255, 255, 255, 0.05)',
                                        drawBorder: false
                                    },
                                    ticks: {
                                        color: '#6B7280',
                                        font: {
                                            size: 10
                                        },
                                        maxRotation: 0,
                                        autoSkip: true,
                                        maxTicksLimit: 8
                                    }
                                },
                                y: {
                                    display: true,
                                    grid: {
                                        color: 'rgba(255, 255, 255, 0.05)',
                                        drawBorder: false
                                    },
                                    ticks: {
                                        color: '#6B7280',
                                        font: {
                                            size: 10
                                        },
                                        callback: function(value) {
                                            return formatBandwidth(value);
                                        }
                                    },
                                    ...scaleOptions  // Apply unified scale if set
                                }
                                }
                            }
                        });
                        
                        this.loadingGraphs[ip] = false;
                        
                    } catch (error) {
                        console.error('Error creating chart for IP:', ip, error);
                        this.loadingGraphs[ip] = false;
                    }
                },
                
                async toggleAllGraphs() {
                    this.allGraphsExpanded = !this.allGraphsExpanded;
                    
                    if (this.allGraphsExpanded) {
                        // Get all client IPs to expand
                        const clientIps = this.clients.map(c => c.ip);
                        
                        // Fetch all histories at once for better performance
                        try {
                            const response = await fetch(`/api/client-histories?ips=${clientIps.join(',')}&duration=${this.timeRange}`);
                            if (response.ok) {
                                const allHistories = await response.json();
                                
                                // Calculate unified scale for all charts
                                if (this.useUnifiedScale) {
                                    this.calculateUnifiedScale(allHistories);
                                }
                                
                                // Process each client's history
                                for (const ip of clientIps) {
                                    const history = allHistories[ip];
                                    if (!history || history.error) continue;
                                    
                                    if (!this.expandedGraphs[ip]) {
                                        this.expandedGraphs[ip] = true;
                                        
                                        // Wait for DOM to update
                                        await this.$nextTick();
                                        
                                        // Create chart with fetched data
                                        const canvasId = 'bandwidth-chart-' + ip.replace(/\\./g, '-');
                                        const canvas = document.getElementById(canvasId);
                                        
                                        if (canvas && !chartInstances[ip]) {
                                            this.createChartFromData(ip, history);
                                        }
                                    }
                                }
                            } else {
                                // Fallback to individual fetching
                                console.warn('Bulk fetch failed, falling back to individual requests');
                                this.clients.forEach(client => {
                                    if (!this.expandedGraphs[client.ip]) {
                                        this.toggleClientGraph(client.ip);
                                    }
                                });
                            }
                        } catch (error) {
                            console.error('Error fetching bulk histories:', error);
                            // Fallback to individual fetching
                            this.clients.forEach(client => {
                                if (!this.expandedGraphs[client.ip]) {
                                    this.toggleClientGraph(client.ip);
                                }
                            });
                        }
                    } else {
                        // Collapse all graphs
                        Object.keys(this.expandedGraphs).forEach(ip => {
                            if (this.expandedGraphs[ip]) {
                                this.expandedGraphs[ip] = false;
                                if (chartInstances[ip]) {
                                    try {
                                        chartInstances[ip].destroy();
                                    } catch (e) {
                                        console.warn('Error destroying chart:', e);
                                    }
                                    delete chartInstances[ip];
                                    delete this.loadingGraphs[ip];
                                }
                            }
                        });
                    }
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
                                compareValue = bwA - bwB; // Lower first (will be reversed for desc)
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
                
                async toggleUnifiedScale() {
                    this.useUnifiedScale = !this.useUnifiedScale;
                    
                    // If enabling unified scale, recalculate and update all charts
                    if (this.useUnifiedScale) {
                        const expandedIps = Object.keys(this.expandedGraphs).filter(ip => this.expandedGraphs[ip]);
                        if (expandedIps.length > 0) {
                            // Fetch all data to calculate unified scale
                            const response = await fetch(`/api/client-histories?ips=${expandedIps.join(',')}&duration=${this.timeRange}`);
                            if (response.ok) {
                                const allHistories = await response.json();
                                this.calculateUnifiedScale(allHistories);
                                
                                // Update all existing charts with the new scale
                                for (const ip of expandedIps) {
                                    const chart = chartInstances[ip];
                                    if (chart && !chart._destroyed) {
                                        this.updateChartScale(chart);
                                        chart.update();
                                    }
                                }
                            }
                        }
                    } else {
                        // Disable unified scale, let charts auto-scale
                        this.unifiedMaxValue = 0;
                        for (const ip of Object.keys(chartInstances)) {
                            const chart = chartInstances[ip];
                            if (chart && !chart._destroyed) {
                                delete chart.options.scales.y.max;
                                delete chart.options.scales.y.min;
                                chart.update();
                            }
                        }
                    }
                },
                
                async onTimeRangeChange() {
                    console.log(`[TIME_RANGE] Changed to: ${this.timeRange}`);
                    
                    // Clear and recreate all charts with new time range
                    const expandedIps = Object.keys(this.expandedGraphs).filter(ip => this.expandedGraphs[ip]);
                    
                    if (expandedIps.length === 0) return;
                    
                    // Show loading state for all charts
                    for (const ip of expandedIps) {
                        this.loadingGraphs[ip] = true;
                    }
                    
                    try {
                        // Fetch all data with new time range
                        // Note: The backend automatically adapts data sampling based on duration
                        // - Short durations (<=1h): 30s-2m resolution, detailed time labels
                        // - Medium durations (1h-24h): 2m-30m resolution, hour:minute labels  
                        // - Long durations (>24h): 1h-6h resolution, date labels
                        // This keeps graphs responsive while showing appropriate detail level
                        const response = await fetch(`/api/client-histories?ips=${expandedIps.join(',')}&duration=${this.timeRange}`);
                        if (!response.ok) {
                            console.error('Failed to fetch data with new time range');
                            return;
                        }
                        
                        const allHistories = await response.json();
                        
                        // Calculate unified scale if enabled
                        if (this.useUnifiedScale) {
                            this.calculateUnifiedScale(allHistories);
                        }
                        
                        // Update all charts with new data
                        for (const ip of expandedIps) {
                            const history = allHistories[ip];
                            if (!history || history.error) {
                                this.loadingGraphs[ip] = false;
                                continue;
                            }
                            
                            // Recreate chart with new data
                            if (chartInstances[ip]) {
                                chartInstances[ip].destroy();
                                delete chartInstances[ip];
                            }
                            
                            this.createChartFromData(ip, history);
                            this.loadingGraphs[ip] = false;
                        }
                    } catch (error) {
                        console.error('Error changing time range:', error);
                        for (const ip of expandedIps) {
                            this.loadingGraphs[ip] = false;
                        }
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
        
        // Helper function to format bandwidth for display
        function formatBandwidth(bps) {
            if (bps < 1000) {
                return bps.toFixed(0) + ' bps';
            } else if (bps < 1000000) {
                return (bps / 1000).toFixed(1) + ' Kbps';
            } else if (bps < 1000000000) {
                return (bps / 1000000).toFixed(1) + ' Mbps';
            } else {
                return (bps / 1000000000).toFixed(1) + ' Gbps';
            }
        }
        
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
                logger.error(f"Error getting client info from metrics: {e}")
                return self.cache  # Return stale cache on error

# Global cache instances
metrics_cache = MetricsCache(ttl_seconds=5)  # Cache metrics for 5 seconds
connectivity_cache = MetricsCache(ttl_seconds=30)  # Cache connectivity for 30 seconds
blocky_cache = MetricsCache(ttl_seconds=10)  # Cache Blocky stats for 10 seconds
client_info_cache = ClientInfoCache(ttl_seconds=30)  # Cache client info from network-metrics-exporter
bandwidth_history_cache = MetricsCache(ttl_seconds=15)  # Cache bandwidth histories for 15 seconds

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            # Serve the dashboard HTML
            logger.debug(f"Dashboard request from {self.address_string()}")
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(DASHBOARD_HTML.encode())
            logger.debug(f"Served dashboard HTML ({len(DASHBOARD_HTML)} chars)")
        elif self.path == '/api/metrics':
            logger.debug(f"Metrics request from {self.address_string()}")
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            
            metrics = self.get_system_metrics()
            response_data = json.dumps(metrics).encode()
            self.wfile.write(response_data)
            self.wfile.flush()
            logger.debug(f"Sent metrics response ({len(response_data)} bytes)")
        elif self.path.startswith('/api/client-histories'):
            # Bulk fetch client histories
            logger.debug(f"Bulk client histories request from {self.address_string()}")
            
            try:
                # Parse query parameters for specific IPs
                from urllib.parse import urlparse, parse_qs
                parsed = urlparse(self.path)
                query_params = parse_qs(parsed.query)
                
                # Get requested IPs from query params, or all if not specified
                if 'ips' in query_params:
                    # IPs provided as comma-separated list
                    client_ips = query_params['ips'][0].split(',')
                    logger.debug(f"Fetching histories for specific IPs: {client_ips}")
                else:
                    # No IPs specified, get all connected clients
                    clients_data = self.get_connected_clients()
                    client_ips = [client['ip'] for client in clients_data.get('clients', [])]
                    logger.debug(f"Fetching histories for all {len(client_ips)} connected clients")
                
                # Get duration parameter (default to 10m)
                duration = query_params.get('duration', ['10m'])[0]
                logger.debug(f"Using duration: {duration}")
                
                # Fetch histories in parallel with specified duration
                histories = self.get_bulk_client_histories(client_ips, duration)
                
                response_data = json.dumps(histories).encode()
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Content-Length', str(len(response_data)))
                self.end_headers()
                
                self.wfile.write(response_data)
                self.wfile.flush()
                logger.debug(f"Sent bulk histories for {len(histories)} clients ({len(response_data)} bytes)")
            except Exception as e:
                logger.error(f"Error handling bulk histories request: {e}", exc_info=True)
                self.send_error(500, "Internal Server Error")
        else:
            self.send_error(404)
    
    def log_message(self, format, *args):
        # Log HTTP requests using our logger
        logger.info(f"{self.address_string()} - {format % args}")
    
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
                    logger.error(f"Error getting {key}: {e}")
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

        # Try common WAN interfaces including enp2s0 (actual WAN interface)
        for iface in ['enp2s0', 'eth0', 'wan', 'enp1s0']:
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

        # Fallback: query external IP check service
        try:
            result = subprocess.run(
                ['curl', '-s', '--max-time', '2', 'https://ifconfig.me'],
                capture_output=True,
                text=True,
                timeout=3
            )
            if result.returncode == 0 and result.stdout.strip():
                ip = result.stdout.strip()
                # Validate it's a valid-looking IP
                if '.' in ip and len(ip.split('.')) == 4:
                    return ip
        except:
            pass

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
            logger.error(f"Error querying VictoriaMetrics: {e}")
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
                        logger.error(f"Error querying {key}: {e}")
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
            logger.error(f"Error getting Blocky stats: {e}")
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
                    logger.error(f"Error in connectivity check: {e}")
        
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
            logger.error(f"Error reading ARP table: {e}")
        
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
            logger.debug(f"get_connected_clients took: {total_time}ms")
        
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
            logger.error(f"Error getting client bandwidth rates: {e}")
            return {}
    
    def get_bulk_client_histories(self, client_ips: list, duration: str = '10m') -> Dict[str, Any]:
        """Get bandwidth history for multiple clients in a single VictoriaMetrics query"""
        start_time = time.time()
        
        # Check cache for bulk request
        cache_key = f"bulk_histories_{','.join(sorted(client_ips))}_{duration}"
        cached = bandwidth_history_cache.get(cache_key)
        if cached:
            logger.debug(f"Using cached bulk histories for {len(client_ips)} clients")
            return cached
        
        histories = {}
        
        # Initialize empty histories for all IPs
        for ip in client_ips:
            histories[ip] = {
                'ip': ip,
                'labels': [],
                'rx': [],
                'tx': []
            }
        
        if not client_ips:
            return histories
        
        try:
            # Build time range parameters
            end_time = int(time.time())
            
            # Parse duration and determine optimal step size
            if duration.endswith('m'):
                duration_seconds = int(duration[:-1]) * 60
            elif duration.endswith('h'):
                duration_seconds = int(duration[:-1]) * 3600
            elif duration.endswith('d'):
                duration_seconds = int(duration[:-1]) * 86400
            else:
                duration_seconds = 600  # Default 10 minutes for bulk
            
            start_time_query = end_time - duration_seconds
            
            # Adaptive step size and max points based on duration
            # Goal: Keep graphs responsive with max ~100 data points
            if duration_seconds <= 600:  # <= 10 minutes
                step = 30  # 30-second resolution
                max_points = 100
            elif duration_seconds <= 1800:  # <= 30 minutes
                step = 60  # 1-minute resolution
                max_points = 100
            elif duration_seconds <= 3600:  # <= 1 hour
                step = 120  # 2-minute resolution
                max_points = 100
            elif duration_seconds <= 10800:  # <= 3 hours
                step = 300  # 5-minute resolution
                max_points = 100
            elif duration_seconds <= 21600:  # <= 6 hours
                step = 600  # 10-minute resolution
                max_points = 100
            elif duration_seconds <= 43200:  # <= 12 hours
                step = 900  # 15-minute resolution
                max_points = 100
            elif duration_seconds <= 86400:  # <= 24 hours
                step = 1800  # 30-minute resolution
                max_points = 100
            elif duration_seconds <= 172800:  # <= 48 hours (2 days)
                step = 3600  # 1-hour resolution
                max_points = 100
            elif duration_seconds <= 259200:  # <= 72 hours (3 days)
                step = 7200  # 2-hour resolution
                max_points = 100
            elif duration_seconds <= 604800:  # <= 1 week
                step = 14400  # 4-hour resolution
                max_points = 100
            else:  # > 1 week
                step = 21600  # 6-hour resolution
                max_points = 100
            
            logger.debug(f"Duration: {duration}, seconds: {duration_seconds}, step: {step}s, max_points: {max_points}")
            
            # Build a single query for all clients using regex matching
            # This queries all client_traffic_rate_bps metrics and filters by IP
            base_url = "http://localhost:8428/api/v1/query_range"
            
            # Query all client traffic in one request
            ip_regex = '|'.join(client_ips)
            query = f'client_traffic_rate_bps{{ip=~"{ip_regex}"}}'
            
            params = {
                'query': query,
                'start': start_time_query,
                'end': end_time,
                'step': step
            }
            
            url = f"{base_url}?{urllib.parse.urlencode(params)}"
            logger.debug(f"Bulk query URL: {url}")
            logger.debug(f"Query params: start={start_time_query}, end={end_time}, step={step}, duration_seconds={duration_seconds}")
            
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.loads(response.read().decode())
                
                logger.debug(f"VictoriaMetrics response status: {data.get('status')}")
                if data.get('data', {}).get('result'):
                    logger.debug(f"Got {len(data['data']['result'])} series from VictoriaMetrics")
                
                if data.get('status') == 'success' and data.get('data', {}).get('result'):
                    # Process each series returned - collect all data first
                    series_data = {}  # ip -> {rx_values: [], tx_values: [], timestamps: []}
                    
                    for series in data['data']['result']:
                        metric = series.get('metric', {})
                        ip = metric.get('ip')
                        direction = metric.get('direction')
                        values = series.get('values', [])
                        
                        logger.debug(f"Processing series: ip={ip}, direction={direction}, values_count={len(values)}")
                        
                        if ip and ip in histories:
                            if ip not in series_data:
                                series_data[ip] = {'rx_values': [], 'tx_values': [], 'timestamps': []}
                            
                            if direction == 'rx':
                                series_data[ip]['rx_values'] = [float(v) for _, v in values]
                                series_data[ip]['timestamps'] = [float(ts) for ts, _ in values]
                                logger.debug(f"Stored RX data for {ip}: {len(values)} points")
                            elif direction == 'tx':
                                series_data[ip]['tx_values'] = [float(v) for _, v in values]
                                logger.debug(f"Stored TX data for {ip}: {len(values)} points")
                    
                    # Now process each IP's complete data
                    for ip, data_dict in series_data.items():
                        rx_values = data_dict['rx_values']
                        tx_values = data_dict['tx_values']
                        timestamps = data_dict['timestamps']
                        
                        logger.debug(f"Processing {ip}: rx={len(rx_values)}, tx={len(tx_values)}, timestamps={len(timestamps)}")
                        
                        # Use the longest array as the reference (should all be the same length)
                        max_len = max(len(rx_values), len(tx_values), len(timestamps))
                        if max_len == 0:
                            logger.debug(f"Skipping {ip} - no data")
                            continue
                            
                        # Pad shorter arrays with zeros/last timestamp
                        while len(rx_values) < max_len:
                            rx_values.append(0.0)
                        while len(tx_values) < max_len:
                            tx_values.append(0.0)
                        while len(timestamps) < max_len:
                            timestamps.append(timestamps[-1] if timestamps else start_time_query)
                        
                        # Truncate to shortest length if somehow mismatched
                        min_len = min(len(rx_values), len(tx_values), len(timestamps))
                        rx_values = rx_values[:min_len]
                        tx_values = tx_values[:min_len]
                        timestamps = timestamps[:min_len]
                        
                        # Generate formatted labels
                        if duration_seconds <= 3600:  # <= 1 hour: show time only
                            labels = [time.strftime('%H:%M:%S', time.localtime(ts)) for ts in timestamps]
                        elif duration_seconds <= 86400:  # <= 24 hours: show hours:minutes
                            labels = [time.strftime('%H:%M', time.localtime(ts)) for ts in timestamps]
                        elif duration_seconds <= 604800:  # <= 1 week: show day and time
                            labels = [time.strftime('%m/%d %H:%M', time.localtime(ts)) for ts in timestamps]
                        else:  # > 1 week: show date only
                            labels = [time.strftime('%m/%d', time.localtime(ts)) for ts in timestamps]
                        
                        # Apply downsampling if needed BEFORE storing
                        if len(labels) > max_points:
                            logger.debug(f"Downsampling {ip}: {len(labels)} -> {max_points} points")
                            downsample_rate = len(labels) // max_points
                            labels = labels[::downsample_rate][:max_points]
                            rx_values = rx_values[::downsample_rate][:max_points]
                            tx_values = tx_values[::downsample_rate][:max_points]
                        
                        # Store the processed data
                        logger.debug(f"Storing {ip}: labels={len(labels)}, rx={len(rx_values)}, tx={len(tx_values)}")
                        histories[ip]['labels'] = labels
                        histories[ip]['rx'] = rx_values
                        histories[ip]['tx'] = tx_values
            
            # Calculate expected number of points
            num_points = min(max_points, max(1, int(duration_seconds / step)))
            # Fill in empty data for clients with no metrics and validate all arrays
            for ip in client_ips:
                if not histories[ip]['labels']:  # No data from VictoriaMetrics
                    # Generate time labels for empty data
                    for i in range(num_points):
                        timestamp = start_time_query + (i * step)
                        # Format based on duration
                        if duration_seconds <= 3600:  # <= 1 hour
                            time_str = time.strftime('%H:%M:%S', time.localtime(timestamp))
                        elif duration_seconds <= 86400:  # <= 24 hours
                            time_str = time.strftime('%H:%M', time.localtime(timestamp))
                        elif duration_seconds <= 604800:  # <= 1 week
                            time_str = time.strftime('%m/%d %H:%M', time.localtime(timestamp))
                        else:  # > 1 week
                            time_str = time.strftime('%m/%d', time.localtime(timestamp))
                        histories[ip]['labels'].append(time_str)
                    histories[ip]['rx'] = [0] * num_points
                    histories[ip]['tx'] = [0] * num_points
                else:
                    # Validate that all arrays are the same length
                    label_count = len(histories[ip]['labels'])
                    rx_count = len(histories[ip]['rx'])
                    tx_count = len(histories[ip]['tx'])
                    
                    if not (label_count == rx_count == tx_count):
                        logger.warning(f"Pre-validation length mismatch for {ip}: labels={label_count}, rx={rx_count}, tx={tx_count}")
                        # Fix by truncating to shortest length
                        min_count = min(label_count, rx_count, tx_count)
                        if min_count > 0:
                            histories[ip]['labels'] = histories[ip]['labels'][:min_count]
                            histories[ip]['rx'] = histories[ip]['rx'][:min_count]
                            histories[ip]['tx'] = histories[ip]['tx'][:min_count]
                        else:
                            # All arrays are empty, generate empty data
                            histories[ip]['labels'] = []
                            histories[ip]['rx'] = []
                            histories[ip]['tx'] = []
        
        except Exception as e:
            logger.error(f"Error fetching bulk histories: {e}")
            # Fill with empty data on error
            num_points = 10
            for ip in client_ips:
                if not histories[ip]['labels']:
                    for i in range(num_points):
                        timestamp = end_time - ((num_points - i - 1) * 30)
                        time_str = time.strftime('%H:%M:%S', time.localtime(timestamp))
                        histories[ip]['labels'].append(time_str)
                    histories[ip]['rx'] = [0] * num_points
                    histories[ip]['tx'] = [0] * num_points
        
        elapsed = time.time() - start_time
        # Log statistics with validation
        total_points = sum(len(h['labels']) for h in histories.values())
        
        # Debug: Check for mismatched array lengths
        for ip, history in histories.items():
            if history['labels']:  # Only check if there's data
                label_len = len(history['labels'])
                rx_len = len(history['rx'])
                tx_len = len(history['tx'])
                if not (label_len == rx_len == tx_len):
                    logger.warning(f"Array length mismatch for {ip}: labels={label_len}, rx={rx_len}, tx={tx_len}")
        
        logger.info(f"Fetched {len(histories)} client histories ({total_points} total points) in {elapsed:.2f}s with step={step}s")
        
        # Cache the bulk result
        bandwidth_history_cache.set(cache_key, histories)
        
        return histories
    
    def get_client_bandwidth_history(self, client_ip: str, duration: str = '30m') -> Dict[str, Any]:
        """Get bandwidth history for a specific client from VictoriaMetrics"""
        # For single client queries, just delegate to bulk function for consistency
        histories = self.get_bulk_client_histories([client_ip], duration)
        return histories.get(client_ip, {
            'ip': client_ip,
            'labels': [],
            'rx': [],
            'tx': [],
            'error': 'No data available'
        })

def main():
    parser = argparse.ArgumentParser(description='Router Dashboard and Metrics API Server')
    parser.add_argument('--host', default='localhost', 
                       help='Host to bind to (default: localhost, use 0.0.0.0 for all interfaces)')
    parser.add_argument('--port', type=int, default=8085,
                       help='Port to listen on (default: 8085)')
    parser.add_argument('--bind-all', action='store_true',
                       help='Bind to all interfaces (equivalent to --host 0.0.0.0)')
    parser.add_argument('--log-level', default='INFO',
                       choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'],
                       help='Set the logging level (default: INFO)')
    
    args = parser.parse_args()
    
    # Update log level based on command line argument
    logger.setLevel(getattr(logging, args.log_level))
    
    # Override host if --bind-all is specified
    host = '0.0.0.0' if args.bind_all else args.host
    port = args.port
    
    server = HTTPServer((host, port), MetricsHandler)
    
    # Display appropriate URLs based on binding
    if host == '0.0.0.0':
        logger.info(f"Router Dashboard and Metrics API server running on all interfaces, port {port}")
        logger.info(f"  - Dashboard: http://<your-ip>:{port}/")
        logger.info(f"  - Metrics API: http://<your-ip>:{port}/api/metrics")
        # Try to show actual IPs
        try:
            hostname = socket.gethostname()
            local_ips = socket.gethostbyname_ex(hostname)[2]
            for ip in local_ips:
                if not ip.startswith('127.'):
                    logger.info(f"  - Available at: http://{ip}:{port}/")
        except:
            pass
    else:
        logger.info(f"Router Dashboard and Metrics API server running on http://{host}:{port}")
        logger.info(f"  - Dashboard: http://{host}:{port}/")
        logger.info(f"  - Metrics API: http://{host}:{port}/api/metrics")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down server...")
        server.shutdown()

if __name__ == '__main__':
    main()