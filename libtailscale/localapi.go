package libtailscale

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CallLocalAPI calls the given endpoint on the local API using the given HTTP
// method and optionally sending the given body. It returns a Response
// representing the result of the call.
func (app *App) CallLocalAPI(timeoutMillis int, method, endpoint string, body InputStream) (LocalAPIResponse, error) {
	return app.callLocalAPI(timeoutMillis, method, endpoint, nil, adaptInputStream(body))
}

// CallLocalAPIMultipart is like CallLocalAPI, but instead of uploading a
// generic body, it uploads a multipart/form-encoded body consisting of the
// supplied parts.
func (app *App) CallLocalAPIMultipart(timeoutMillis int, method, endpoint string, parts FileParts) (LocalAPIResponse, error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic in CallLocalAPIMultipart %s: %s", p, debug.Stack())
			panic(p)
		}
	}()

	r, w := io.Pipe()
	defer r.Close()

	mw := multipart.NewWriter(w)
	header := make(http.Header)
	header.Set("Content-Type", mw.FormDataContentType())
	// Own all sources from the start, including parts never reached after an
	// early server rejection or startup failure. The adapters close once.
	bodies := make([]io.ReadCloser, parts.Len())
	for i := range bodies {
		bodies[i] = adaptInputStream(parts.Get(int32(i)).Body)
		if bodies[i] != nil {
			defer bodies[i].Close()
		}
	}
	written := make(chan error, 1)
	go func() {
		err := func() error {
			for i, body := range bodies {
				part := parts.Get(int32(i))
				contentType := "application/octet-stream"
				if part.ContentType != "" {
					contentType = part.ContentType
				}
				header := make(textproto.MIMEHeader, 3)
				header.Set("Content-Disposition",
					fmt.Sprintf(`form-data; name="%s"; filename="%s"`,
						escapeQuotes("file"), escapeQuotes(part.Filename)))
				header.Set("Content-Type", contentType)
				header.Set("Content-Length", strconv.FormatInt(part.ContentLength, 10))
				p, err := mw.CreatePart(header)
				if err != nil {
					return fmt.Errorf("CreatePart: %w", err)
				}
				if body == nil {
					return fmt.Errorf("missing body for multipart file %q", part.Filename)
				}
				_, err = io.Copy(p, body)
				closeErr := body.Close()
				if err == nil {
					err = closeErr
				}
				if err != nil {
					return fmt.Errorf("Copy: %w", err)
				}
			}
			return mw.Close()
		}()
		written <- err
		_ = w.CloseWithError(err)
	}()

	response, err := app.callLocalAPI(timeoutMillis, method, endpoint, header, r)
	if err != nil {
		return nil, err
	}
	// An HTTP rejection need not consume the upload. Successful uploads must
	// finish copying all parts; response headers alone cannot prove delivery.
	if response.StatusCode() >= http.StatusMultipleChoices {
		select {
		case writeErr := <-written:
			if writeErr != nil && !errors.Is(writeErr, io.ErrClosedPipe) {
				_ = response.Close()
				return nil, writeErr
			}
		default:
		}
		return response, nil
	}
	resp := response.(*Response)
	timer := time.NewTimer(time.Until(resp.deadline))
	defer timer.Stop()
	var stopped <-chan struct{}
	if app.ctx != nil {
		stopped = app.ctx.Done()
	}
	select {
	case err := <-written:
		if err != nil {
			_ = response.Close()
			return nil, err
		}
		return response, nil
	case <-timer.C:
		_ = response.Close()
		return nil, context.DeadlineExceeded
	case <-stopped:
		_ = response.Close()
		return nil, context.Canceled
	}
}

// NotifyPolicyChanged notifies the backend about a changed MDM policy.
func (app *App) NotifyPolicyChanged() {
	app.policyStore.notifyChanged()
}

