package libtailscale

import (
	"io"
	"log"
	"os"
	"sync"
	"time"

	"github.com/LiuTangLei/wireguard-go/tun"
)

const defaultMTU = 1280

const tunBatchSize = 32

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

	readMu  sync.Mutex
	pending []byte

	packetMu sync.RWMutex
	packetCB PacketCallback

	dropMu             sync.Mutex
	droppedInbound     uint64
	lastInboundDropLog time.Time
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

func (t *pendingTUN) Read(slab []byte, packets []tun.ReadPacket) (int, error) {
	t.readMu.Lock()
	defer t.readMu.Unlock()
	if t.closedNow() {
		return 0, os.ErrClosed
	}
	if len(packets) == 0 || len(slab) < 2*tun.ReadPacketSpacing {
		return 0, io.ErrShortBuffer
	}
	n, offset := 0, tun.ReadPacketSpacing
	for n < len(packets) {
		if t.pending == nil {
			if n == 0 {
				select {
				case <-t.closed:
					return 0, os.ErrClosed
				case p, ok := <-t.inbound:
					if !ok || t.closedNow() {
						return 0, os.ErrClosed
					}
					t.pending = p
				}
			} else {
				select {
				case p, ok := <-t.inbound:
					if !ok || t.closedNow() {
						return n, nil
					}
					t.pending = p
				default:
					return n, nil
				}
			}
		}
		if len(t.pending) > len(slab)-offset-tun.ReadPacketSpacing {
			if n == 0 {
				return 0, tun.ErrTooManySegments
			}
			return n, nil
		}
		size := copy(slab[offset:], t.pending)
		packets[n] = tun.ReadPacket{Offset: offset, Size: size}
		offset += size + tun.ReadPacketSpacing
		t.pending = nil
		n++
	}
	return n, nil
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
		t.logInboundQueueFull(len(packet))
		return nil
	}
}

func (t *pendingTUN) logInboundQueueFull(packetBytes int) {
	t.dropMu.Lock()
	t.droppedInbound++
	dropped := t.droppedInbound
	now := time.Now()
	shouldLog := dropped == 1 || dropped%256 == 0 || now.Sub(t.lastInboundDropLog) >= 5*time.Second
	if shouldLog {
		t.lastInboundDropLog = now
	}
	t.dropMu.Unlock()

	if shouldLog {
		log.Printf("TUN inbound queue full; dropping packet packetBytes=%d queueDepth=%d dropped=%d", packetBytes, len(t.inbound), dropped)
	}
}

func (t *pendingTUN) closedNow() bool {
	t.closeMu.RLock()
	defer t.closeMu.RUnlock()
	return t.isClosed
}
