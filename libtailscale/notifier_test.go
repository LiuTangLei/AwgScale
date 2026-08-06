package libtailscale

import (
	"testing"

	"tailscale.com/ipn"
	"tailscale.com/tailcfg"
	"tailscale.com/types/netmap"
)

func TestNotifyNeedsCompleteNetMapSnapshot(t *testing.T) {
	tests := []struct {
		name   string
		notify *ipn.Notify
		want   bool
	}{
		{"nil", nil, false},
		{"state-only", &ipn.Notify{}, false},
		{"legacy-netmap", &ipn.Notify{NetMap: new(netmap.NetworkMap)}, true},
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

func TestIOSNotifyMaskIsAcceptedByTailscale102(t *testing.T) {
	const mask = ipn.NotifyInitialNetMap |
		ipn.NotifyInitialPrefs |
		ipn.NotifyInitialState |
		ipn.NotifyInitialOutgoingFiles |
		ipn.NotifyInitialHealthState |
		ipn.NotifyPeerChanges
	if err := ipn.ValidateNotifyWatchOpt(mask); err != nil {
		t.Fatalf("iOS notification mask is invalid: %v", err)
	}
}
