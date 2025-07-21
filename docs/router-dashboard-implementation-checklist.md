# Router Dashboard Implementation Checklist

## Overview
The router dashboard framework is deployed and working with proper CSS/static file loading. All pages currently show placeholders. This document outlines the detailed implementation plan for each page and feature.

## Core Infrastructure ✅
- [x] Go server with embedded templates and static files
- [x] Prometheus metrics client
- [x] Base path support for reverse proxy deployment
- [x] NixOS module and service configuration
- [x] Caddy reverse proxy integration
- [x] Theme switching (dark/light/auto)
- [x] Responsive sidebar navigation

## Page Implementation Checklist

### 1. Home/Overview Page (`/`)
- [ ] **System Status Widget**
  - [ ] Fetch and display uptime from Prometheus
  - [ ] CPU usage with live updates
  - [ ] Memory usage with progress bar
  - [ ] Load average (1, 5, 15 min)
  - [ ] Temperature monitoring (if available)
  
- [ ] **Network Status Widget**
  - [ ] WAN interface status (up/down)
  - [ ] WAN IP address display
  - [ ] Real-time bandwidth meters (RX/TX)
  - [ ] LAN interface status
  - [ ] Total bandwidth usage
  
- [ ] **Quick Stats Cards**
  - [ ] Active clients count with sparkline
  - [ ] DNS queries/sec with sparkline
  - [ ] NAT mappings count with sparkline
  
- [ ] **Recent Alerts**
  - [ ] Query Alertmanager API
  - [ ] Display last 5-10 alerts
  - [ ] Color code by severity

### 2. Network Status Page (`/network`)
- [ ] **Interface Details Table**
  - [ ] List all network interfaces
  - [ ] Status indicators (up/down)
  - [ ] IP addresses (IPv4/IPv6)
  - [ ] MAC addresses
  - [ ] MTU and link speed
  
- [ ] **Bandwidth Graphs**
  - [ ] Per-interface bandwidth charts
  - [ ] Historical data (1h, 6h, 24h, 7d)
  - [ ] Separate RX/TX graphs
  - [ ] Total traffic counters
  
- [ ] **Packet Statistics**
  - [ ] Packets sent/received
  - [ ] Error counts
  - [ ] Dropped packets
  - [ ] Collision statistics
  
- [ ] **Connection Tracking**
  - [ ] Active connections count
  - [ ] Connection state distribution
  - [ ] Top protocols

### 3. Client Monitoring Page (`/clients`)
- [ ] **Active Clients Table**
  - [ ] Client IP addresses
  - [ ] Hostnames from DHCP leases
  - [ ] MAC addresses
  - [ ] Real-time bandwidth usage
  - [ ] Total data transferred
  - [ ] Connection duration
  
- [ ] **Bandwidth Charts**
  - [ ] Per-client bandwidth graphs
  - [ ] Top bandwidth consumers
  - [ ] Historical usage patterns
  
- [ ] **Client Details Modal**
  - [ ] Detailed statistics per client
  - [ ] Active connections
  - [ ] DNS queries
  - [ ] Port mappings

### 4. DNS Analytics Page (`/dns`)
- [ ] **Query Statistics**
  - [ ] Total queries/sec
  - [ ] Query types distribution (A, AAAA, etc.)
  - [ ] Response time histogram
  
- [ ] **Blocky Integration**
  - [ ] Blocked queries count and percentage
  - [ ] Cache hit ratio
  - [ ] Upstream server statistics
  
- [ ] **Top Domains**
  - [ ] Most queried domains
  - [ ] Most blocked domains
  - [ ] Client query distribution
  
- [ ] **Real-time Query Log**
  - [ ] Live query stream
  - [ ] Filtering by client/domain
  - [ ] Block/allow status

### 5. NAT/Port Forwarding Page (`/nat`)
- [ ] **NAT-PMP Mappings**
  - [ ] Active mappings table
  - [ ] External/internal ports
  - [ ] Protocol (TCP/UDP)
  - [ ] Client IP
  - [ ] Remaining lifetime
  
- [ ] **Port Forwarding Rules**
  - [ ] Static rules from config
  - [ ] Enable/disable status
  - [ ] Usage statistics
  
- [ ] **Mapping Statistics**
  - [ ] Total mappings over time
  - [ ] Mappings per client
  - [ ] Port usage distribution

### 6. QoS/Traffic Shaping Page (`/qos`)
- [ ] **Traffic Classes**
  - [ ] Class hierarchy visualization
  - [ ] Bandwidth allocation per class
  - [ ] Current usage per class
  
- [ ] **Queue Statistics**
  - [ ] Packet counts per queue
  - [ ] Drop statistics
  - [ ] Queue depths
  - [ ] Latency measurements
  
- [ ] **Real-time Graphs**
  - [ ] Bandwidth per traffic class
  - [ ] Queue utilization
  - [ ] Packet drops over time

