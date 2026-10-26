package libtailscale

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestLocalAPIDeadlineIncludesReadiness(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	done := make(chan error, 1)
	go func() {
		_, err := app.callLocalAPI(20, "GET", "/localapi/v0/status", nil, nil)
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("call error = %v, want deadline exceeded", err)
		}
	case <-time.After(time.Second):
		t.Fatal("LocalAPI ignored its deadline while waiting for startup")
	}
}

type closeTrackingBody struct {
	io.Reader
	closed atomic.Bool
}

func (b *closeTrackingBody) Close() error {
	b.closed.Store(true)
	return nil
}

func TestLocalAPIResponseKeepsRequestAlive(t *testing.T) {
	body := &closeTrackingBody{Reader: strings.NewReader("request")}
	requestContext := make(chan context.Context, 1)
	handlerDone := make(chan struct{})
	app := &App{ready: make(chan struct{})}
	app.localAPIHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(handlerDone)
		requestContext <- r.Context()
		_, _ = w.Write([]byte("response"))
	})
	app.markReady(nil)
	resp, err := app.callLocalAPI(1000, "POST", "/test", nil, body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.(*Response).Body().Close()
	ctx := <-requestContext
	if err := ctx.Err(); err != nil {
		t.Errorf("request canceled before response body was consumed: %v", err)
	}
	if body.closed.Load() {
		t.Error("request body closed while the handler was still writing its response")
	}
	got, err := resp.BodyBytes()
	if err != nil || string(got) != "response" {
		t.Fatalf("response = %q, %v", got, err)
	}
	<-handlerDone
}

func TestLocalAPIStopCancelsActiveRequest(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	app := &App{ctx: ctx, cancel: cancel, ready: make(chan struct{})}
	defer app.Stop()
	started := make(chan struct{})
	done := make(chan error, 1)
	handlerDone := make(chan struct{})
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(handlerDone)
		close(started)
		<-r.Context().Done()
	}))
	go func() {
		_, err := app.callLocalAPI(30000, "GET", "/test", nil, nil)
		done <- err
	}()
	<-started
	app.Stop()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("request after Stop = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not cancel active request")
	}
	<-handlerDone
}

func TestLocalAPIClosesBodyOnStartupError(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	app.markReady(errors.New("startup failed"))
	body := &closeTrackingBody{Reader: strings.NewReader("request")}
	if _, err := app.callLocalAPI(1000, "POST", "/test", nil, body); err == nil {
		t.Fatal("startup failure was not returned")
	}
	if !body.closed.Load() {
		t.Fatal("startup failure leaked request body")
	}
}

func TestLocalAPIEmptyResponse(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer app.Stop()
	for range 100 {
		resp, err := app.callLocalAPI(1000, "GET", "/test", nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode() != http.StatusNoContent {
			t.Fatalf("status = %d", resp.StatusCode())
		}
		got, err := resp.BodyBytes()
		if err != nil || len(got) != 0 {
			t.Fatalf("empty response = %q, %v", got, err)
		}
	}
}

func TestLocalAPIFirstFinalHeadersAreCommitted(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	headersWritten := make(chan struct{})
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		w.(http.Flusher).Flush()
		w.WriteHeader(http.StatusInternalServerError)
		close(headersWritten)
		_, _ = io.WriteString(w, "created")
	}))
	resp, err := app.callLocalAPI(1000, "POST", "/test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Close()
	<-headersWritten
	if got := resp.StatusCode(); got != http.StatusCreated {
		t.Fatalf("status changed after commitment: %d", got)
	}
	if body, err := resp.BodyBytes(); err != nil || string(body) != "created" {
		t.Fatalf("body = %q, %v", body, err)
	}
}

func TestLocalAPIHeadersReturnBeforeBodyAndCloseCancelsHandler(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	handlerDone := make(chan struct{})
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(handlerDone)
		w.WriteHeader(http.StatusAccepted)
		<-r.Context().Done()
	}))
	resp, err := app.callLocalAPI(1000, "POST", "/test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode() != http.StatusAccepted {
		t.Fatal("missing accepted status")
	}
	_ = resp.Close()
	_ = resp.Close()
	select {
	case <-handlerDone:
	case <-time.After(time.Second):
		t.Fatal("discarded response kept its handler alive")
	}
}

func TestLocalAPIBodyBytesReleasesResponse(t *testing.T) {
	app := &App{ready: make(chan struct{})}
	defer app.Stop()
	app.publishBackend(&backend{}, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "response")
	}))
	resp, err := app.callLocalAPI(1000, "GET", "/test", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if body, err := resp.BodyBytes(); err != nil || string(body) != "response" {
		t.Fatalf("body = %q, %v", body, err)
	}
	if _, err := resp.(*Response).bodyReader.Read(make([]byte, 1)); !errors.Is(err, io.ErrClosedPipe) {
		t.Fatalf("response reader after consumption = %v, want closed", err)
	}
}
