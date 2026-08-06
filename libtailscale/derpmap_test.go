package libtailscale

import (
	"context"
	"net/netip"
	"slices"
	"sync/atomic"
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
		t.Fatalf("official DERP hostname unexpectedly resolved: %s", host)
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

func TestEnsureDERPMapSourceCachesNoChangeEvaluation(t *testing.T) {
	app := new(App)
	dm := testDERPMap("relay.example.net")
	lookupCount := 0
	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		lookupCount++
		return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
	})
	install := func(*tailcfg.DERPMap) bool {
		t.Fatal("unchanged DERP map unexpectedly installed")
		return false
	}

	current := func() (*tailcfg.DERPMap, string) {
		return dm, "https://controlplane.tailscale.com"
	}
	if !app.ensureCurrentUsableDERPMap(current, install) {
		t.Fatal("unchanged DERP map was not treated as usable")
	}
	if !app.ensureCurrentUsableDERPMap(current, install) {
		t.Fatal("cached unchanged DERP map was not treated as usable")
	}
	if lookupCount != 1 {
		t.Fatalf("DERP lookup count = %d, want 1", lookupCount)
	}
}

func TestEnsureDERPMapSourceRetriesAndReappliesCachedSanitizedMap(t *testing.T) {
	app := new(App)
	dm := testDERPMap("relay.example.net")
	dm.Regions[1001].Nodes[0].IPv4 = "127.0.0.1"
	lookupCount := 0
	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		lookupCount++
		return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
	})

	installCount := 0
	install := func(got *tailcfg.DERPMap) bool {
		installCount++
		if got == nil || got.Regions[1001].Nodes[0].IPv4 != "8.8.8.8" {
			t.Fatalf("unexpected sanitized DERP map: %#v", got)
		}
		return installCount > 1
	}

	current := func() (*tailcfg.DERPMap, string) {
		return dm, "https://controlplane.tailscale.com"
	}
	if app.ensureCurrentUsableDERPMap(current, install) {
		t.Fatal("failed DERP map install was reported successful")
	}
	if !app.ensureCurrentUsableDERPMap(current, install) {
		t.Fatal("failed DERP map install was not retried")
	}
	if !app.ensureCurrentUsableDERPMap(current, install) {
		t.Fatal("cached sanitized DERP map was not reapplied")
	}
	if installCount != 3 {
		t.Fatalf("install count = %d, want 3", installCount)
	}
	if lookupCount != 1 {
		t.Fatalf("DERP lookup count = %d, want 1", lookupCount)
	}
}

func TestEnsureCurrentDERPMapDoesNotLeaveStaleSourceInstalled(t *testing.T) {
	app := new(App)
	first := testDERPMap("first.example.net")
	first.Regions[1001].Nodes[0].IPv4 = "127.0.0.1"
	second := testDERPMap("second.example.net")
	second.Regions[1001].Nodes[0].IPv4 = "127.0.0.1"
	var currentSource atomic.Pointer[tailcfg.DERPMap]
	currentSource.Store(first)

	withDERPLookup(t, func(_ context.Context, _ string, host string) ([]netip.Addr, error) {
		switch host {
		case "first.example.net":
			return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
		case "second.example.net":
			return []netip.Addr{netip.MustParseAddr("9.9.9.9")}, nil
		default:
			return nil, nil
		}
	})

	firstInstallStarted := make(chan struct{})
	continueFirstInstall := make(chan struct{})
	installed := make(chan string, 2)
	done := make(chan bool, 1)
	go func() {
		done <- app.ensureCurrentUsableDERPMap(func() (*tailcfg.DERPMap, string) {
			return currentSource.Load(), "https://controlplane.tailscale.com"
		}, func(dm *tailcfg.DERPMap) bool {
			ipv4 := dm.Regions[1001].Nodes[0].IPv4
			installed <- ipv4
			if ipv4 == "8.8.8.8" {
				close(firstInstallStarted)
				<-continueFirstInstall
			}
			return true
		})
	}()

	<-firstInstallStarted
	// Replace the source from another goroutine while installation of the old
	// sanitized map is still in progress.
	currentSource.Store(second)
	close(continueFirstInstall)
	ok := <-done
	if !ok {
		t.Fatal("latest DERP map was not installed")
	}
	close(installed)
	var got []string
	for ipv4 := range installed {
		got = append(got, ipv4)
	}
	if want := []string{"8.8.8.8", "9.9.9.9"}; !slices.Equal(got, want) {
		t.Fatalf("installed DERP IPv4 sequence = %v, want %v", got, want)
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
