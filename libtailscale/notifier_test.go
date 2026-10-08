package libtailscale

import (
	"encoding/json"
	"tailscale.com/types/netmap"
	"testing"

	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
)

func TestNotifyNeedsCompleteNetMapSnapshot(t *testing.T) {
	tests := []struct {
		name   string
		notify *ipn.Notify
		want   bool
	}{
		{"nil", nil, false},
		{"state-only", &ipn.Notify{}, false},
		{"initial-status", &ipn.Notify{InitialStatus: new(ipnstate.Status)}, true},
		{"self-change", &ipn.Notify{SelfChange: &tailcfg.Node{}}, true},
		{"peer-upsert", &ipn.Notify{PeersChanged: []*tailcfg.Node{{ID: 1}}}, true},
		{"peer-removal", &ipn.Notify{PeersRemoved: []tailcfg.NodeID{1}}, true},
		{"user-profile", &ipn.Notify{UserProfiles: map[tailcfg.UserID]tailcfg.UserProfileView{1: {}}}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := notifyNeedsCompleteNetMapSnapshot(tt.notify); got != tt.want {
				t.Fatalf("notifyNeedsCompleteNetMapSnapshot() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestIOSNotifyMaskIsAcceptedByTailscale104(t *testing.T) {
	const mask = ipn.NotifyInitialStatus |
		ipn.NotifyInitialPrefs |
		ipn.NotifyInitialState |
		ipn.NotifyInitialOutgoingFiles |
		ipn.NotifyInitialHealthState |
		ipn.NotifyPeerChanges
	if err := ipn.ValidateNotifyWatchOpt(mask); err != nil {
		t.Fatalf("iOS notification mask is invalid: %v", err)
	}
}

func TestNotificationSnapshotJSONContract(t *testing.T) {
	state := ipn.Running
	b, err := marshalNotification(&ipn.Notify{State: &state}, &netmap.NetworkMap{Domain: "test-node"})
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		State  ipn.State
		NetMap struct{ Domain string }
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.State != state || got.NetMap.Domain != "test-node" {
		t.Fatalf("notification lost fields: %s", b)
	}
}