### 7. System Performance Page (`/system`)
- [ ] **CPU Metrics**
  - [ ] Per-core usage
  - [ ] System/user/idle breakdown
  - [ ] Historical graphs
  - [ ] Top processes by CPU
  
- [ ] **Memory Metrics**
  - [ ] Used/free/cached breakdown
  - [ ] Swap usage
  - [ ] Memory pressure indicators
  - [ ] Top processes by memory
  
- [ ] **Disk I/O**
  - [ ] Read/write rates
  - [ ] IOPS metrics
  - [ ] Disk usage per partition
  
- [ ] **System Health**
  - [ ] Temperature sensors
  - [ ] Fan speeds (if available)
  - [ ] Power consumption (if available)
  - [ ] Interrupt statistics

### 8. Logs & Alerts Page (`/logs`)
- [ ] **System Events**
  - [ ] Service start/stop events
  - [ ] Configuration changes
  - [ ] Error logs
  
- [ ] **Security Alerts**
  - [ ] Failed login attempts
  - [ ] Firewall blocks
  - [ ] Port scan detection
  
- [ ] **Alert History**
  - [ ] Prometheus alerts
  - [ ] Resolved/active status
  - [ ] Alert timeline
  
- [ ] **Log Search**
  - [ ] Full-text search
  - [ ] Time range filtering
  - [ ] Severity filtering

## API Implementation

### Metrics API (`/api/metrics`)
- [ ] Real-time metrics endpoint
- [ ] Batch metrics for efficiency
- [ ] Metric aggregation
- [ ] Time range queries

### WebSocket Implementation (`/ws`)
- [ ] Real-time metric updates
- [ ] Bandwidth streaming
- [ ] Alert notifications
- [ ] Connection management

## Data Collection Enhancements

### Custom Prometheus Exporters
- [ ] DHCP lease exporter (hostname/IP/MAC mapping)
- [ ] Per-client bandwidth exporter
- [ ] Traffic class statistics exporter
- [ ] Connection tracking exporter

### Metric Storage Optimization
- [ ] Implement metric caching
- [ ] Aggregation for historical data
- [ ] Efficient query patterns
- [ ] Rate limiting for expensive queries

## UI/UX Enhancements

### Interactive Features
- [ ] Click-to-copy for IPs/MACs
- [ ] Sortable tables
- [ ] Collapsible sections
- [ ] Keyboard shortcuts
- [ ] Export to CSV/JSON

### Visualization
- [ ] Chart.js integration
- [ ] Real-time graph updates
- [ ] Zoom/pan for historical data
- [ ] Custom color schemes per theme

### Mobile Optimization
- [ ] Touch-friendly controls
- [ ] Swipe navigation
- [ ] Responsive charts
- [ ] Condensed mobile views

## Performance Optimization

### Backend
- [ ] Implement metric pre-aggregation
- [ ] Add Redis caching layer
- [ ] Optimize Prometheus queries
- [ ] Batch API requests
- [ ] Implement pagination

### Frontend
- [ ] Lazy loading for charts
- [ ] Virtual scrolling for large tables
- [ ] Progressive enhancement
- [ ] Service worker for offline support

## Security Enhancements

### Authentication (Optional)
- [ ] Basic auth support
- [ ] Integration with router auth
- [ ] Read-only mode
- [ ] IP-based access control

### Security Headers
- [ ] Content Security Policy
- [ ] X-Frame-Options
- [ ] X-Content-Type-Options
- [ ] Strict-Transport-Security

## Testing & Documentation

### Testing
- [ ] Unit tests for metrics client
- [ ] Integration tests for API
- [ ] End-to-end browser tests
- [ ] Performance benchmarks

### Documentation
- [ ] API documentation
- [ ] Configuration guide
- [ ] Troubleshooting guide
- [ ] Development setup guide

## Deployment Enhancements

### Monitoring
- [ ] Dashboard health checks
- [ ] Prometheus metrics for the dashboard itself
- [ ] Error tracking
- [ ] Performance monitoring

### Operations
- [ ] Backup/restore for settings
- [ ] Configuration hot-reload
- [ ] Graceful shutdown
- [ ] Update notifications

## Priority Order

1. **Phase 1 - Core Functionality**
   - Home page with real metrics
   - Network status page
   - Basic API implementation

2. **Phase 2 - Client & DNS**
   - Client monitoring with bandwidth
   - DNS analytics with Blocky integration
   - WebSocket for real-time updates

3. **Phase 3 - Advanced Features**
   - NAT/Port forwarding management
   - QoS visualization
   - System performance details

4. **Phase 4 - Polish**
   - Mobile optimization
   - Advanced visualizations
   - Performance optimizations

## Notes

- Each page should load in under 100ms
- All metrics should update at least every 2 seconds
- Charts should show at least 1 hour of historical data
- Tables should handle 1000+ rows efficiently
- The dashboard should work without JavaScript for basic viewing