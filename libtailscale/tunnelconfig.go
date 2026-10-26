package libtailscale

import (
	"bytes"
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
	mu                        sync.Mutex
	cb                        TunnelConfigCallback
	lastConfigJSON            []byte
	lastConfigDelivered       bool
	defaultRouteExcludeRoutes func() []netip.Prefix
}

func (m *tunnelConfigManager) setDefaultRouteExcludeRoutes(fn func() []netip.Prefix) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.defaultRouteExcludeRoutes = fn
}

func (m *tunnelConfigManager) getDefaultRouteExcludeRoutes() []netip.Prefix {
	m.mu.Lock()
	fn := m.defaultRouteExcludeRoutes
	m.mu.Unlock()
	if fn == nil {
		return nil
	}
	return fn()
}

func (m *tunnelConfigManager) setCallback(cb TunnelConfigCallback) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cb = cb
	m.lastConfigDelivered = false
	lastConfigJSON := append([]byte(nil), m.lastConfigJSON...)

	if cb != nil && len(lastConfigJSON) > 0 {
		if err := cb.OnTunnelConfigUpdate(lastConfigJSON); err != nil {
			log.Printf("replay tunnel config: %v", err)
		} else {
			m.lastConfigDelivered = true
		}
	}
}

func (m *tunnelConfigManager) onConfigUpdate(rcfg *router.Config, dcfg *dns.OSConfig) error {
	if rcfg == nil {
		// Tunnel being torn down
		m.mu.Lock()
		m.lastConfigJSON = nil
		m.lastConfigDelivered = false
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
		tc.Routes = append(tc.Routes, route.Masked().String())
	}
	hasDefaultRoute := hasDefaultRoute(tc.Routes)
	if hasDefaultRoute {
		tc.Routes = appendMissingCoreTunnelRoutes(tc.Routes)
	}

	// Excluded routes (routes that should stay outside the tunnel).
	for _, route := range rcfg.LocalRoutes {
		tc.ExcludeRoutes = appendExcludeRoute(tc.ExcludeRoutes, route)
	}
	if hasDefaultRoute {
		underlayExcludeStart := len(tc.ExcludeRoutes)
		for _, route := range m.getDefaultRouteExcludeRoutes() {
			tc.ExcludeRoutes = appendExcludeRoute(tc.ExcludeRoutes, route)
		}
		if len(tc.ExcludeRoutes) > underlayExcludeStart {
			log.Printf("exit node: excluding underlay routes from NetworkExtension tunnel: %v", tc.ExcludeRoutes[underlayExcludeStart:])
		}
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
	// Preserve the core's resolver and split-DNS policy even with an exit
	// node. Replacing its service IP with LAN/public DNS bypasses MagicDNS
	// and sends private tailnet names to a resolver that cannot answer them.

	log.Printf("tunnel config: localAddrs=%d routes=%d excludeRoutes=%d dnsServers=%d searchDomains=%d matchDomains=%d mtu=%d hasDefaultRoute=%t",
		len(tc.LocalAddresses),
		len(tc.Routes),
		len(tc.ExcludeRoutes),
		len(tc.DNSServers),
		len(tc.DNSDomains),
		len(tc.DNSMatchDomains),
		tc.MTU,
		hasDefaultRoute,
	)

	configJSON, err := json.Marshal(tc)
	if err != nil {
		return fmt.Errorf("marshal tunnel config: %w", err)
	}
	m.mu.Lock()
	if bytes.Equal(m.lastConfigJSON, configJSON) && (m.cb == nil || m.lastConfigDelivered) {
		m.mu.Unlock()
		return nil
	}
	m.lastConfigJSON = append([]byte(nil), configJSON...)
	m.lastConfigDelivered = false
	cb := m.cb

	if cb == nil {
		m.mu.Unlock()
		return nil
	}

	err = cb.OnTunnelConfigUpdate(configJSON)
	// Keep the latest config for a new callback, but only deduplicate after
	// delivery succeeds. A failed callback must not suppress the next retry.
	m.lastConfigDelivered = err == nil
	m.mu.Unlock()
	if err != nil {
		log.Printf("tunnel config: callback failed: %v", err)
	}
	return err
}

func shouldSkipExcludeRoute(route netip.Prefix) bool {
	return route.Addr().IsLoopback()
}

func appendExcludeRoute(routes []string, route netip.Prefix) []string {
	if shouldSkipExcludeRoute(route) {
		return routes
	}
	routeStr := route.Masked().String()
	for _, existing := range routes {
		if existing == routeStr {
			return routes
		}
	}
	return append(routes, routeStr)
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

// setTunnelConfigCallback is called from the exported SetTunnelConfigCallback.
func (a *App) setTunnelConfigCallback(cb TunnelConfigCallback) {
	a.tunnelConfigMgr.setCallback(cb)
}
