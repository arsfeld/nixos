// Dashboard Component
function dashboard() {
    return {
        stats: {
            active_vpns: 0,
            total_vpns: 0,
            connected_clients: 0,
            system_health: {
                cpu_usage: 0,
                memory_usage: 0,
                uptime: 0
            },
            traffic_stats: {}
        },

        async init() {
            await this.fetchStats();
            this.setupEventSource();
            
            // Refresh stats every 5 seconds
            setInterval(() => this.fetchStats(), 5000);
        },

        async fetchStats() {
            try {
                const response = await fetch('/api/dashboard/stats');
                this.stats = await response.json();
            } catch (error) {
                console.error('Failed to fetch dashboard stats:', error);
            }
        },

        formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        },

        formatUptime(seconds) {
            const days = Math.floor(seconds / 86400);
            const hours = Math.floor((seconds % 86400) / 3600);
            const minutes = Math.floor((seconds % 3600) / 60);
            
            let parts = [];
            if (days > 0) parts.push(`${days}d`);
            if (hours > 0) parts.push(`${hours}h`);
            if (minutes > 0) parts.push(`${minutes}m`);
            
            return parts.join(' ') || '0m';
        },

        setupEventSource() {
            const eventSource = new EventSource('/api/events');
            
            eventSource.addEventListener('stats-update', (event) => {
                this.fetchStats();
            });
        }
    };
}

// VPN Manager Component
function vpnManager() {
    return {
        providers: [],
        showAddProvider: false,
        editingProvider: null,
        providerForm: {
            name: '',
            type: 'wireguard',
            interface_name: '',
            endpoint: '',
            public_key: '',
            private_key: '',
            preshared_key: ''
        },

        async init() {
            await this.fetchProviders();
            this.setupEventSource();
        },

        async fetchProviders() {
            try {
                const response = await fetch('/api/vpn/providers');
                this.providers = await response.json();
            } catch (error) {
                console.error('Failed to fetch providers:', error);
            }
        },

        async toggleProvider(id) {
            try {
                const response = await fetch(`/api/vpn/providers/${id}/toggle`, { method: 'POST' });
                if (response.ok) {
                    await this.fetchProviders();
                    showToast('VPN provider toggled successfully', 'success');
                } else {
                    showToast('Failed to toggle VPN provider', 'error');
                }
            } catch (error) {
                console.error('Failed to toggle provider:', error);
                showToast('Failed to toggle VPN provider', 'error');
            }
        },

        editProvider(provider) {
            this.editingProvider = provider;
            this.providerForm = { ...provider };
            this.showAddProvider = true;
        },

        async deleteProvider(id) {
            if (!confirm('Are you sure you want to delete this provider?')) return;
            
            try {
                const response = await fetch(`/api/vpn/providers/${id}`, { method: 'DELETE' });
                if (response.ok) {
                    await this.fetchProviders();
                    showToast('VPN provider deleted successfully', 'success');
                } else {
                    showToast('Failed to delete VPN provider', 'error');
                }
            } catch (error) {
                console.error('Failed to delete provider:', error);
                showToast('Failed to delete VPN provider', 'error');
            }
        },

        async saveProvider() {
            const method = this.editingProvider ? 'PUT' : 'POST';
            const url = this.editingProvider 
                ? `/api/vpn/providers/${this.editingProvider.id}` 
                : '/api/vpn/providers';

            try {
                const response = await fetch(url, {
                    method,
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(this.providerForm)
                });
                
                if (response.ok) {
                    await this.fetchProviders();
                    this.closeModal();
                    const action = this.editingProvider ? 'updated' : 'created';
                    showToast(`VPN provider ${action} successfully`, 'success');
                } else {
                    const error = await response.text();
                    showToast(error || 'Failed to save VPN provider', 'error');
                }
            } catch (error) {
                console.error('Failed to save provider:', error);
                showToast('Failed to save VPN provider', 'error');
            }
        },

        closeModal() {
            this.showAddProvider = false;
            this.editingProvider = null;
            this.providerForm = {
                name: '',
                type: 'wireguard',
                interface_name: '',
                endpoint: '',
                public_key: '',
                private_key: '',
                preshared_key: ''
            };
        },

        setupEventSource() {
            const eventSource = new EventSource('/api/events');
            
            eventSource.addEventListener('provider-update', (event) => {
                this.fetchProviders();
            });

            eventSource.addEventListener('heartbeat', (event) => {
                console.log('Heartbeat:', event.data);
            });
        }
    };
}

