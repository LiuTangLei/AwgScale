package libtailscale

import (
	"context"
	"errors"
	"os"
	"testing"

	"tailscale.com/ipn"
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

	bufs := [][]byte{make([]byte, 64)}
	sizes := []int{0}
	n, err := tun.Read(bufs, sizes, 4)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if n != 1 {
		t.Fatalf("Read returned %d, want 1", n)
	}
	if sizes[0] != len(packet) || string(bufs[0][4:4+sizes[0]]) != string(packet) {
		t.Fatalf("Read packet = %v size %d, want %v", bufs[0][4:4+sizes[0]], sizes[0], packet)
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

func TestAppStopIdempotentWithoutBackend(t *testing.T) {
	a := &App{cancel: func() {}}
	a.Stop()
	a.Stop()
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
