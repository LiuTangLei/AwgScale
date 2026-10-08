package libtailscale

import (
	"context"
	"encoding/json"
	"log"
	"runtime/debug"

	"tailscale.com/ipn"
	"tailscale.com/types/netmap"
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

		// Keep the app/extension snapshot contract while subscribing to the
		// upstream 1.104 status and peer-delta API.
		var snapshot *netmap.NetworkMap
		if notifyNeedsCompleteNetMapSnapshot(notify) {
			snapshot = backend.NetMapWithPeers()
			if snapshot != nil {
				app.refreshUsableDERPMapForLocalAPI("netmap-notify")
			}
		}
		b, err := marshalNotification(notify, snapshot)
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
	return notify != nil && (notify.InitialStatus != nil ||
		notify.SelfChange != nil ||
		len(notify.PeersChanged) != 0 ||
		len(notify.PeersRemoved) != 0 ||
		len(notify.UserProfiles) != 0)
}

func marshalNotification(notify *ipn.Notify, snapshot *netmap.NetworkMap) ([]byte, error) {
	return json.Marshal(struct {
		*ipn.Notify
		NetMap *netmap.NetworkMap `json:",omitempty"`
	}{notify, snapshot})
}

type notificationManager struct {
	cancel func()
}

func (nm *notificationManager) Stop() {
	nm.cancel()
}
