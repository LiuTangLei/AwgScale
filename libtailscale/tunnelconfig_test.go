package libtailscale

import (
	"encoding/json"
	"net/netip"
	"sync"
	"testing"

	"tailscale.com/net/dns"
	"tailscale.com/util/dnsname"
	"tailscale.com/wgengine/router"
)

type recordingCallback struct {
	mu      sync.Mutex
	configs [][]byte
	err     error
}

func (r *recordingCallback) OnTunnelConfigUpdate(configJSON []byte) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.configs = append(r.configs, append([]byte(nil), configJSON...))
	return r.err
}

func (r *recordingCallback) snapshot() [][]byte {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([][]byte, len(r.configs))
	for i, c := range r.configs {
		out[i] = append([]byte(nil), c...)
	}
	return out
}

func sampleRouterConfig() *router.Config {
	return &router.Config{
		LocalAddrs: []netip.Prefix{
			netip.MustParsePrefix("100.64.0.2/32"),
			netip.MustParsePrefix("fd7a:115c:a1e0::1/128"),
		},
		Routes: []netip.Prefix{
			netip.MustParsePrefix("10.1.0.0/16"),
			netip.MustParsePrefix("fd00::/8"),
		},
		LocalRoutes: []netip.Prefix{
			netip.MustParsePrefix("192.168.1.0/24"),
		},
		NewMTU: 1380,
	}
}

func sampleDNSConfig(t *testing.T) *dns.OSConfig {
	t.Helper()
	search, err := dnsname.ToFQDN("example.com")
	if err != nil {
		t.Fatalf("ToFQDN: %v", err)
	}
	match, err := dnsname.ToFQDN("ts.net")
	if err != nil {
		t.Fatalf("ToFQDN match: %v", err)
	}
	return &dns.OSConfig{
		Nameservers:   []netip.Addr{netip.MustParseAddr("100.100.100.100")},
		SearchDomains: []dnsname.FQDN{search},
		MatchDomains:  []dnsname.FQDN{match},
	}
}

func TestTunnelConfigOnConfigUpdateDelivers(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	if err := mgr.onConfigUpdate(sampleRouterConfig(), sampleDNSConfig(t)); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	if len(configs) != 1 {
		t.Fatalf("got %d configs, want 1", len(configs))
	}

	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got := tc.MTU; got != 1380 {
		t.Errorf("MTU = %d, want 1380", got)
	}
	if len(tc.LocalAddresses) != 2 {
		t.Errorf("LocalAddresses = %v", tc.LocalAddresses)
	}
	for _, want := range []string{"10.1.0.0/16", "fd00::/8"} {
		if !containsString(tc.Routes, want) {
			t.Errorf("Routes = %v, missing %s", tc.Routes, want)
		}
	}
	for _, unwanted := range []string{"100.64.0.0/10", "fd7a:115c:a1e0::/48"} {
		if containsString(tc.Routes, unwanted) {
			t.Errorf("Routes = %v, must not add hard-coded %s", tc.Routes, unwanted)
		}
	}
	if len(tc.ExcludeRoutes) != 1 || tc.ExcludeRoutes[0] != "192.168.1.0/24" {
		t.Errorf("ExcludeRoutes = %v", tc.ExcludeRoutes)
	}
	if len(tc.DNSServers) != 1 || tc.DNSServers[0] != "100.100.100.100" {
		t.Errorf("DNSServers = %v", tc.DNSServers)
	}
	if len(tc.DNSDomains) != 1 || tc.DNSDomains[0] != "example.com" {
		t.Errorf("DNSDomains = %v", tc.DNSDomains)
	}
	if len(tc.DNSMatchDomains) != 1 || tc.DNSMatchDomains[0] != "ts.net" {
		t.Errorf("DNSMatchDomains = %v", tc.DNSMatchDomains)
	}
}

// TestTunnelConfigReplaysOnLateCallback verifies the fix where Go pushes a
// config before Swift registers its callback: the cached config should be
// replayed when setCallback is called.
func TestTunnelConfigReplaysOnLateCallback(t *testing.T) {
	mgr := &tunnelConfigManager{}

	if err := mgr.onConfigUpdate(sampleRouterConfig(), sampleDNSConfig(t)); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	cb := &recordingCallback{}
	mgr.setCallback(cb)

	configs := cb.snapshot()
	if len(configs) != 1 {
		t.Fatalf("got %d replayed configs, want 1", len(configs))
	}
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if tc.MTU != 1380 {
		t.Errorf("replayed MTU = %d, want 1380", tc.MTU)
	}
}

func TestTunnelConfigClearedOnTeardown(t *testing.T) {
	mgr := &tunnelConfigManager{}

	if err := mgr.onConfigUpdate(sampleRouterConfig(), sampleDNSConfig(t)); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}
	if err := mgr.onConfigUpdate(nil, nil); err != nil {
		t.Fatalf("teardown: %v", err)
	}

	cb := &recordingCallback{}
	mgr.setCallback(cb)
	if got := cb.snapshot(); len(got) != 0 {
		t.Fatalf("got %d configs after teardown, want 0", len(got))
	}
}

