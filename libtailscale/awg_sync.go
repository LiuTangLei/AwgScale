package libtailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/netip"
	"sort"
	"sync"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnauth"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/wgengine/magicsock"
)

type awgSyncApplyRequest struct {
	NodeKey key.NodePublic `json:"nodeKey"`
	Timeout int            `json:"timeout"`
}

type awgSyncPeerResult struct {
	NodeKey     string             `json:"nodeKey"`
	Hostname    string             `json:"hostname"`
	TailscaleIP string             `json:"tailscaleIP,omitempty"`
	Config      ipn.AmneziaWGPrefs `json:"config"`
	Err         string             `json:"error,omitempty"`
	idx         int
}

// The upstream LocalAPI endpoint waits a long time for every online peer to
// answer. The in-app peer list needs a fast hint and the full apply request
// still retries when the user chooses a peer.
func (a *App) handleAWGSyncPeers(w http.ResponseWriter, r *http.Request, b *backend) {
	if r.Method != http.MethodGet {
		http.Error(w, "only GET allowed", http.StatusMethodNotAllowed)
		return
	}
	if b == nil || b.backend == nil || b.sys == nil {
		http.Error(w, "tailnet backend is not ready", http.StatusBadGateway)
		return
	}

	nm := b.backend.NetMap()
	if nm == nil {
		http.Error(w, "no netmap available", http.StatusInternalServerError)
		return
	}

	ms, ok := b.sys.MagicSock.GetOK()
	if !ok || ms == nil {
		http.Error(w, "magicsock not available", http.StatusBadGateway)
		return
	}

	const maxConcurrent = 12
	const perPeerTimeout = 3 * time.Second

	sem := make(chan struct{}, maxConcurrent)
	results := make(chan awgSyncPeerResult, len(nm.Peers))
	var wg sync.WaitGroup

	for i, peer := range nm.Peers {
		if !peer.Valid() || peer.Hostinfo().ShareeNode() {
			continue
		}
		if online := peer.Online(); !online.Valid() || !online.Get() {
			continue
		}

		i := i
		peer := peer
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			result := awgSyncPeerResult{
				idx:      i,
				NodeKey:  peer.Key().String(),
				Hostname: peer.Hostinfo().Hostname(),
			}
			if addrs := peer.Addresses(); addrs.Len() > 0 {
				result.TailscaleIP = addrs.At(0).Addr().String()
			}

			if peer.DiscoKey().IsZero() {
				result.Err = "peer has no disco key"
				results <- result
				return
			}

			ctx, cancel := context.WithTimeout(r.Context(), perPeerTimeout)
			config, err := requestPeerAmneziaWGConfigOnce(ctx, ms, peer.DiscoKey())
			cancel()
			if err != nil {
				result.Err = err.Error()
			} else {
				result.Config = config
			}
			results <- result
		}()
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	collected := make([]awgSyncPeerResult, 0)
	for result := range results {
		if result.Err != "" {
			log.Printf("awg-sync-peers: fast probe skipped peer %s (%s): %s", result.Hostname, result.NodeKey, result.Err)
			continue
		}
		if result.Config == (ipn.AmneziaWGPrefs{}) {
			continue
		}
		collected = append(collected, result)
	}

	sort.SliceStable(collected, func(i, j int) bool {
		return collected[i].idx < collected[j].idx
	})

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(collected); err != nil {
		log.Printf("failed to encode awg-sync-peers response: %v", err)
	}
}

