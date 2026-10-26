package libtailscale

import (
	"context"
	"errors"
	"net/http"
	"net/netip"
	"os"
	"sync"
	"testing"
	"time"

	wgtun "github.com/LiuTangLei/wireguard-go/tun"
	"tailscale.com/ipn"
	"tailscale.com/net/netmon"
	"tailscale.com/util/eventbus/eventbustest"
)

type testAppContext struct {
	store             map[string]string
	platformDNSConfig string
	googleDNSFallback bool
}

func newTestAppContext() *testAppContext {
	return &testAppContext{store: make(map[string]string)}
}

func (f *testAppContext) Log(tag, logLine string)                    {}
func (f *testAppContext) EncryptToPref(key, value string) error      { f.store[key] = value; return nil }
func (f *testAppContext) DecryptFromPref(key string) (string, error) { return f.store[key], nil }
func (f *testAppContext) GetStateStoreKeysJSON() string              { return "[]" }
func (f *testAppContext) GetOSVersion() (string, error)              { return "iOS 18.0", nil }
func (f *testAppContext) GetDeviceName() (string, error)             { return "iPhone", nil }
func (f *testAppContext) GetInstallSource() string                   { return "appstore" }
func (f *testAppContext) ShouldUseGoogleDNSFallback() bool           { return f.googleDNSFallback }
func (f *testAppContext) IsChromeOS() (bool, error)                  { return false, nil }
func (f *testAppContext) GetInterfacesAsJson() (string, error)       { return "[]", nil }
func (f *testAppContext) GetPlatformDNSConfig() string               { return f.platformDNSConfig }
func (f *testAppContext) GetSyspolicyStringValue(key string) (string, error) {
	return "", nil
}
func (f *testAppContext) GetSyspolicyBooleanValue(key string) (bool, error) {
	return false, nil
}
func (f *testAppContext) GetSyspolicyStringArrayJSONValue(key string) (string, error) {
	return "[]", nil
}
func (f *testAppContext) HardwareAttestationKeySupported() bool         { return false }
func (f *testAppContext) HardwareAttestationKeyCreate() (string, error) { return "", nil }
func (f *testAppContext) HardwareAttestationKeyRelease(id string) error { return nil }
func (f *testAppContext) HardwareAttestationKeyPublic(id string) ([]byte, error) {
	return nil, nil
}
func (f *testAppContext) HardwareAttestationKeySign(id string, data []byte) ([]byte, error) {
	return nil, nil
}
func (f *testAppContext) HardwareAttestationKeyLoad(id string) error { return nil }

func TestStateStoreReadWrite(t *testing.T) {
	ctx := newTestAppContext()
	s := newStateStore(ctx)

	err := s.WriteState("testkey", []byte("testvalue"))
	if err != nil {
		t.Fatalf("WriteState: %v", err)
	}

	data, err := s.ReadState("testkey")
	if err != nil {
		t.Fatalf("ReadState: %v", err)
	}
	if string(data) != "testvalue" {
		t.Fatalf("ReadState = %q, want testvalue", data)
	}
}

func TestStateStoreReadMissing(t *testing.T) {
	ctx := newTestAppContext()
	s := newStateStore(ctx)

	_, err := s.ReadState("missing")
	if err != ipn.ErrStateNotExist {
		t.Fatalf("ReadState missing = %v, want ErrStateNotExist", err)
	}
}

func TestPendingTUNMTU(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	mtu, err := tun.MTU()
	if err != nil {
		t.Fatalf("MTU: %v", err)
	}
	if mtu != defaultMTU {
		t.Fatalf("MTU = %d, want %d", mtu, defaultMTU)
	}
}

func TestGetDNSBaseConfigUsesPlatformDNS(t *testing.T) {
	ctx := newTestAppContext()
	ctx.platformDNSConfig = "1.1.1.1 2606:4700:4700::1111\nlan"
	b := &backend{appCtx: ctx}

	cfg, err := b.getDNSBaseConfig()
	if err != nil {
		t.Fatalf("getDNSBaseConfig: %v", err)
	}
	if got, want := len(cfg.Nameservers), 2; got != want {
		t.Fatalf("len(Nameservers) = %d, want %d", got, want)
	}
	if got, want := cfg.Nameservers[0].String(), "1.1.1.1"; got != want {
		t.Fatalf("Nameservers[0] = %q, want %q", got, want)
	}
	if got, want := cfg.SearchDomains[0].WithoutTrailingDot(), "lan"; got != want {
		t.Fatalf("SearchDomains[0] = %q, want %q", got, want)
	}
}

