package libtailscale

import (
	"errors"
	"io"
	"net/http"
	"testing"
	"time"
)

type testFileParts []*FilePart

func (p testFileParts) Len() int32            { return int32(len(p)) }
func (p testFileParts) Get(i int32) *FilePart { return p[i] }

func TestMultipartEarlyRejectionClosesUnconsumedFiles(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	first := &trackedInputStream{data: []byte("first")}
	second := &trackedInputStream{data: []byte("second")}
	parts := testFileParts{{Filename: "first", Body: first}, {Filename: "second", Body: second}}
	resp, err := app.CallLocalAPIMultipart(1000, "POST", "/test", parts)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Close()
	if resp.StatusCode() != http.StatusForbidden {
		t.Fatal("server rejection lost")
	}
	for _, source := range []*trackedInputStream{first, second} {
		if source.closeCount.Load() != 1 {
			t.Fatal("early rejection leaked an unread file")
		}
	}
}

func TestMultipartStartupFailureClosesUnconsumedFiles(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	app.markReady(errors.New("not ready"))
	defer app.Stop()
	source := &trackedInputStream{data: []byte("file")}
	_, err := app.CallLocalAPIMultipart(1000, "POST", "/test", singleFileParts{&FilePart{Filename: "file", Body: source}})
	if err == nil {
		t.Fatal("startup failure was lost")
	}
	if source.closeCount.Load() != 1 {
		t.Fatal("startup failure leaked an unread file")
	}
}

func TestMultipartReadFailureReleasesHandler(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	done := make(chan struct{})
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(done)
		if _, err := io.Copy(io.Discard, r.Body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
		}
	}))
	failure := errors.New("file read failed")
	source := &trackedInputStream{data: []byte("partial"), err: failure}
	_, err := app.CallLocalAPIMultipart(1000, "POST", "/test", singleFileParts{&FilePart{Filename: "file", Body: source}})
	if !errors.Is(err, failure) {
		t.Fatalf("error = %v, want source error", err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("read failure left the HTTP handler blocked")
	}
}

func TestMultipartEarlySuccessCannotAcknowledgeUnsentFile(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		// Deliberately return without consuming the upload.
	}))
	source := &trackedInputStream{data: []byte("not sent")}
	resp, err := app.CallLocalAPIMultipart(1000, "POST", "/test", singleFileParts{&FilePart{Filename: "file", Body: source}})
	if err == nil {
		_ = resp.Close()
		t.Fatal("success headers incorrectly acknowledged an unsent file")
	}
	if source.closeCount.Load() != 1 {
		t.Fatal("unsent file was not closed")
	}
}
