package libtailscale

import (
	"encoding/json"
	"fmt"
	"log"
	"net/netip"
	"sync"

	"tailscale.com/net/dns"
	"tailscale.com/wgengine/router"
)

var coreTunnelRoutes = []netip.Prefix{
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("fd7a:115c:a1e0::/48"),
}

var exitNodePublicDNSServers = []string{
	"8.8.8.8",
	"8.8.4.4",
}

var tailscaleServiceDNSServers = map[string]bool{
	"100.100.100.100":    true,
	"fd7a:115c:a1e0::53": true,
}

// TunnelConfig is the JSON-serializable tunnel configuration pushed to Swift.
// It contains everything NEPacketTunnelProvider needs to call
// setTunnelNetworkSettings.
type TunnelConfig struct {
	// Routes
	LocalAddresses []string `json:"localAddresses"` // e.g. ["100.64.0.2/32", "fd7a:115c:a1e0::1/128"]
	Routes         []string `json:"routes"`         // CIDR routes to include
	ExcludeRoutes  []string `json:"excludeRoutes,omitempty"`

	// DNS
	DNSServers      []string `json:"dnsServers"`
	DNSDomains      []string `json:"dnsDomains"`
	DNSMatchDomains []string `json:"dnsMatchDomains,omitempty"`

	// Tunnel
	MTU int `json:"mtu"`
}

// tunnelConfigManager holds the callback to Swift and serializes config updates.
type tunnelConfigManager struct {
	mu             sync.Mutex
	cb             TunnelConfigCallback
	lastConfigJSON []byte
}

func (m *tunnelConfigManager) setCallback(cb TunnelConfigCallback) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cb = cb
	lastConfigJSON := append([]byte(nil), m.lastConfigJSON...)

	if cb != nil && len(lastConfigJSON) > 0 {
		if err := cb.OnTunnelConfigUpdate(lastConfigJSON); err != nil {
			log.Printf("replay tunnel config: %v", err)
		}
	}
}

func (m *tunnelConfigManager) onConfigUpdate(rcfg *router.Config, dcfg *dns.OSConfig) error {
	if rcfg == nil {
		// Tunnel being torn down
		m.mu.Lock()
		m.lastConfigJSON = nil
		m.mu.Unlock()
		return nil
	}

	tc := TunnelConfig{
		LocalAddresses:  []string{},
		Routes:          []string{},
		DNSServers:      []string{},
		DNSDomains:      []string{},
		DNSMatchDomains: []string{},
		MTU:             rcfg.NewMTU,
	}
	if tc.MTU <= 0 {
		tc.MTU = defaultMTU
	}

	// Local addresses
	for _, addr := range rcfg.LocalAddrs {
		tc.LocalAddresses = append(tc.LocalAddresses, addr.String())
	}

	// Routes
	for _, route := range rcfg.Routes {
		tc.Routes = append(tc.Routes, route.String())
	}
	tc.Routes = appendMissingCoreTunnelRoutes(tc.Routes)

	// Excluded routes (routes that should stay outside the tunnel).
	for _, route := range rcfg.LocalRoutes {
		if shouldSkipExcludeRoute(route) {
			continue
		}
		tc.ExcludeRoutes = append(tc.ExcludeRoutes, route.String())
	}

	// DNS
	if dcfg != nil {
		for _, ns := range dcfg.Nameservers {
			tc.DNSServers = append(tc.DNSServers, ns.String())
		}
		for _, d := range dcfg.SearchDomains {
			tc.DNSDomains = append(tc.DNSDomains, d.WithoutTrailingDot())
		}
		for _, d := range dcfg.MatchDomains {
			tc.DNSMatchDomains = append(tc.DNSMatchDomains, d.WithoutTrailingDot())
		}
	}

	// Fallback: if no DNS servers from Go, use MagicDNS default
	if len(tc.DNSServers) == 0 {
		tc.DNSServers = []string{"100.100.100.100"}
	}
	if hasDefaultRoute(tc.Routes) && dnsServersAreTailscaleServiceIPs(tc.DNSServers) {
		log.Printf("exit node: using public DNS servers for NetworkExtension DNS to avoid PeerAPI DNS proxy timeout")
		tc.DNSServers = append([]string(nil), exitNodePublicDNSServers...)
	}

	configJSON, err := json.Marshal(tc)
	if err != nil {
		return fmt.Errorf("marshal tunnel config: %w", err)
	}
	m.mu.Lock()
	m.lastConfigJSON = append([]byte(nil), configJSON...)
	cb := m.cb

	if cb == nil {
		m.mu.Unlock()
		return nil
	}

	err = cb.OnTunnelConfigUpdate(configJSON)
	m.mu.Unlock()
	if err != nil {
		log.Printf("tunnel config: callback failed: %v", err)
	}
	return err
}

func appendMissingCoreTunnelRoutes(routes []string) []string {
	seen := make(map[string]bool, len(routes)+len(coreTunnelRoutes))
	for _, route := range routes {
		seen[route] = true
	}
	for _, route := range coreTunnelRoutes {
		routeStr := route.String()
		if !seen[routeStr] {
			routes = append(routes, routeStr)
			seen[routeStr] = true
		}
	}
	return routes
}

func shouldSkipExcludeRoute(route netip.Prefix) bool {
	if route.Addr().IsLoopback() {
		return true
	}
	route = route.Masked()
	for _, coreRoute := range coreTunnelRoutes {
		if route.Overlaps(coreRoute.Masked()) {
			return true
		}
	}
	return false
}

func hasDefaultRoute(routes []string) bool {
	for _, route := range routes {
		prefix, err := netip.ParsePrefix(route)
		if err != nil {
			continue
		}
		prefix = prefix.Masked()
		if (prefix.Addr().Is4() && prefix.Bits() == 0) || (prefix.Addr().Is6() && prefix.Bits() == 0) {
			return true
		}
	}
	return false
}

func dnsServersAreTailscaleServiceIPs(servers []string) bool {
	if len(servers) == 0 {
		return false
	}
	for _, server := range servers {
		if !tailscaleServiceDNSServers[server] {
			return false
		}
	}
	return true
}

// setTunnelConfigCallback is called from the exported SetTunnelConfigCallback.
func (a *App) setTunnelConfigCallback(cb TunnelConfigCallback) {
	a.tunnelConfigMgr.setCallback(cb)
}
