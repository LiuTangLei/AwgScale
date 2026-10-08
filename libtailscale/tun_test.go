package libtailscale

import (
	"errors"
	wgtun "github.com/LiuTangLei/wireguard-go/tun"
	"os"
	"testing"
	"time"
)

func TestPendingTUNReadAfterClose(t *testing.T) {
	tun := newPendingTUN()
	if err := tun.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	slab := make([]byte, 256)
	packets := make([]wgtun.ReadPacket, tunBatchSize)
	if _, err := tun.Read(slab, packets); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Read after close = %v, want ErrClosed", err)
	}
}

func TestPendingTUNInjectAfterClose(t *testing.T) {
	tun := newPendingTUN()
	tun.Close()

	if err := tun.InjectInboundPacket([]byte{0x45}); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Inject after close = %v, want ErrClosed", err)
	}
}

func TestPendingTUNInjectEmptyIgnored(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()
	if err := tun.InjectInboundPacket(nil); err != nil {
		t.Fatalf("InjectInboundPacket(nil) = %v, want nil", err)
	}
	if err := tun.InjectInboundPacket([]byte{}); err != nil {
		t.Fatalf("InjectInboundPacket(empty) = %v, want nil", err)
	}
}

func TestPendingTUNBatchRead(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	for i := 0; i < 4; i++ {
		if err := tun.InjectInboundPacket([]byte{byte(i + 1), 0xAA, 0xBB}); err != nil {
			t.Fatalf("Inject %d: %v", i, err)
		}
	}

	slab := make([]byte, 1024)
	packets := make([]wgtun.ReadPacket, tunBatchSize)
	n, err := tun.Read(slab, packets)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if n < 1 {
		t.Fatalf("Read returned %d packets, want >=1", n)
	}
	for i := 0; i < n; i++ {
		if packets[i].Size != 3 {
			t.Errorf("size[%d] = %d, want 3", i, packets[i].Size)
		}
		if slab[packets[i].Offset] != byte(i+1) {
			t.Errorf("packet[%d][0] = %d, want %d", i, slab[packets[i].Offset], i+1)
		}
	}
}

func TestPendingTUNWriteWithoutCallbackDrops(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	bufs := [][]byte{{0x45, 0, 0, 0}}
	n, err := tun.Write(bufs, 0)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if n != 1 {
		t.Fatalf("Write = %d, want 1 (dropped silently)", n)
	}
}

func TestPendingTUNWriteOffsetTooLarge(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()
	tun.SetPacketCallback(&testPacketCallback{})

	bufs := [][]byte{{0x45}}
	if _, err := tun.Write(bufs, 8); err == nil {
		t.Fatalf("Write with offset > buf returned nil, want short buffer error")
	}
}

func TestPendingTUNWriteAfterClose(t *testing.T) {
	tun := newPendingTUN()
	tun.Close()

	if _, err := tun.Write([][]byte{{0x45}}, 0); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("Write after close = %v, want ErrClosed", err)
	}
}

func TestPendingTUNCloseIdempotent(t *testing.T) {
	tun := newPendingTUN()
	if err := tun.Close(); err != nil {
		t.Fatalf("Close 1: %v", err)
	}
	if err := tun.Close(); err != nil {
		t.Fatalf("Close 2: %v", err)
	}
}

func TestPendingTUNReadUnblocksOnClose(t *testing.T) {
	tun := newPendingTUN()
	done := make(chan error, 1)
	go func() {
		slab := make([]byte, 256)
		packets := make([]wgtun.ReadPacket, tunBatchSize)
		_, err := tun.Read(slab, packets)
		done <- err
	}()

	// Give the goroutine a chance to block.
	time.Sleep(20 * time.Millisecond)
	tun.Close()

	select {
	case err := <-done:
		if !errors.Is(err, os.ErrClosed) {
			t.Fatalf("Read returned %v, want ErrClosed", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Read did not unblock after Close")
	}
}

func TestPendingTUNEvents(t *testing.T) {
	tun := newPendingTUN()
	defer tun.Close()

	select {
	case <-tun.Events():
	case <-time.After(time.Second):
		t.Fatalf("expected initial Event")
	}
}

func TestPendingTUNSlabSpacingAndRetainedPacket(t *testing.T) {
	dev := newPendingTUN()
	defer dev.Close()
	for _, p := range [][]byte{{1, 2, 3}, {4, 5, 6}} {
		if err := dev.InjectInboundPacket(p); err != nil {
			t.Fatal(err)
		}
	}
	packets := make([]wgtun.ReadPacket, tunBatchSize)
	// Exactly one packet plus required leading/trailing headroom fits.
	slab := make([]byte, 2*wgtun.ReadPacketSpacing+3)
	for want := byte(1); want <= 4; want += 3 {
		n, err := dev.Read(slab, packets)
		if err != nil || n != 1 {
			t.Fatalf("Read = %d, %v", n, err)
		}
		p := packets[0]
		if p.Offset != wgtun.ReadPacketSpacing || p.Size != 3 || slab[p.Offset] != want {
			t.Fatalf("packet = %+v bytes = %v", p, slab[p.Offset:p.Offset+p.Size])
		}
	}
}
