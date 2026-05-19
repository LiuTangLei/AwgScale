package libtailscale

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"tailscale.com/net/socks5"
)

const (
	inAppHTTPMaxBodyBytes = 2 << 20
	inAppTCPMaxBodyBytes  = 64 << 10
)

type inAppHTTPFetchRequest struct {
	URL           string `json:"url"`
	TimeoutMillis int    `json:"timeoutMillis,omitempty"`
}

type inAppHTTPFetchResponse struct {
	URL         string            `json:"url"`
	StatusCode  int               `json:"statusCode"`
	Headers     map[string]string `json:"headers"`
	ContentType string            `json:"contentType"`
	Body        string            `json:"body,omitempty"`
	BodyBase64  string            `json:"bodyBase64,omitempty"`
	Truncated   bool              `json:"truncated"`
}

type inAppBrowserProxyResponse struct {
	Type    string `json:"type"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
	Address string `json:"address"`
}

type inAppTCPRequest struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	Payload       string `json:"payload,omitempty"`
	AppendNewline bool   `json:"appendNewline"`
	TimeoutMillis int    `json:"timeoutMillis,omitempty"`
}

type inAppTCPResponse struct {
	Body       string `json:"body,omitempty"`
	BodyBase64 string `json:"bodyBase64,omitempty"`
	Truncated  bool   `json:"truncated"`
}

func (a *App) withInAppToolsHandler(base http.Handler, b *backend) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/localapi/v0/awg-sync-apply":
			a.handleAWGSyncApply(w, r, b)
		case "/localapi/v0/awgscale/http-fetch":
			a.handleInAppHTTPFetch(w, r, b)
		case "/localapi/v0/awgscale/browser-proxy":
			a.handleInAppBrowserProxy(w, r, b)
		case "/localapi/v0/awgscale/tcp-console":
			a.handleInAppTCPConsole(w, r, b)
		case "/localapi/v0/awgscale/ssh/open":
			a.handleInAppSSHOpen(w, r, b)
		case "/localapi/v0/awgscale/ssh/send":
			a.handleInAppSSHSend(w, r)
		case "/localapi/v0/awgscale/ssh/read":
			a.handleInAppSSHRead(w, r)
		case "/localapi/v0/awgscale/ssh/close":
			a.handleInAppSSHClose(w, r)
		default:
			base.ServeHTTP(w, r)
		}
	})
}

func (a *App) handleInAppBrowserProxy(w http.ResponseWriter, r *http.Request, b *backend) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	proxy, err := a.ensureInAppBrowserProxy(b)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeInAppJSON(w, http.StatusOK, proxy)
}

func (a *App) ensureInAppBrowserProxy(b *backend) (inAppBrowserProxyResponse, error) {
	if b == nil || b.netstack == nil || b.backend == nil {
		return inAppBrowserProxyResponse{}, errors.New("tailnet backend is not ready")
	}

	a.inAppProxyMu.Lock()
	defer a.inAppProxyMu.Unlock()

	if a.inAppProxyListener != nil && a.inAppProxyBackend == b {
		return inAppBrowserProxyResponse{
			Type:    "socks5",
			Host:    a.inAppProxyHost,
			Port:    a.inAppProxyPort,
			Address: net.JoinHostPort(a.inAppProxyHost, strconv.Itoa(a.inAppProxyPort)),
		}, nil
	}

	a.closeInAppBrowserProxyLocked()

	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return inAppBrowserProxyResponse{}, err
	}
	host, portString, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		_ = ln.Close()
		return inAppBrowserProxyResponse{}, err
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		_ = ln.Close()
		return inAppBrowserProxyResponse{}, err
	}

	server := &socks5.Server{
		Logf: func(format string, args ...any) {
			msg := fmt.Sprintf(format, args...)
			if strings.Contains(msg, "connection reset by peer") || strings.Contains(msg, "context canceled") || strings.Contains(msg, "broken pipe") {
				return
			}
			log.Printf("in-app browser socks5: %s", msg)
		},
		Dialer: func(ctx context.Context, network, address string) (net.Conn, error) {
			return a.dialInAppTailnetTCP(ctx, b, network, address)
		},
	}

	a.inAppProxyListener = ln
	a.inAppProxyBackend = b
	a.inAppProxyHost = host
	a.inAppProxyPort = port

	go func() {
		if err := server.Serve(ln); err != nil && !errors.Is(err, net.ErrClosed) && !strings.Contains(err.Error(), "use of closed network connection") {
			log.Printf("in-app browser socks5 exited: %v", err)
		}
	}()

	return inAppBrowserProxyResponse{
		Type:    "socks5",
		Host:    host,
		Port:    port,
		Address: net.JoinHostPort(host, strconv.Itoa(port)),
	}, nil
}

func (a *App) closeInAppBrowserProxy() {
	a.inAppProxyMu.Lock()
	defer a.inAppProxyMu.Unlock()
	a.closeInAppBrowserProxyLocked()
}

func (a *App) closeInAppBrowserProxyLocked() {
	if a.inAppProxyListener != nil {
		_ = a.inAppProxyListener.Close()
	}
	a.inAppProxyListener = nil
	a.inAppProxyBackend = nil
	a.inAppProxyHost = ""
	a.inAppProxyPort = 0
}

func (a *App) handleInAppHTTPFetch(w http.ResponseWriter, r *http.Request, b *backend) {
	if r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req inAppHTTPFetchRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, "invalid request body")
		return
	}

	parsedURL, err := normalizeInAppURL(req.URL)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	timeout := inAppTimeout(req.TimeoutMillis, 30*time.Second)
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return a.dialInAppTailnetTCP(ctx, b, network, address)
		},
		ForceAttemptHTTP2:   false,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	defer transport.CloseIdleConnections()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, parsedURL.String(), nil)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	httpReq.Header.Set("User-Agent", "AwgScale-InAppBrowser/1")

	resp, err := (&http.Client{Transport: transport}).Do(httpReq)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer resp.Body.Close()

	body, truncated, err := readLimited(resp.Body, inAppHTTPMaxBodyBytes)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	out := inAppHTTPFetchResponse{
		URL:         resp.Request.URL.String(),
		StatusCode:  resp.StatusCode,
		Headers:     firstHeaderValues(resp.Header),
		ContentType: resp.Header.Get("Content-Type"),
		Truncated:   truncated,
	}
	setTextOrBase64(body, &out.Body, &out.BodyBase64)
	writeInAppJSON(w, http.StatusOK, out)
}

func (a *App) handleInAppTCPConsole(w http.ResponseWriter, r *http.Request, b *backend) {
	if r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req inAppTCPRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if strings.TrimSpace(req.Host) == "" || req.Port <= 0 || req.Port > 65535 {
		writeInAppJSONError(w, http.StatusBadRequest, "host and port are required")
		return
	}

	timeout := inAppTimeout(req.TimeoutMillis, 8*time.Second)
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	conn, err := a.dialInAppTailnetTCP(ctx, b, "tcp", net.JoinHostPort(req.Host, strconv.Itoa(req.Port)))
	if err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(timeout))
	if req.Payload != "" {
		payload := req.Payload
		if req.AppendNewline && !strings.HasSuffix(payload, "\n") {
			payload += "\n"
		}
		if _, err := io.WriteString(conn, payload); err != nil {
			writeInAppJSONError(w, http.StatusBadGateway, err.Error())
			return
		}
	}

	body, truncated, err := readConnUntilIdle(conn, inAppTCPMaxBodyBytes)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	out := inAppTCPResponse{Truncated: truncated}
	setTextOrBase64(body, &out.Body, &out.BodyBase64)
	writeInAppJSON(w, http.StatusOK, out)
}

func (a *App) dialInAppTailnetTCP(ctx context.Context, b *backend, network, address string) (net.Conn, error) {
	if network != "tcp" && network != "tcp4" && network != "tcp6" {
		return nil, fmt.Errorf("unsupported network %q", network)
	}
	if b == nil || b.netstack == nil || b.backend == nil {
		return nil, errors.New("tailnet backend is not ready")
	}

	host, portString, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.ParseUint(portString, 10, 16)
	if err != nil {
		return nil, err
	}
	addrs, err := resolveInAppAddrs(ctx, b, host)
	if err != nil {
		return nil, err
	}
	if len(addrs) == 0 {
		return nil, errors.New("host did not resolve to an IP address")
	}

	var lastErr error
	for _, addr := range addrs {
		if !inAppAddrRoutableWithoutExitNode(b, addr) {
			if inAppExitNodeActive(b) {
				lastErr = errors.New("exit node route is not ready")
				continue
			}
			return nil, errors.New("select an exit node to reach non-tailnet addresses")
		}
		conn, err := b.netstack.DialContextTCP(ctx, netip.AddrPortFrom(addr, uint16(port)))
		if err == nil {
			return conn, nil
		}
		lastErr = err
	}

	if lastErr != nil {
		return nil, lastErr
	}
	return nil, errors.New("no routable address found")
}

func resolveInAppAddr(ctx context.Context, b *backend, host string) (netip.Addr, error) {
	addrs, err := resolveInAppAddrs(ctx, b, host)
	if err != nil {
		return netip.Addr{}, err
	}
	if len(addrs) == 0 {
		return netip.Addr{}, fmt.Errorf("%q did not resolve to an IP address", host)
	}
	return addrs[0], nil
}

func resolveInAppAddrs(ctx context.Context, b *backend, host string) ([]netip.Addr, error) {
	host = normalizeTailnetName(host)
	if addr, err := netip.ParseAddr(host); err == nil {
		if inAppAddrRoutableWithoutExitNode(b, addr) || inAppExitNodeActive(b) {
			return []netip.Addr{addr}, nil
		}
		return nil, errors.New("select an exit node to reach non-tailnet addresses")
	}

	status := b.backend.Status()
	candidates := make(map[string]netip.Addr)
	addPeer := func(hostName, dnsName string, ips []netip.Addr) {
		if len(ips) == 0 {
			return
		}
		ip := ips[0]
		for _, name := range candidateTailnetNames(hostName, dnsName, status.MagicDNSSuffix) {
			candidates[name] = ip
		}
	}
	if status.Self != nil {
		addPeer(status.Self.HostName, status.Self.DNSName, status.Self.TailscaleIPs)
	}
	for _, peer := range status.Peer {
		if peer != nil {
			addPeer(peer.HostName, peer.DNSName, peer.TailscaleIPs)
		}
	}

	if addr, ok := candidates[host]; ok {
		return []netip.Addr{addr}, nil
	}

	if inAppExitNodeActive(b) {
		ipAddrs, err := lookupPublicIPAddrsViaExitNode(ctx, b, host)
		if err != nil {
			return nil, err
		}
		var addrs []netip.Addr
		for _, ipAddr := range ipAddrs {
			if addr, ok := netip.AddrFromSlice(ipAddr.IP); ok {
				addrs = append(addrs, addr.Unmap())
			}
		}
		if len(addrs) == 0 {
			return nil, fmt.Errorf("%q did not resolve to an IP address", host)
		}
		return preferIPv4(addrs), nil
	}

	return nil, fmt.Errorf("%q is not a known tailnet host or IP", host)
}

func lookupPublicIPAddrsViaExitNode(ctx context.Context, b *backend, host string) ([]net.IPAddr, error) {
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return dialInAppDNSViaExitNode(ctx, b, network)
		},
	}
	return resolver.LookupIPAddr(ctx, host)
}

func dialInAppDNSViaExitNode(ctx context.Context, b *backend, network string) (net.Conn, error) {
	if b == nil || b.netstack == nil {
		return nil, errors.New("tailnet backend is not ready")
	}
	dnsAddr := netip.MustParseAddrPort("1.1.1.1:53")
	if strings.HasSuffix(network, "6") {
		dnsAddr = netip.MustParseAddrPort("[2606:4700:4700::1111]:53")
	}
	if !inAppAddrRoutableWithoutExitNode(b, dnsAddr.Addr()) {
		if inAppExitNodeActive(b) {
			return nil, errors.New("exit node DNS route is not ready")
		}
		return nil, errors.New("select an exit node to resolve public hostnames")
	}
	if strings.HasPrefix(network, "udp") {
		return b.netstack.DialContextUDP(ctx, dnsAddr)
	}
	return b.netstack.DialContextTCP(ctx, dnsAddr)
}

func preferIPv4(addrs []netip.Addr) []netip.Addr {
	out := make([]netip.Addr, 0, len(addrs))
	for _, addr := range addrs {
		if addr.Is4() {
			out = append(out, addr)
		}
	}
	for _, addr := range addrs {
		if !addr.Is4() {
			out = append(out, addr)
		}
	}
	return out
}

func inAppAddrRoutableWithoutExitNode(b *backend, addr netip.Addr) bool {
	if b == nil || b.engine == nil {
		return false
	}
	_, ok := b.engine.PeerForIP(addr)
	return ok
}

func inAppExitNodeActive(b *backend) bool {
	if b == nil || b.backend == nil {
		return false
	}
	prefs := b.backend.Prefs()
	if prefs.Valid() && (!prefs.ExitNodeID().IsZero() || prefs.ExitNodeIP().IsValid()) {
		return true
	}
	status := b.backend.Status()
	return status != nil && status.ExitNodeStatus != nil
}

func candidateTailnetNames(hostName, dnsName, suffix string) []string {
	var out []string
	add := func(name string) {
		name = normalizeTailnetName(name)
		if name != "" {
			out = append(out, name)
		}
	}

	add(hostName)
	add(dnsName)

	dnsName = normalizeTailnetName(dnsName)
	suffix = normalizeTailnetName(suffix)
	if dnsName != "" && suffix != "" && strings.HasSuffix(dnsName, "."+suffix) {
		add(strings.TrimSuffix(dnsName, "."+suffix))
	}
	return out
}

func normalizeTailnetName(name string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(name)), ".")
}

func normalizeInAppURL(raw string) (*url.URL, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("url is required")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("only http and https urls are supported")
	}
	if parsed.Hostname() == "" {
		return nil, errors.New("url host is required")
	}
	return parsed, nil
}

func inAppTimeout(timeoutMillis int, fallback time.Duration) time.Duration {
	if timeoutMillis <= 0 {
		return fallback
	}
	return time.Duration(timeoutMillis) * time.Millisecond
}

func firstHeaderValues(header http.Header) map[string]string {
	out := make(map[string]string, len(header))
	for key, values := range header {
		if len(values) > 0 {
			out[key] = values[0]
		}
	}
	return out
}

func readLimited(r io.Reader, limit int) ([]byte, bool, error) {
	data, err := io.ReadAll(io.LimitReader(r, int64(limit+1)))
	if err != nil {
		return nil, false, err
	}
	if len(data) > limit {
		return data[:limit], true, nil
	}
	return data, false, nil
}

func readConnUntilIdle(conn net.Conn, limit int) ([]byte, bool, error) {
	var data []byte
	buf := make([]byte, 4096)
	for len(data) < limit {
		n, err := conn.Read(buf)
		if n > 0 {
			remaining := limit - len(data)
			if n > remaining {
				data = append(data, buf[:remaining]...)
				return data, true, nil
			}
			data = append(data, buf[:n]...)
		}
		if err != nil {
			if err == io.EOF {
				return data, false, nil
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				return data, false, nil
			}
			return data, false, err
		}
	}
	return data, true, nil
}

func setTextOrBase64(data []byte, textOut, base64Out *string) {
	if utf8.Valid(data) {
		*textOut = string(data)
		return
	}
	*base64Out = base64.StdEncoding.EncodeToString(data)
}

func writeInAppJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeInAppJSONError(w http.ResponseWriter, status int, message string) {
	writeInAppJSON(w, status, map[string]string{"error": message})
}