func (a *App) handleAWGSyncApply(w http.ResponseWriter, r *http.Request, b *backend) {
	if r.Method != http.MethodPost {
		http.Error(w, "only POST allowed", http.StatusMethodNotAllowed)
		return
	}

	var req awgSyncApplyRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.NodeKey.IsZero() {
		http.Error(w, "nodeKey required", http.StatusBadRequest)
		return
	}

	timeout := 10 * time.Second
	if req.Timeout > 0 && req.Timeout <= 60 {
		timeout = time.Duration(req.Timeout) * time.Second
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	nm := b.backend.NetMap()
	if nm == nil {
		http.Error(w, "no netmap available", http.StatusInternalServerError)
		return
	}

	var target tailcfg.NodeView
	for _, peer := range nm.Peers {
		if peer.Key() == req.NodeKey {
			target = peer
			break
		}
	}
	if !target.Valid() {
		http.Error(w, "peer not found", http.StatusNotFound)
		return
	}

	cfg, err := a.requestPeerAmneziaWGConfigWithRetry(ctx, b, target)
	if err != nil {
		http.Error(w, "failed to fetch config: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if cfg == (ipn.AmneziaWGPrefs{}) {
		http.Error(w, "peer has no Amnezia-WG config", http.StatusConflict)
		return
	}

	mp := &ipn.MaskedPrefs{Prefs: ipn.Prefs{AmneziaWG: cfg}, AmneziaWGSet: true}
	if _, err := b.backend.EditPrefsAs(mp, ipnauth.Self); err != nil {
		http.Error(w, "failed to apply config: "+err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(cfg); err != nil {
		log.Printf("failed to encode awg-sync-apply response: %v", err)
	}
}

func (a *App) requestPeerAmneziaWGConfigWithRetry(ctx context.Context, b *backend, target tailcfg.NodeView) (ipn.AmneziaWGPrefs, error) {
	discoKey := target.DiscoKey()
	if discoKey.IsZero() {
		return ipn.AmneziaWGPrefs{}, errors.New("peer has no disco key")
	}

	ms, ok := b.sys.MagicSock.GetOK()
	if !ok || ms == nil {
		return ipn.AmneziaWGPrefs{}, errors.New("magicsock not available")
	}

	var peerIP netip.Addr
	if addrs := target.Addresses(); addrs.Len() > 0 {
		peerIP = addrs.At(0).Addr()
	}

	var lastErr error
	for attempt := 1; ; attempt++ {
		if err := ctx.Err(); err != nil {
			if lastErr != nil {
				return ipn.AmneziaWGPrefs{}, fmt.Errorf("%w; last attempt: %v", err, lastErr)
			}
			return ipn.AmneziaWGPrefs{}, err
		}

		a.refreshUsableDERPMapForLocalAPI(fmt.Sprintf("awg-sync-attempt-%d", attempt))
		if peerIP.IsValid() {
			pingCtx, cancel := context.WithTimeout(ctx, minDuration(5*time.Second, timeUntilContextDeadline(ctx)))
			pr, err := b.backend.Ping(pingCtx, peerIP, tailcfg.PingDisco, 0)
			cancel()
			if err != nil {
				lastErr = err
				log.Printf("awg-sync-apply: attempt %d disco ping to %s failed: %v", attempt, target.Key().ShortString(), err)
			} else if pr != nil && pr.Err != "" {
				lastErr = errors.New(pr.Err)
				log.Printf("awg-sync-apply: attempt %d disco ping to %s returned error: %s", attempt, target.Key().ShortString(), pr.Err)
			} else if pr != nil {
				log.Printf("awg-sync-apply: attempt %d disco ping to %s ok endpoint=%q derp=%d latency=%.3fs", attempt, target.Key().ShortString(), pr.Endpoint, pr.DERPRegionID, pr.LatencySeconds)
			}
		}

		attemptTimeout := minDuration(8*time.Second, timeUntilContextDeadline(ctx))
		if attemptTimeout <= 0 {
			continue
		}
		attemptCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
		cfg, err := requestPeerAmneziaWGConfigOnce(attemptCtx, ms, discoKey)
		cancel()
		if err == nil {
			log.Printf("awg-sync-apply: attempt %d received AmneziaWG config from %s", attempt, target.Key().ShortString())
			return cfg, nil
		}

		lastErr = err
		log.Printf("awg-sync-apply: attempt %d request to %s failed: %v", attempt, target.Key().ShortString(), err)
		if ctx.Err() != nil {
			continue
		}
		select {
		case <-time.After(750 * time.Millisecond):
		case <-ctx.Done():
		}
	}
}

func requestPeerAmneziaWGConfigOnce(ctx context.Context, ms *magicsock.Conn, discoKey key.DiscoPublic) (ipn.AmneziaWGPrefs, error) {
	respCh := make(chan *magicsock.AmneziaWGConfigData, 1)
	if err := ms.RequestAmneziaWGConfigCtx(ctx, discoKey, respCh); err != nil {
		return ipn.AmneziaWGPrefs{}, err
	}

	select {
	case resp := <-respCh:
		var cfg ipn.AmneziaWGPrefs
		if err := json.Unmarshal(resp.ConfigJSON, &cfg); err != nil {
			return ipn.AmneziaWGPrefs{}, err
		}
		return cfg, nil
	case <-ctx.Done():
		return ipn.AmneziaWGPrefs{}, ctx.Err()
	}
}

func timeUntilContextDeadline(ctx context.Context) time.Duration {
	deadline, ok := ctx.Deadline()
	if !ok {
		return time.Hour
	}
	return time.Until(deadline)
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
