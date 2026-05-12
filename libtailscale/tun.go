package libtailscale

import (
	"errors"
	"io"
	"log"
	"os"
	"sync"

	"github.com/LiuTangLei/wireguard-go/tun"
)

const defaultMTU = 1280

const tunBatchSize = 32

var errInboundQueueFull = errors.New("tun inbound queue full")

// pendingTUN implements tun.Device for the iOS backend. Swift reads packets
// from NEPacketTunnelFlow and injects them with InjectInboundPacket; packets
// written by wireguard-go are delivered back to Swift via PacketCallback.
type pendingTUN struct {
	events   chan tun.Event
	closed   chan struct{}
	inbound  chan []byte
	once     sync.Once
	closeMu  sync.RWMutex
	isClosed bool

	packetMu sync.RWMutex
	packetCB PacketCallback
}

func newPendingTUN() *pendingTUN {
	t := &pendingTUN{
		events:  make(chan tun.Event, 1),
		closed:  make(chan struct{}),
		inbound: make(chan []byte, 1024),
	}
	t.events <- tun.EventUp
	return t
}

func (t *pendingTUN) File() *os.File { return nil }

func (t *pendingTUN) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	if t.closedNow() {
		return 0, os.ErrClosed
	}
	select {
	case <-t.closed:
		return 0, os.ErrClosed
	case packet, ok := <-t.inbound:
		if !ok || t.closedNow() {
			return 0, os.ErrClosed
		}
		return t.readBatch(packet, bufs, sizes, offset)
	}
}

func (t *pendingTUN) Write(bufs [][]byte, offset int) (int, error) {
	if t.closedNow() {
		return 0, os.ErrClosed
	}
	t.packetMu.RLock()
	defer t.packetMu.RUnlock()
	cb := t.packetCB

	if cb == nil {
		return len(bufs), nil
	}

	for i, buf := range bufs {
		select {
		case <-t.closed:
			return i, os.ErrClosed
		default:
		}
		if offset > len(buf) {
			return i, io.ErrShortBuffer
		}
		packet := append([]byte(nil), buf[offset:]...)
		if len(packet) == 0 {
			continue
		}
		if err := cb.OnPacket(packet); err != nil {
			log.Printf("packet callback failed after %d packet(s): %v", i, err)
			return i, err
		}
	}
	return len(bufs), nil
}

func (t *pendingTUN) MTU() (int, error) { return defaultMTU, nil }

func (t *pendingTUN) Name() (string, error) { return "utun_ts", nil }

func (t *pendingTUN) Events() <-chan tun.Event { return t.events }

func (t *pendingTUN) Close() error {
	t.once.Do(func() {
		t.closeMu.Lock()
		t.isClosed = true
		close(t.closed)
		close(t.inbound)
		close(t.events)
		t.closeMu.Unlock()
	})
	return nil
}

func (t *pendingTUN) BatchSize() int { return tunBatchSize }

func (t *pendingTUN) SetPacketCallback(cb PacketCallback) {
	t.packetMu.Lock()
	defer t.packetMu.Unlock()
	t.packetCB = cb
}

func (t *pendingTUN) InjectInboundPacket(packet []byte) error {
	if len(packet) == 0 {
		return nil
	}
	t.closeMu.RLock()
	defer t.closeMu.RUnlock()
	if t.isClosed {
		return os.ErrClosed
	}
	packet = append([]byte(nil), packet...)
	select {
	case t.inbound <- packet:
		return nil
	default:
		log.Printf("TUN inbound queue full packetBytes=%d queueDepth=%d", len(packet), len(t.inbound))
		return errInboundQueueFull
	}
}

func (t *pendingTUN) readBatch(first []byte, bufs [][]byte, sizes []int, offset int) (int, error) {
	if len(bufs) == 0 || len(sizes) < len(bufs) {
		return 0, io.ErrShortBuffer
	}
	if err := copyPacket(bufs[0], sizes, 0, first, offset); err != nil {
		return 0, err
	}
	n := 1
	for n < len(bufs) {
		select {
		case packet, ok := <-t.inbound:
			if !ok || t.closedNow() {
				return n, nil
			}
			if err := copyPacket(bufs[n], sizes, n, packet, offset); err != nil {
				return n, err
			}
			n++
		default:
			return n, nil
		}
	}
	return n, nil
}

func copyPacket(dst []byte, sizes []int, index int, packet []byte, offset int) error {
	if offset < 0 || len(dst) < offset+len(packet) {
		return io.ErrShortBuffer
	}
	copy(dst[offset:], packet)
	sizes[index] = len(packet)
	return nil
}

func (t *pendingTUN) closedNow() bool {
	t.closeMu.RLock()
	defer t.closeMu.RUnlock()
	return t.isClosed
}
