package libtailscale

import (
	"errors"
	"io"
	"net/http"
	"sync/atomic"
	"testing"
)

type trackedInputStream struct {
	data       []byte
	err        error
	reads      int
	closeCount atomic.Int32
}

func (s *trackedInputStream) Read() ([]byte, error) {
	s.reads++
	data := s.data
	s.data = nil
	return data, s.err
}

func (s *trackedInputStream) Close() error {
	s.closeCount.Add(1)
	return nil
}

func TestAdaptInputStreamPreservesPartialDataAndError(t *testing.T) {
	failure := errors.New("file read failed")
	in := &trackedInputStream{data: []byte("partial"), err: failure}
	r := adaptInputStream(in)
	defer r.Close()
	buf := make([]byte, 3)
	var got []byte
	for {
		n, err := r.Read(buf)
		got = append(got, buf[:n]...)
		if err != nil {
			if !errors.Is(err, failure) {
				t.Fatalf("read error = %v, want source error", err)
			}
			break
		}
	}
	if string(got) != "partial" || in.reads != 1 {
		t.Fatalf("read = %q in %d source reads", got, in.reads)
	}
}

func TestAdaptInputStreamEmptyDataIsEOF(t *testing.T) {
	r := adaptInputStream(&trackedInputStream{data: []byte{}})
	defer r.Close()
	if n, err := r.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("empty Swift Data = %d, %v, want EOF", n, err)
	}
}

func TestAdaptInputStreamCloseOwnsSource(t *testing.T) {
	in := &trackedInputStream{data: []byte("unused")}
	r := adaptInputStream(in)
	for range 2 {
		if err := r.Close(); err != nil {
			t.Fatal(err)
		}
	}
	if got := in.closeCount.Load(); got != 1 {
		t.Fatalf("source closed %d times, want once", got)
	}
	if n, err := r.Read(make([]byte, 1)); n != 0 || !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("read after close = %d, %v", n, err)
	}
	if in.reads != 0 {
		t.Fatal("adapter read source before request consumed it")
	}
}

type singleFileParts struct{ part *FilePart }

func (p singleFileParts) Len() int32          { return 1 }
func (p singleFileParts) Get(int32) *FilePart { return p.part }

func TestLocalAPIMultipartClosesSource(t *testing.T) {
	for _, failure := range []error{nil, errors.New("file read failed")} {
		in := &trackedInputStream{data: []byte("file data"), err: failure}
		app := &App{ready: make(chan struct{})}
		app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if _, err := io.Copy(io.Discard, r.Body); err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		}))
		parts := singleFileParts{&FilePart{Filename: "file", ContentLength: 9, Body: in}}
		resp, err := app.CallLocalAPIMultipart(1000, "POST", "/test", parts)
		if failure != nil {
			if !errors.Is(err, failure) {
				t.Fatalf("multipart error = %v, want source error", err)
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode() != http.StatusNoContent {
				t.Fatalf("multipart status = %d", resp.StatusCode())
			}
			if _, err := resp.BodyBytes(); err != nil {
				t.Fatal(err)
			}
		}
		app.Stop()
		if got := in.closeCount.Load(); got != 1 {
			t.Fatalf("multipart source closed %d times, want once", got)
		}
	}
}
