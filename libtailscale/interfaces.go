package libtailscale

import (
	_ "golang.org/x/mobile/bind"
)

// Start starts the iOS libtailscale runtime.
func Start(dataDir, directFileRoot string, hwAttestationPref bool, appCtx AppContext) Application {
	return start(dataDir, directFileRoot, hwAttestationPref, false, appCtx)
}

// StartAppLogin starts the iOS libtailscale runtime for app-process login.
// The app process is not the packet tunnel provider, so it should not bind
// control-plane sockets to a Darwin interface as the extension backend does.
func StartAppLogin(dataDir, directFileRoot string, appCtx AppContext) Application {
	return start(dataDir, directFileRoot, false, true, appCtx)
}

// AppContext provides the platform hooks implemented on the Swift side.
type AppContext interface {
	Log(tag, logLine string)
	EncryptToPref(key, value string) error
	DecryptFromPref(key string) (string, error)
	GetStateStoreKeysJSON() string
	GetOSVersion() (string, error)
	GetDeviceName() (string, error)
	GetInstallSource() string
	ShouldUseGoogleDNSFallback() bool
	IsChromeOS() (bool, error)
	GetInterfacesAsJson() (string, error)
	GetPlatformDNSConfig() string
	GetSyspolicyStringValue(key string) (string, error)
	GetSyspolicyBooleanValue(key string) (bool, error)
	GetSyspolicyStringArrayJSONValue(key string) (string, error)
	HardwareAttestationKeySupported() bool
	HardwareAttestationKeyCreate() (keyID string, err error)
	HardwareAttestationKeyRelease(keyID string) error
	HardwareAttestationKeyPublic(keyID string) (pub []byte, err error)
	HardwareAttestationKeySign(keyID string, data []byte) (sig []byte, err error)
	HardwareAttestationKeyLoad(keyID string) error
}

// Application encapsulates the running iOS libtailscale application.
type Application interface {
	CallLocalAPI(timeoutMillis int, method, endpoint string, body InputStream) (LocalAPIResponse, error)
	CallLocalAPIMultipart(timeoutMillis int, method, endpoint string, parts FileParts) (LocalAPIResponse, error)
	InjectInboundPacket(packet []byte) error
	NotifyPolicyChanged()
	SetPacketCallback(cb PacketCallback)
	Stop()
	WatchNotifications(mask int, cb NotificationCallback) NotificationManager
}

// PacketCallback receives packets written by the Go TUN device. The Swift
// PacketTunnelProvider writes them to NEPacketTunnelFlow.
type PacketCallback interface {
	OnPacket(packet []byte) error
}

// FileParts is an array of multiple FileParts.
type FileParts interface {
	Len() int32
	Get(int32) *FilePart
}

// FilePart is a multipart file that can be submitted via CallLocalAPIMultipart.
type FilePart struct {
	ContentLength int64
	Filename      string
	Body          InputStream
	ContentType   string
}

// LocalAPIResponse is a response to a localapi call.
type LocalAPIResponse interface {
	StatusCode() int
	BodyBytes() ([]byte, error)
	BodyInputStream() InputStream
}

// NotificationCallback receives ipn.Notify messages serialized as JSON.
type NotificationCallback interface {
	OnNotify([]byte) error
}

// NotificationManager lets callers stop receiving notifications.
type NotificationManager interface {
	Stop()
}

// InputStream provides an adapter between Swift streams and Go readers.
type InputStream interface {
	Read() ([]byte, error)
	Close() error
}

// OutputStream provides an adapter between Swift streams and Go writers.
type OutputStream interface {
	Write([]byte) (int, error)
	Close() error
}

// TunnelConfigCallback receives tunnel configuration updates from the Go
// backend (router.Config + dns.OSConfig) serialized as JSON. Swift implements
// this to call NEPacketTunnelProvider.setTunnelNetworkSettings.
type TunnelConfigCallback interface {
	// OnTunnelConfigUpdate receives a JSON-encoded TunnelConfig. The
	// Extension must apply these settings and return nil on success.
	OnTunnelConfigUpdate(configJSON []byte) error
}

// SetTunnelConfigCallback registers a callback that will be invoked whenever
// the Go backend updates the VPN tunnel configuration (routes, DNS, etc.).
// Must be called after Start() and before the backend sends its first config.
func SetTunnelConfigCallback(app Application, cb TunnelConfigCallback) {
	if a, ok := app.(*App); ok {
		a.setTunnelConfigCallback(cb)
	}
}