// Client Manager Component
function clientManager() {
    return {
        clients: [],
        providers: [],
        stats: { total: 0, online: 0 },
        showEditClient: false,
        editingClient: {},

        async init() {
            await Promise.all([
                this.fetchClients(),
                this.fetchProviders(),
                this.fetchStats()
            ]);
            this.setupEventSource();
            // Refresh clients every 30 seconds
            setInterval(() => {
                this.fetchClients();
                this.fetchStats();
            }, 30000);
        },

        async fetchClients() {
            try {
                const response = await fetch('/api/clients');
                this.clients = await response.json();
                // Load VPN mappings
                for (const client of this.clients) {
                    const vpnResponse = await fetch(`/api/clients/${client.mac}/vpn`);
                    if (vpnResponse.ok) {
                        const mapping = await vpnResponse.json();
                        client.vpn_provider_id = mapping.provider_id;
                    }
                }
            } catch (error) {
                console.error('Failed to fetch clients:', error);
            }
        },

        async fetchProviders() {
            try {
                const response = await fetch('/api/vpn/providers');
                this.providers = await response.json();
            } catch (error) {
                console.error('Failed to fetch providers:', error);
            }
        },

        async fetchStats() {
            try {
                const response = await fetch('/api/clients/stats');
                this.stats = await response.json();
            } catch (error) {
                console.error('Failed to fetch client stats:', error);
            }
        },

        async updateClientVPN(mac, providerId) {
            try {
                const response = await fetch(`/api/clients/${mac}/vpn`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ provider_id: providerId })
                });
                
                if (response.ok) {
                    await this.fetchClients();
                    const message = providerId 
                        ? 'Client VPN assignment updated' 
                        : 'Client VPN assignment removed';
                    showToast(message, 'success');
                } else {
                    showToast('Failed to update client VPN assignment', 'error');
                }
            } catch (error) {
                console.error('Failed to update client VPN:', error);
                showToast('Failed to update client VPN assignment', 'error');
            }
        },

        editClient(client) {
            this.editingClient = { ...client };
            this.showEditClient = true;
        },

        async saveClient() {
            try {
                const response = await fetch(`/api/clients/${this.editingClient.mac}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        name: this.editingClient.name,
                        device_type: this.editingClient.device_type,
                        notes: this.editingClient.notes
                    })
                });
                
                if (response.ok) {
                    await this.fetchClients();
                    showToast('Client information updated', 'success');
                    this.closeEditModal();
                } else {
                    showToast('Failed to update client information', 'error');
                }
            } catch (error) {
                console.error('Failed to save client:', error);
                showToast('Failed to update client information', 'error');
            }
        },

        closeEditModal() {
            this.showEditClient = false;
            this.editingClient = {};
        },

        formatTime(timestamp) {
            if (!timestamp) return 'Never';
            const date = new Date(timestamp);
            const now = new Date();
            const diff = now - date;
            
            if (diff < 60000) return 'Just now';
            if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
            if (diff < 86400000) return `${Math.floor(diff / 3600000)}h ago`;
            
            return date.toLocaleDateString();
        },

        setupEventSource() {
            const eventSource = new EventSource('/api/events');
            
            eventSource.addEventListener('client-update', (event) => {
                this.fetchClients();
                this.fetchStats();
            });
        }
    };
}