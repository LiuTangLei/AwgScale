package libtailscale

import (
	"context"
	"net/netip"
	"testing"

	"tailscale.com/tailcfg"
)

func withDERPLookup(t *testing.T, lookup func(context.Context, string, string) ([]netip.Addr, error)) {
	t.Helper()
	oldLookup := derpLookupNetIP
	derpLookupNetIP = lookup
	t.Cleanup(func() {
		derpLookupNetIP = oldLookup
	})
}

func TestSanitizeDERPMapPinsCustomControlDERPHostIPv4(t *testing.T) {
	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		switch host {
		case "ctl2.yesican.top":
			return []netip.Addr{netip.MustParseAddr("198.18.0.6")}, nil
		default:
			return nil, nil
		}
	})

	dm := testDERPMap("ctl2.yesican.top")
	sanitized, changed := sanitizeDERPMapForIOS(dm, "https://ctl.yesican.top")
	if !changed {
		t.Fatal("sanitizeDERPMapForIOS changed = false, want true")
	}
	if got := sanitized.Regions[1001].Nodes[0].HostName; got != "ctl.yesican.top" {
		t.Fatalf("sanitized HostName = %q, want ctl.yesican.top", got)
	}
	if got := sanitized.Regions[1001].Nodes[0].IPv4; got != "141.98.196.111" {
		t.Fatalf("sanitized IPv4 = %q, want 141.98.196.111", got)
	}
	if got := sanitized.Regions[1001].Nodes[0].IPv6; got != "none" {
		t.Fatalf("sanitized IPv6 = %q, want none", got)
	}
	if got := dm.Regions[1001].Nodes[0].IPv4; got != "" {
		t.Fatalf("original DERP map IPv4 mutated to %q", got)
	}
}

func TestSanitizeDERPMapPinsCustomDERPHostWithoutControlURL(t *testing.T) {
	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		if host == "ctl2.yesican.top" {
			return []netip.Addr{netip.MustParseAddr("198.18.0.6")}, nil
		}
		return nil, nil
	})

	dm := testDERPMap("ctl2.yesican.top")
	sanitized, changed := sanitizeDERPMapForIOS(dm, "")
	if !changed {
		t.Fatal("sanitizeDERPMapForIOS changed = false, want true")
	}
	if got := sanitized.Regions[1001].Nodes[0].HostName; got != "ctl.yesican.top" {
		t.Fatalf("sanitized HostName = %q, want ctl.yesican.top", got)
	}
	if got := sanitized.Regions[1001].Nodes[0].IPv4; got != "141.98.196.111" {
		t.Fatalf("sanitized IPv4 = %q, want 141.98.196.111", got)
	}
}

func TestSanitizeDERPMapLeavesOfficialDERPHostUnpinned(t *testing.T) {
	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		if host == "derp1.tailscale.com" {
			return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
		}
		return nil, nil
	})

	dm := testDERPMap("derp1.tailscale.com")
	_, changed := sanitizeDERPMapForIOS(dm, "https://controlplane.tailscale.com")
	if changed {
		t.Fatal("sanitizeDERPMapForIOS changed = true, want false")
	}
}

func TestSanitizeDERPMapSingleLabelHostUsesLanFallback(t *testing.T) {
	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		switch host {
		case "ctl2":
			return []netip.Addr{netip.MustParseAddr("127.3.3.40")}, nil
		case "ctl2.lan":
			return []netip.Addr{netip.MustParseAddr("198.18.2.227")}, nil
		default:
			return nil, nil
		}
	})

	dm := testDERPMap("ctl2")
	sanitized, changed := sanitizeDERPMapForIOS(dm, "https://ctl.yesican.top")
	if !changed {
		t.Fatal("sanitizeDERPMapForIOS changed = false, want true")
	}
	if got := sanitized.Regions[1001].Nodes[0].IPv4; got != "198.18.2.227" {
		t.Fatalf("sanitized IPv4 = %q, want 198.18.2.227", got)
	}
}

func testDERPMap(hostname string) *tailcfg.DERPMap {
	return &tailcfg.DERPMap{
		Regions: map[int]*tailcfg.DERPRegion{
			1001: {
				RegionID:   1001,
				RegionCode: "ctl2",
				Nodes: []*tailcfg.DERPNode{{
					Name:     "1001a",
					RegionID: 1001,
					HostName: hostname,
					DERPPort: 443,
				}},
			},
		},
	}
}