func TestGetDNSBaseConfigGoogleFallback(t *testing.T) {
	ctx := newTestAppContext()
	ctx.googleDNSFallback = true
	b := &backend{appCtx: ctx}

	cfg, err := b.getDNSBaseConfig()
	if err != nil {
		t.Fatalf("getDNSBaseConfig: %v", err)
	}
	if got, want := len(cfg.Nameservers), len(googleDNSServers); got != want {
		t.Fatalf("len(Nameservers) = %d, want %d", got, want)
	}
	if got, want := cfg.Nameservers[0], googleDNSServers[0]; got != want {
		t.Fatalf("Nameservers[0] = %v, want %v", got, want)
	}
}

func TestGetDNSBaseConfigNoFallbackByDefault(t *testing.T) {
	ctx := newTestAppContext()
	b := &backend{appCtx: ctx}

	cfg, err := b.getDNSBaseConfig()
	if err != nil {
		t.Fatalf("getDNSBaseConfig: %v", err)
	}
	if got := len(cfg.Nameservers); got != 0 {
		t.Fatalf("len(Nameservers) = %d, want 0", got)
	}
}

func TestPendingTUNName(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	name, err := tun.Name()
	if err != nil {
		t.Fatalf("Name: %v", err)
	}
	if name != "utun_ts" {
		t.Fatalf("Name = %q, want utun_ts", name)
	}
}

func TestPendingTUNInjectRead(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	packet := []byte{0x45, 0, 0, 1}
	if err := tun.InjectInboundPacket(packet); err != nil {
		t.Fatalf("InjectInboundPacket: %v", err)
	}

	slab := make([]byte, 256)
	packets := make([]wgtun.ReadPacket, tunBatchSize)
	n, err := tun.Read(slab, packets)
	if err != nil || n != 1 {
		t.Fatalf("Read = %d, %v", n, err)
	}
	p := packets[0]
	if p.Size != len(packet) || string(slab[p.Offset:p.Offset+p.Size]) != string(packet) {
		t.Fatalf("Read packet = %+v, want %v", p, packet)
	}

}

func TestPendingTUNWriteCallback(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	cb := &testPacketCallback{}
	tun.SetPacketCallback(cb)
	bufs := [][]byte{{0, 0, 0, 0, 0x60, 1, 2, 3}}
	n, err := tun.Write(bufs, 4)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if n != 1 {
		t.Fatalf("Write returned %d, want 1", n)
	}
	if string(cb.packet) != string([]byte{0x60, 1, 2, 3}) {
		t.Fatalf("callback packet = %v", cb.packet)
	}
}

type testPacketCallback struct {
	packet []byte
}

func (cb *testPacketCallback) OnPacket(packet []byte) error {
	cb.packet = append([]byte(nil), packet...)
	return nil
}

func TestAdaptInputStream(t *testing.T) {
	in := &testInputStream{data: []byte("hello world")}
	rc := adaptInputStream(in)
	defer rc.Close()

	buf := make([]byte, 128)
	n, _ := rc.Read(buf)
	if string(buf[:n]) != "hello world" {
		t.Fatalf("Read = %q, want hello world", buf[:n])
	}
}

func TestAppInjectAndCallbackBeforeBackend(t *testing.T) {
	a := &App{}
	if err := a.InjectInboundPacket([]byte{0x45}); err == nil {
		t.Fatalf("InjectInboundPacket without backend = nil, want error")
	}
	// SetPacketCallback before backend should not panic and should be
	// applied later. We can verify the callback is stashed.
	cb := &testPacketCallback{}
	a.SetPacketCallback(cb)
	if a.packetCallback != cb {
		t.Fatalf("packetCallback not stored")
	}
}

func TestBackendPeerForIPBeforeLocalBackendIsReady(t *testing.T) {
	var b *backend
	if _, ok := b.peerForIP(netip.MustParseAddr("100.64.0.1")); ok {
		t.Fatal("nil backend unexpectedly resolved a peer")
	}
	b = &backend{}
	if _, ok := b.peerForIP(netip.MustParseAddr("100.64.0.1")); ok {
		t.Fatal("backend without LocalBackend unexpectedly resolved a peer")
	}
}

