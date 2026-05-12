package libtailscale

import (
	"encoding/json"
	"errors"
	"sync"

	"tailscale.com/util/set"
	"tailscale.com/util/syspolicy"
	"tailscale.com/util/syspolicy/pkey"
)

type syspolicyStore struct {
	a   *App
	mu  sync.RWMutex
	cbs set.HandleSet[func()]
}

func (h *syspolicyStore) ReadString(key pkey.Key) (string, error) {
	if key == "" {
		return "", syspolicy.ErrNoSuchKey
	}
	retVal, err := h.a.appCtx.GetSyspolicyStringValue(string(key))
	return retVal, translateHandlerError(err)
}

func (h *syspolicyStore) ReadBoolean(key pkey.Key) (bool, error) {
	if key == "" {
		return false, syspolicy.ErrNoSuchKey
	}
	retVal, err := h.a.appCtx.GetSyspolicyBooleanValue(string(key))
	return retVal, translateHandlerError(err)
}

func (h *syspolicyStore) ReadUInt64(key pkey.Key) (uint64, error) {
	if key == "" {
		return 0, syspolicy.ErrNoSuchKey
	}
	return 0, errors.New("ReadUInt64 is not implemented on iOS")
}

func (h *syspolicyStore) ReadStringArray(key pkey.Key) ([]string, error) {
	if key == "" {
		return nil, syspolicy.ErrNoSuchKey
	}
	retVal, err := h.a.appCtx.GetSyspolicyStringArrayJSONValue(string(key))
	if err := translateHandlerError(err); err != nil {
		return nil, err
	}
	if retVal == "" {
		return nil, syspolicy.ErrNoSuchKey
	}
	var arr []string
	if jsonErr := json.Unmarshal([]byte(retVal), &arr); jsonErr != nil {
		return nil, jsonErr
	}
	return arr, nil
}

func (h *syspolicyStore) RegisterChangeCallback(cb func()) (unregister func(), err error) {
	h.mu.Lock()
	handle := h.cbs.Add(cb)
	h.mu.Unlock()
	return func() {
		h.mu.Lock()
		delete(h.cbs, handle)
		h.mu.Unlock()
	}, nil
}

func (h *syspolicyStore) notifyChanged() {
	h.mu.RLock()
	for _, cb := range h.cbs {
		go cb()
	}
	h.mu.RUnlock()
}

func translateHandlerError(err error) error {
	if err != nil && !errors.Is(err, syspolicy.ErrNoSuchKey) && err.Error() == syspolicy.ErrNoSuchKey.Error() {
		return syspolicy.ErrNoSuchKey
	}
	return err
}
