package libtailscale

import "tailscale.com/version"

// CoreVersion returns the embedded runtime version, not app bundle metadata.
func CoreVersion() string { return version.Long() }