func TestTunnelConfigDefaultMTUFallback(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	rc := sampleRouterConfig()
	rc.NewMTU = 0
	if err := mgr.onConfigUpdate(rc, nil); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	if len(configs) != 1 {
		t.Fatalf("len(configs) = %d", len(configs))
	}
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if tc.MTU != defaultMTU {
		t.Errorf("MTU = %d, want defaultMTU=%d", tc.MTU, defaultMTU)
	}
	// dcfg nil should still trigger the MagicDNS fallback.
	if len(tc.DNSServers) == 0 || tc.DNSServers[0] != "100.100.100.100" {
		t.Errorf("DNSServers = %v, want MagicDNS fallback", tc.DNSServers)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func TestTunnelConfigEmptyRoutesStayEmpty(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	rc := &router.Config{
		LocalAddrs: []netip.Prefix{netip.MustParsePrefix("100.64.0.2/32")},
		NewMTU:     1280,
	}
	if err := mgr.onConfigUpdate(rc, nil); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(tc.Routes) != 0 {
		t.Errorf("Routes = %v, want empty routes to stay empty", tc.Routes)
	}
}

func TestTunnelConfigExcludesLocalRoutesExceptLoopback(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	rc := sampleRouterConfig()
	rc.LocalRoutes = []netip.Prefix{
		netip.MustParsePrefix("100.64.0.0/10"),
		netip.MustParsePrefix("100.64.0.36/32"),
		netip.MustParsePrefix("fd7a:115c:a1e0::/48"),
		netip.MustParsePrefix("127.0.0.1/32"),
		netip.MustParsePrefix("192.168.1.0/24"),
	}

	if err := mgr.onConfigUpdate(rc, nil); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, want := range []string{"100.64.0.0/10", "100.64.0.36/32", "fd7a:115c:a1e0::/48", "192.168.1.0/24"} {
		if !containsString(tc.ExcludeRoutes, want) {
			t.Fatalf("ExcludeRoutes = %v, missing %s", tc.ExcludeRoutes, want)
		}
	}
	for _, forbidden := range []string{"127.0.0.1/32"} {
		if containsString(tc.ExcludeRoutes, forbidden) {
			t.Fatalf("ExcludeRoutes = %v, must not contain %s", tc.ExcludeRoutes, forbidden)
		}
	}
}

func TestTunnelConfigPreservesCustomHeadscaleRoutes(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	rc := &router.Config{
		LocalAddrs: []netip.Prefix{netip.MustParsePrefix("172.18.0.42/32")},
		Routes: []netip.Prefix{
			netip.MustParsePrefix("172.18.0.0/16"),
			netip.MustParsePrefix("10.42.7.9/24"),
		},
		NewMTU: 1280,
	}
	if err := mgr.onConfigUpdate(rc, nil); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, want := range []string{"172.18.0.0/16", "10.42.7.0/24"} {
		if !containsString(tc.Routes, want) {
			t.Fatalf("Routes = %v, missing %s", tc.Routes, want)
		}
	}
	for _, unwanted := range []string{"100.64.0.0/10", "fd7a:115c:a1e0::/48"} {
		if containsString(tc.Routes, unwanted) {
			t.Fatalf("Routes = %v, must not add %s", tc.Routes, unwanted)
		}
	}
}

func TestTunnelConfigExitNodeUsesPublicDNSForSystemResolver(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	rc := sampleRouterConfig()
	rc.Routes = []netip.Prefix{
		netip.MustParsePrefix("0.0.0.0/0"),
		netip.MustParsePrefix("::/0"),
	}
	dcfg := &dns.OSConfig{
		Nameservers: []netip.Addr{
			netip.MustParseAddr("100.100.100.100"),
			netip.MustParseAddr("fd7a:115c:a1e0::53"),
		},
	}

	if err := mgr.onConfigUpdate(rc, dcfg); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !containsString(tc.Routes, "0.0.0.0/0") || !containsString(tc.Routes, "::/0") {
		t.Fatalf("Routes = %v, missing default routes", tc.Routes)
	}
	if len(tc.DNSServers) != len(exitNodePublicDNSServers) {
		t.Fatalf("DNSServers = %v, want %v", tc.DNSServers, exitNodePublicDNSServers)
	}
	for i, want := range exitNodePublicDNSServers {
		if tc.DNSServers[i] != want {
			t.Fatalf("DNSServers = %v, want %v", tc.DNSServers, exitNodePublicDNSServers)
		}
	}
}

func TestTunnelConfigExitNodePreservesCustomDNS(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{}
	mgr.setCallback(cb)

	rc := sampleRouterConfig()
	rc.Routes = []netip.Prefix{netip.MustParsePrefix("0.0.0.0/0")}
	dcfg := &dns.OSConfig{Nameservers: []netip.Addr{netip.MustParseAddr("9.9.9.9")}}

	if err := mgr.onConfigUpdate(rc, dcfg); err != nil {
		t.Fatalf("onConfigUpdate: %v", err)
	}

	configs := cb.snapshot()
	var tc TunnelConfig
	if err := json.Unmarshal(configs[0], &tc); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(tc.DNSServers) != 1 || tc.DNSServers[0] != "9.9.9.9" {
		t.Fatalf("DNSServers = %v, want custom resolver", tc.DNSServers)
	}
}

func TestTunnelConfigCallbackErrorPropagates(t *testing.T) {
	mgr := &tunnelConfigManager{}
	cb := &recordingCallback{err: errFakeCallback}
	mgr.setCallback(cb)

	if err := mgr.onConfigUpdate(sampleRouterConfig(), nil); err != errFakeCallback {
		t.Fatalf("onConfigUpdate err = %v, want errFakeCallback", err)
	}
}

var errFakeCallback = stubError("fake callback error")

type stubError string

func (e stubError) Error() string { return string(e) }
