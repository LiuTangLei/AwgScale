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

type notificationManager struct {
	cancel func()
}

func (nm *notificationManager) Stop() {
	nm.cancel()
}
