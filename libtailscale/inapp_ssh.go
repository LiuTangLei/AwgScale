package libtailscale

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const inAppSSHBufferLimit = 256 << 10

type inAppSSHOpenRequest struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	Username      string `json:"username"`
	Password      string `json:"password,omitempty"`
	PrivateKey    string `json:"privateKey,omitempty"`
	Passphrase    string `json:"passphrase,omitempty"`
	Terminal      string `json:"terminal,omitempty"`
	Columns       int    `json:"columns,omitempty"`
	Rows          int    `json:"rows,omitempty"`
	TimeoutMillis int    `json:"timeoutMillis,omitempty"`
}

type inAppSSHSessionRequest struct {
	SessionID string `json:"sessionID"`
}

type inAppSSHSendRequest struct {
	SessionID string `json:"sessionID"`
	Input     string `json:"input"`
}

type inAppSSHResponse struct {
	SessionID string `json:"sessionID"`
	Body      string `json:"body,omitempty"`
	BodyBase64 string `json:"bodyBase64,omitempty"`
	Active    bool   `json:"active"`
	Truncated bool   `json:"truncated"`
}

type inAppSSHSession struct {
	client  *ssh.Client
	session *ssh.Session
	stdin   io.WriteCloser
	done    chan struct{}

	mu        sync.Mutex
	buffer    []byte
	truncated bool
	closed    bool
}