func TestAppStopIdempotentWithoutBackend(t *testing.T) {
	a := &App{cancel: func() {}}
	a.Stop()
	a.Stop()
}

func TestAppNetworkChangedForcesMonitorNotification(t *testing.T) {
	mon, err := netmon.New(eventbustest.NewBus(t), t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	changes := make(chan struct{}, 8)
	unregister := mon.RegisterChangeCallback(func(*netmon.ChangeDelta) {
		select {
		case changes <- struct{}{}:
		default:
		}
	})
	defer unregister()
	a := &App{backendState: &backend{netMon: mon}}
	defer a.Stop()
	mon.Start()
	// Both updates must reach the core even though the interface snapshot
	// need not change. Poll() instead of InjectEvent() would suppress these.
	for range 2 {
		a.NetworkChanged()
		select {
		case <-changes:
		case <-time.After(3 * time.Second):
			t.Fatal("platform path update did not notify network monitor")
		}
	}
	a.Stop()
	a.NetworkChanged() // a late platform callback must ignore the stopped backend.
}

func TestAppNetworkChangedBeforeBackendAndDuringStop(t *testing.T) {
	a := &App{}
	a.NetworkChanged()
	a.backendState = &backend{}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for range 100 {
			a.NetworkChanged()
		}
	}()
	go func() {
		defer wg.Done()
		a.Stop()
	}()
	wg.Wait()
}

func TestAppStopUnblocksReadyWaiters(t *testing.T) {
	a := &App{ready: make(chan struct{}), cancel: func() {}}
	done := make(chan error, 1)
	go func() {
		done <- a.waitReady()
	}()

	a.Stop()

	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("waitReady after Stop = %v, want context.Canceled", err)
	}
	if err := a.waitReady(); !errors.Is(err, context.Canceled) {
		t.Fatalf("second waitReady after Stop = %v, want context.Canceled", err)
	}
}

func TestAppWaitReadyZeroValue(t *testing.T) {
	a := &App{}
	if err := a.waitReady(); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("zero-value waitReady = %v, want os.ErrNotExist", err)
	}
}

func TestPublishBackendMakesHandlerReady(t *testing.T) {
	a := &App{ready: make(chan struct{})}
	b := &backend{tunDev: newPendingTUN()}
	defer a.Stop()
	// The callback may be registered while backend creation is in progress.
	cb := &testPacketCallback{}
	a.SetPacketCallback(cb)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ready"))
	})
	if !a.publishBackend(b, handler) {
		t.Fatal("backend was not published")
	}
	if err := a.waitReady(); err != nil {
		t.Fatal(err)
	}
	resp, err := a.callLocalAPI(1000, "GET", "/test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, err := resp.BodyBytes()
	if err != nil || string(got) != "ready" {
		t.Fatalf("ready response = %q, %v", got, err)
	}
	if _, err := b.tunDev.Write([][]byte{{0x45}}, 0); err != nil {
		t.Fatal(err)
	}
	if string(cb.packet) != string([]byte{0x45}) {
		t.Fatal("callback registered during startup was lost")
	}
}

func TestPublishBackendRacingStop(t *testing.T) {
	for range 100 {
		a := &App{ready: make(chan struct{})}
		b := &backend{tunDev: newPendingTUN()}
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			if !a.publishBackend(b, http.NotFoundHandler()) {
				a.closeBackendState(b)
			}
		}()
		go func() {
			defer wg.Done()
			a.Stop()
		}()
		wg.Wait()
		if err := a.waitReady(); !errors.Is(err, context.Canceled) {
			t.Fatalf("ready after Stop = %v", err)
		}
		if !b.tunDev.closedNow() {
			t.Fatal("stopped startup leaked its TUN")
		}
		a.mu.Lock()
		published := a.backendState != nil || a.localAPIHandler != nil
		a.mu.Unlock()
		if published {
			t.Fatal("stopped backend was published")
		}
	}
}

type testInputStream struct {
	data []byte
	done bool
}

func (s *testInputStream) Read() ([]byte, error) {
	if s.done {
		return nil, nil
	}
	s.done = true
	return s.data, nil
}

func (s *testInputStream) Close() error {
	s.done = true
	return nil
}