func (app *App) callLocalAPI(timeoutMillis int, method, endpoint string, header http.Header, body io.ReadCloser) (LocalAPIResponse, error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic in callLocalAPI %s: %s", p, debug.Stack())
			panic(p)
		}
	}()

	parent := app.ctx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(timeoutMillis)*time.Millisecond)
	handlerOwnsRequest := false
	defer func() {
		if !handlerOwnsRequest {
			cancel()
			if body != nil {
				_ = body.Close()
			}
		}
	}()
	if err := app.waitReadyContext(ctx); err != nil {
		return nil, err
	}
	app.mu.Lock()
	handler := app.localAPIHandler
	stopped := app.stopped
	app.mu.Unlock()
	if stopped {
		return nil, context.Canceled
	}
	if handler == nil {
		return nil, fmt.Errorf("localapi handler not ready")
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return nil, fmt.Errorf("error creating new request for %s: %w", endpoint, err)
	}
	maps.Copy(req.Header, header)

	deadline, _ := ctx.Deadline()
	pipeReader, pipeWriter := net.Pipe()
	pipeReader.SetDeadline(deadline)
	pipeWriter.SetDeadline(deadline)
	stopCancel := context.AfterFunc(ctx, func() {
		// Stop also interrupts a blocked response read/write, without waiting
		// for the original request deadline.
		_ = pipeReader.SetDeadline(time.Now())
		_ = pipeWriter.SetDeadline(time.Now())
	})

	resp := &Response{
		headers:          http.Header{},
		deadline:         deadline,
		cancel:           cancel,
		bodyReader:       pipeReader,
		bodyWriter:       pipeWriter,
		startWritingBody: make(chan interface{}),
	}

	handlerOwnsRequest = true
	requestReturned := make(chan struct{})
	defer close(requestReturned)
	go func() {
		defer func() {
			// An empty response can finish before the caller receives its
			// headers. Do not make successful completion look like cancellation.
			<-requestReturned
			cancel()
		}()
		defer stopCancel()
		if body != nil {
			defer body.Close()
		}
		defer func() {
			if p := recover(); p != nil {
				log.Printf("panic in CallLocalAPI.ServeHTTP %s: %s", p, debug.Stack())
				panic(p)
			}
		}()

		// LocalBackend restores the control-provided DERP map during prefs
		// edits. Re-run the cached, content-idempotent ensure after every
		// handler so PATCH prefs, start, AWG apply, and future prefs-mutating
		// endpoints cannot silently discard the iOS fallback map. Register it
		// before Close so the response reaches the caller first; a fresh custom
		// map might otherwise hold EOF behind one or more DNS lookups.
		defer app.refreshUsableDERPMapForLocalAPI(endpoint + "-complete")
		defer pipeWriter.Close()
		app.refreshUsableDERPMapForLocalAPI(endpoint)
		if ctx.Err() != nil {
			return
		}
		handler.ServeHTTP(resp, req)
		resp.Flush()
	}()

	select {
	case <-resp.startWritingBody:
		if err := ctx.Err(); err != nil {
			_ = pipeReader.Close()
			return nil, fmt.Errorf("localapi %s: %w", endpoint, err)
		}
		return resp, nil
	case <-ctx.Done():
		_ = pipeReader.Close()
		return nil, fmt.Errorf("localapi %s: %w", endpoint, ctx.Err())
	}
}

// Response represents the result of processing a localAPI request.
type Response struct {
	deadline         time.Time
	cancel           context.CancelFunc
	headers          http.Header
	statusMu         sync.Mutex
	status           int
	bodyWriter       net.Conn
	bodyReader       net.Conn
	startWritingBody chan interface{}
}

func (r *Response) Header() http.Header {
	return r.headers
}

func (r *Response) Write(data []byte) (int, error) {
	r.Flush()
	return r.bodyWriter.Write(data)
}

func (r *Response) WriteHeader(statusCode int) {
	if statusCode >= 100 && statusCode < 200 && statusCode != http.StatusSwitchingProtocols {
		return // An informational response does not commit final headers.
	}
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	if r.status != 0 {
		return
	}
	r.status = statusCode
	close(r.startWritingBody)
}

func (r *Response) Body() net.Conn {
	return r.bodyReader
}

func (r *Response) BodyBytes() ([]byte, error) {
	defer r.Close()
	return io.ReadAll(r.bodyReader)
}

func (r *Response) Close() error {
	r.cancel()
	return r.bodyReader.Close()
}

func (r *Response) StatusCode() int {
	r.statusMu.Lock()
	defer r.statusMu.Unlock()
	return r.status
}

func (r *Response) Flush() {
	r.WriteHeader(http.StatusOK)
}

var quoteEscaper = strings.NewReplacer("\\", "\\\\", `"`, "\\\"")

func escapeQuotes(s string) string {
	return quoteEscaper.Replace(s)
}
