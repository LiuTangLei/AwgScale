package libtailscale

import (
	"encoding/base64"
	"encoding/json"
	"iter"

	"tailscale.com/ipn"
)

const logPrefKey = "privatelogid"

type stateStore struct {
	appCtx AppContext
}

func newStateStore(appCtx AppContext) *stateStore {
	return &stateStore{appCtx: appCtx}
}

var _ ipn.StateStore = (*stateStore)(nil)

func prefKeyFor(id ipn.StateKey) string {
	return "statestore-" + string(id)
}

func (s *stateStore) All() iter.Seq2[ipn.StateKey, []byte] {
	rawJSON := s.appCtx.GetStateStoreKeysJSON()
	var keys []string
	if err := json.Unmarshal([]byte(rawJSON), &keys); err != nil {
		return func(yield func(ipn.StateKey, []byte) bool) {}
	}
	return func(yield func(ipn.StateKey, []byte) bool) {
		for _, k := range keys {
			blob, err := s.ReadState(ipn.StateKey(k))
			if err != nil {
				continue
			}
			if !yield(ipn.StateKey(k), blob) {
				return
			}
		}
	}
}

func (s *stateStore) ReadState(id ipn.StateKey) ([]byte, error) {
	state, err := s.read(prefKeyFor(id))
	if err != nil {
		return nil, err
	}
	if state == nil {
		return nil, ipn.ErrStateNotExist
	}
	return state, nil
}

func (s *stateStore) WriteState(id ipn.StateKey, bs []byte) error {
	return s.write(prefKeyFor(id), bs)
}

func (s *stateStore) read(key string) ([]byte, error) {
	b64, err := s.appCtx.DecryptFromPref(key)
	if err != nil {
		return nil, err
	}
	if b64 == "" {
		return nil, nil
	}
	return base64.RawStdEncoding.DecodeString(b64)
}

func (s *stateStore) write(key string, value []byte) error {
	bs64 := base64.RawStdEncoding.EncodeToString(value)
	return s.appCtx.EncryptToPref(key, bs64)
}