func (a *App) handleInAppSSHOpen(w http.ResponseWriter, r *http.Request, b *backend) {
	if r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req inAppSSHOpenRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if strings.TrimSpace(req.Host) == "" || strings.TrimSpace(req.Username) == "" || req.Port <= 0 || req.Port > 65535 {
		writeInAppJSONError(w, http.StatusBadRequest, "host, port, and username are required")
		return
	}

	auth, err := sshAuthMethods(req)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	timeout := inAppTimeout(req.TimeoutMillis, 15*time.Second)
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	address := net.JoinHostPort(req.Host, strconv.Itoa(req.Port))
	netConn, err := a.dialInAppTailnetTCP(ctx, b, "tcp", address)
	if err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	config := &ssh.ClientConfig{
		User:            strings.TrimSpace(req.Username),
		Auth:            auth,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         timeout,
	}
	clientConn, chans, reqs, err := ssh.NewClientConn(netConn, address, config)
	if err != nil {
		_ = netConn.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	client := ssh.NewClient(clientConn, chans, reqs)
	sshSession, err := client.NewSession()
	if err != nil {
		_ = client.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	stdin, err := sshSession.StdinPipe()
	if err != nil {
		_ = sshSession.Close()
		_ = client.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	stdout, err := sshSession.StdoutPipe()
	if err != nil {
		_ = sshSession.Close()
		_ = client.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	stderr, err := sshSession.StderrPipe()
	if err != nil {
		_ = sshSession.Close()
		_ = client.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	term := req.Terminal
	if term == "" {
		term = "xterm-256color"
	}
	cols, rows := req.Columns, req.Rows
	if cols <= 0 {
		cols = 80
	}
	if rows <= 0 {
		rows = 24
	}
	modes := ssh.TerminalModes{
		ssh.ECHO:          1,
		ssh.TTY_OP_ISPEED: 14400,
		ssh.TTY_OP_OSPEED: 14400,
	}
	if err := sshSession.RequestPty(term, rows, cols, modes); err != nil {
		_ = sshSession.Close()
		_ = client.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := sshSession.Shell(); err != nil {
		_ = sshSession.Close()
		_ = client.Close()
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}

	session := &inAppSSHSession{
		client:  client,
		session: sshSession,
		stdin:   stdin,
		done:    make(chan struct{}),
	}
	id, err := randomSessionID()
	if err != nil {
		session.close()
		writeInAppJSONError(w, http.StatusInternalServerError, err.Error())
		return
	}

	a.sshMu.Lock()
	a.sshSessions[id] = session
	a.sshMu.Unlock()

	go session.copyOutput(stdout)
	go session.copyOutput(stderr)
	go func() {
		if err := sshSession.Wait(); err != nil && !errors.Is(err, io.EOF) {
			session.appendOutput([]byte("\n[ssh closed: " + err.Error() + "]\n"))
		}
		session.markClosed()
	}()

	writeSSHResponse(w, http.StatusOK, id, session)
}

func (a *App) handleInAppSSHSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req inAppSSHSendRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	session, ok := a.inAppSSHSession(req.SessionID)
	if !ok {
		writeInAppJSONError(w, http.StatusNotFound, "ssh session not found")
		return
	}
	if _, err := io.WriteString(session.stdin, req.Input); err != nil {
		writeInAppJSONError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeSSHResponse(w, http.StatusOK, req.SessionID, session)
}

func (a *App) handleInAppSSHRead(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req inAppSSHSessionRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	session, ok := a.inAppSSHSession(req.SessionID)
	if !ok {
		writeInAppJSONError(w, http.StatusNotFound, "ssh session not found")
		return
	}
	writeSSHResponse(w, http.StatusOK, req.SessionID, session)
}

func (a *App) handleInAppSSHClose(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeInAppJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req inAppSSHSessionRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		writeInAppJSONError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	session, ok := a.removeInAppSSHSession(req.SessionID)
	if ok {
		session.close()
	}
	writeInAppJSON(w, http.StatusOK, map[string]bool{"closed": true})
}

func sshAuthMethods(req inAppSSHOpenRequest) ([]ssh.AuthMethod, error) {
	var auth []ssh.AuthMethod
	if req.Password != "" {
		auth = append(auth, ssh.Password(req.Password))
	}
	if strings.TrimSpace(req.PrivateKey) != "" {
		var signer ssh.Signer
		var err error
		key := []byte(req.PrivateKey)
		if req.Passphrase != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase(key, []byte(req.Passphrase))
		} else {
			signer, err = ssh.ParsePrivateKey(key)
		}
		if err != nil {
			return nil, err
		}
		auth = append(auth, ssh.PublicKeys(signer))
	}
	if len(auth) == 0 {
		return nil, errors.New("password or private key is required")
	}
	return auth, nil
}

func (a *App) inAppSSHSession(id string) (*inAppSSHSession, bool) {
	a.sshMu.Lock()
	defer a.sshMu.Unlock()
	session, ok := a.sshSessions[id]
	return session, ok
}

func (a *App) removeInAppSSHSession(id string) (*inAppSSHSession, bool) {
	a.sshMu.Lock()
	defer a.sshMu.Unlock()
	session, ok := a.sshSessions[id]
	if ok {
		delete(a.sshSessions, id)
	}
	return session, ok
}

func (a *App) closeInAppSSHSessions() {
	a.sshMu.Lock()
	sessions := a.sshSessions
	a.sshSessions = make(map[string]*inAppSSHSession)
	a.sshMu.Unlock()

	for _, session := range sessions {
		session.close()
	}
}

func (s *inAppSSHSession) copyOutput(r io.Reader) {
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			s.appendOutput(buf[:n])
		}
		if err != nil {
			return
		}
	}
}

func (s *inAppSSHSession) appendOutput(data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.buffer = append(s.buffer, data...)
	if len(s.buffer) > inAppSSHBufferLimit {
		s.buffer = append([]byte(nil), s.buffer[len(s.buffer)-inAppSSHBufferLimit:]...)
		s.truncated = true
	}
}

func (s *inAppSSHSession) drainOutput() ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data := append([]byte(nil), s.buffer...)
	s.buffer = nil
	truncated := s.truncated
	s.truncated = false
	return data, truncated
}

func (s *inAppSSHSession) active() bool {
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

func (s *inAppSSHSession) markClosed() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()
	close(s.done)
}

func (s *inAppSSHSession) close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()
	_ = s.stdin.Close()
	_ = s.session.Close()
	_ = s.client.Close()
	close(s.done)
}

func writeSSHResponse(w http.ResponseWriter, status int, id string, session *inAppSSHSession) {
	body, truncated := session.drainOutput()
	out := inAppSSHResponse{
		SessionID: id,
		Active:    session.active(),
		Truncated: truncated,
	}
	setTextOrBase64(body, &out.Body, &out.BodyBase64)
	writeInAppJSON(w, status, out)
}

func randomSessionID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}