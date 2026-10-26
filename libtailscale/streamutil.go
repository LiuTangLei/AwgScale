package libtailscale

import (
	"io"
	"sync"
)

// adaptInputStream wraps an InputStream into an io.ReadCloser.
func adaptInputStream(in InputStream) io.ReadCloser {
	if in == nil {
		return nil
	}
	return &inputStreamReader{in: in}
}

// Read and Close are serialized because the Swift stream owns a mutable
// FileHandle (or Data buffer). No producer goroutine outlives its request.
type inputStreamReader struct {
	mu      sync.Mutex
	in      InputStream
	pending []byte
	err     error
	closed  bool
}

func (r *inputStreamReader) Read(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return 0, io.ErrClosedPipe
	}
	if len(p) == 0 {
		return 0, nil
	}
	if len(r.pending) == 0 && r.err == nil {
		r.pending, r.err = r.in.Read()
		// Swift represents EOF as empty Data, which can arrive as either an
		// empty slice or nil through gomobile.
		if len(r.pending) == 0 && r.err == nil {
			r.err = io.EOF
		}
	}
	n := copy(p, r.pending)
	r.pending = r.pending[n:]
	if len(r.pending) > 0 {
		return n, nil
	}
	return n, r.err
}

func (r *inputStreamReader) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	r.closed = true
	r.pending = nil
	return r.in.Close()
}
