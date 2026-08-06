package libtailscale

import (
	"context"
	"encoding/json"
	"log"
	"runtime/debug"

	"tailscale.com/ipn"
)

func (app *App) WatchNotifications(mask int, cb NotificationCallback) NotificationManager {
	if err := app.waitReady(); err != nil {
		log.Printf("WatchNotifications: backend not ready: %v", err)
		return nil
	}
	app.mu.Lock()
	backend := app.backend
	app.mu.Unlock()
	if backend == nil {
		log.Printf("WatchNotifications: backend stopped")
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	go backend.WatchNotifications(ctx, ipn.NotifyWatchOpt(mask), func() {}, func(notify *ipn.Notify) bool {
		defer func() {
			if p := recover(); p != nil {
				log.Printf("panic in WatchNotifications %s: %s", p, debug.Stack())
				panic(p)
			}
		}()

		// Tailscale 1.102 keeps peers in LocalBackend's live node map. Even on
		// Apple platforms, where the legacy Notify.NetMap is still emitted, its
		// embedded Peers slice can therefore be stale or empty. AwgScale's app and
		// Network Extension IPC contract intentionally shares one complete
		// NetworkMap snapshot, so replace both legacy NetMap notifications and
		// peer deltas with the authoritative live view.
		if notifyNeedsCompleteNetMapSnapshot(notify) {
			if nm := backend.NetMapWithPeers(); nm != nil {
				copy := *notify
				copy.NetMap = nm
				notify = &copy
			}
		}

		if notify.NetMap != nil {
			app.refreshUsableDERPMapForLocalAPI("netmap-notify")
		}

		b, err := json.Marshal(notify)
		if err != nil {
			log.Printf("WatchNotifications: marshal: %s", err)
			return true
		}
		if err := cb.OnNotify(b); err != nil {
			log.Printf("WatchNotifications: OnNotify: %s", err)
			return true
		}
		return true
	})
	return &notificationManager{cancel}
}

func notifyNeedsCompleteNetMapSnapshot(notify *ipn.Notify) bool {
	return notify != nil && (notify.NetMap != nil ||
		notify.SelfChange != nil ||
		len(notify.PeersChanged) != 0 ||
		len(notify.PeersRemoved) != 0 ||
		len(notify.UserProfiles) != 0)
}

type notificationManager struct {
	cancel func()
}

func (nm *notificationManager) Stop() {
	nm.cancel()
}
