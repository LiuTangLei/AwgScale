package libtailscale

import (
	"errors"
	"net/netip"
	"testing"

	"tailscale.com/net/dns"
	"tailscale.com/wgengine/router"
)

func TestVPNFacadeSupportsSplitDNS(t *testing.T) {
	vf := &VPNFacade{}
	if !vf.SupportsSplitDNS() {
		t.Fatalf("SupportsSplitDNS = false, want true")
	}
}

func TestVPNFacadeSetThenReconfigureCallsSetBoth(t *testing.T) {
	var gotR *router.Config
	var gotD *dns.OSConfig
	vf := &VPNFacade{
		SetBoth: func(r *router.Config, d *dns.OSConfig) error {
			gotR, gotD = r, d
			return nil
		},
		InitialMTU: 1280,
	}

	rc := &router.Config{
		LocalAddrs: []netip.Prefix{netip.MustParsePrefix("100.64.0.5/32")},
	}
	if err := vf.Set(rc); err != nil {
		t.Fatalf("Set: %v", err)
	}
	dc := dns.OSConfig{Nameservers: []netip.Addr{netip.MustParseAddr("100.100.100.100")}}
	if err := vf.SetDNS(dc); err != nil {
		t.Fatalf("SetDNS: %v", err)
	}
	if err := vf.ReconfigureVPN(); err != nil {
		t.Fatalf("ReconfigureVPN: %v", err)
	}
	if gotR == nil || gotR.NewMTU != 1280 {
		t.Errorf("SetBoth router NewMTU = %v, want 1280", gotR)
	}
	if gotD == nil || len(gotD.Nameservers) != 1 {
		t.Errorf("SetBoth dns = %v", gotD)
	}
}

func TestVPNFacadeSetNilClearsConfig(t *testing.T) {
	vf := &VPNFacade{
		SetBoth: func(r *router.Config, d *dns.OSConfig) error { return nil },
	}
	rc := &router.Config{LocalAddrs: []netip.Prefix{netip.MustParsePrefix("100.64.0.5/32")}}
	if err := vf.Set(rc); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if err := vf.Set(nil); err != nil {
		t.Fatalf("Set(nil): %v", err)
	}
	if vf.rcfg != nil {
		t.Fatalf("vf.rcfg = %v, want nil", vf.rcfg)
	}
}

func TestVPNFacadeGetBaseConfigUnsupported(t *testing.T) {
	vf := &VPNFacade{}
	_, err := vf.GetBaseConfig()
	if !errors.Is(err, dns.ErrGetBaseConfigNotSupported) {
		t.Fatalf("GetBaseConfig err = %v, want ErrGetBaseConfigNotSupported", err)
	}
}

func TestVPNFacadeCloseCallsSetBothNil(t *testing.T) {
	called := false
	vf := &VPNFacade{
		SetBoth: func(r *router.Config, d *dns.OSConfig) error {
			if r != nil || d != nil {
				t.Errorf("Close should pass nil/nil, got %v %v", r, d)
			}
			called = true
			return nil
		},
	}
	if err := vf.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if !called {
		t.Fatalf("SetBoth not called by Close")
	}
}

func TestVPNFacadeCloseWithoutSetBoth(t *testing.T) {
	vf := &VPNFacade{}
	if err := vf.Close(); err != nil {
		t.Fatalf("Close without SetBoth = %v, want nil", err)
	}
}
