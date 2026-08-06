package libtailscale

import (
	"context"
	"log"
	"net"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"tailscale.com/tailcfg"
)

var derpLookupNetIP = net.DefaultResolver.LookupNetIP

func (app *App) refreshUsableDERPMapForLocalAPI(endpoint string) {
	app.mu.Lock()
	b := app.backendState
	app.mu.Unlock()
	if b == nil || b.backend == nil || b.sys == nil {
		return
	}
	app.ensureCurrentUsableDERPMap(func() (*tailcfg.DERPMap, string) {
		return b.backend.DERPMap(), b.backend.Prefs().ControlURL()
	}, func(sanitized *tailcfg.DERPMap) bool {
		if mc := b.sys.MagicSock.Get(); mc != nil {
			mc.SetDERPMap(sanitized)
			return true
		}
		return false
	})
}

// ensureCurrentUsableDERPMap evaluates each DERPMap/control URL pair once, then
// ensures the cached sanitized map is installed whenever a caller reaches this
// point. Keeping evaluation separate from installation has three important
// properties:
//   - a map that needs no changes is remembered instead of repeating DNS work;
//   - a failed install can be retried without repeating DNS work; and
//   - a prefs edit that makes LocalBackend restore its original map can be
//     followed by another ensure call to restore the sanitized clone.
//
// magicsock's SetDERPMap is content-idempotent, so reinstalling an unchanged
// sanitized map is a cheap no-op and does not reconnect DERP.
//
// Reading the current source and installing its sanitized form are serialized.
// The source is checked again after installation so an older evaluation cannot
// overwrite a newer map when control updates the netmap concurrently.
func (app *App) ensureCurrentUsableDERPMap(current func() (*tailcfg.DERPMap, string), install func(*tailcfg.DERPMap) bool) bool {
	app.derpMapMu.Lock()
	defer app.derpMapMu.Unlock()

	// Netmap churn is normally one update at a time. Bound the loop so a control
	// plane continuously replacing maps cannot monopolize a LocalAPI request; a
	// later notification/request will retry the latest source.
	for range 4 {
		source, controlURL := current()
		if source == nil {
			return false
		}
		sanitized, changed := app.evaluateDERPMapSourceLocked(source, controlURL)
		installed := true
		if changed {
			installed = install(sanitized)
		}

		latestSource, latestControlURL := current()
		if latestSource == source && latestControlURL == controlURL {
			return installed
		}
	}
	return false
}

func (app *App) evaluateDERPMapSourceLocked(source *tailcfg.DERPMap, controlURL string) (*tailcfg.DERPMap, bool) {
	if app.derpMapEvaluationReady &&
		app.evaluatedDERPMap == source &&
		app.evaluatedDERPControlURL == controlURL {
		return app.evaluatedSanitizedDERPMap, app.evaluatedSanitizedDERPMap != nil
	}

	sanitized, changed := sanitizeDERPMapForIOS(source, controlURL)
	app.evaluatedDERPMap = source
	app.evaluatedDERPControlURL = controlURL
	app.derpMapEvaluationReady = true
	if changed {
		app.evaluatedSanitizedDERPMap = sanitized
	} else {
		app.evaluatedSanitizedDERPMap = nil
	}
	return sanitized, changed
}

func sanitizeDERPMapForIOS(dm *tailcfg.DERPMap, controlURL string) (*tailcfg.DERPMap, bool) {
	if dm == nil {
		return nil, false
	}
	var out *tailcfg.DERPMap
	changed := false
	for regionID, region := range dm.Regions {
		if region == nil {
			continue
		}
		for _, node := range region.Nodes {
			if node == nil || node.HostName == "" {
				continue
			}
			addr, hasLoopbackIPv4 := derpLoopbackIPv4(node.IPv4)
			hasSingleLabelHost := !strings.Contains(node.HostName, ".")
			shouldPinCustomHost := shouldPinCustomDERPIPv4(node.HostName, controlURL)
			var resolved netip.Addr
			var resolvedLoopback bool
			if !hasLoopbackIPv4 && !hasSingleLabelHost && !shouldPinCustomHost {
				// Official DERP hostnames already have a usable control-provided
				// definition. Resolving every official hostname here adds no useful
				// fallback and can serialize one DNS timeout per node on every API
				// request when the resolver is unhealthy.
				normalizedHost := strings.Trim(strings.ToLower(node.HostName), ".")
				if isOfficialTailscaleDERPHost(normalizedHost) {
					continue
				}
				resolved, resolvedLoopback = derpHostnameResolvesToLoopback(node.HostName)
				if !resolvedLoopback {
					continue
				}
			}

			fallback, fallbackName, fallbackHostName := resolveDERPFallbackIPv4(node.HostName, controlURL)
			if fallback.IsValid() && node.IPv4 == fallback.String() && (fallbackHostName == "" || node.HostName == fallbackHostName) {
				continue
			}
			if out == nil {
				out = dm.Clone()
			}
			if outRegion := out.Regions[regionID]; outRegion != nil {
				for _, outNode := range outRegion.Nodes {
					if outNode != nil && outNode.Name == node.Name {
						if fallback.IsValid() {
							if fallbackHostName != "" {
								outNode.HostName = fallbackHostName
							}
							outNode.IPv4 = fallback.String()
							outNode.IPv6 = "none"
							log.Printf("derpmap: DERP node %s host=%s effectiveHost=%s forcedIPv4=%q loopback=%s resolvedLoopback=%s singleLabel=%v using %s=%s", node.Name, node.HostName, outNode.HostName, node.IPv4, addr, resolved, hasSingleLabelHost, fallbackName, fallback)
						} else {
							outNode.IPv4 = ""
							log.Printf("derpmap: DERP node %s host=%s forcedIPv4=%q loopback=%s resolvedLoopback=%s singleLabel=%v clearing forced IPv4", node.Name, node.HostName, node.IPv4, addr, resolved, hasSingleLabelHost)
						}
						changed = true
						break
					}
				}
			}
		}
	}
	if !changed {
		return nil, false
	}
	return out, true
}

func derpLoopbackIPv4(value string) (netip.Addr, bool) {
	addr, err := netip.ParseAddr(value)
	if err != nil || !addr.Is4() || !addr.IsLoopback() {
		return netip.Addr{}, false
	}
	return addr, true
}

func derpHostnameResolvesToLoopback(host string) (netip.Addr, bool) {
	addr, ok := firstDERPIPv4(host)
	return addr, ok && addr.IsLoopback()
}

func resolveDERPFallbackIPv4(host, controlURL string) (netip.Addr, string, string) {
	if addr, name, hostName := explicitDERPPublicIPv4(host); addr.IsValid() {
		return addr, name, hostName
	}
	for _, candidate := range derpFallbackHostnames(host, controlURL) {
		if addr, name, hostName := explicitDERPPublicIPv4(candidate); addr.IsValid() {
			return addr, name, hostName
		}
		addr, ok := firstDERPIPv4(candidate)
		if ok && !addr.IsLoopback() && !addr.IsPrivate() && !addr.IsLinkLocalUnicast() {
			return addr, candidate, ""
		}
		if ok && !addr.IsLoopback() && !addr.IsLinkLocalUnicast() {
			return addr, candidate, ""
		}
	}
	return netip.Addr{}, "", ""
}

func explicitDERPPublicIPv4(host string) (netip.Addr, string, string) {
	switch strings.Trim(strings.ToLower(host), ".") {
	case "ctl2.yesican.top":
		return netip.MustParseAddr("141.98.196.111"), "ctl.yesican.top/public", "ctl.yesican.top"
	case "ctl.yesican.top":
		return netip.MustParseAddr("141.98.196.111"), "ctl.yesican.top/public", ""
	default:
		return netip.Addr{}, "", ""
	}
}

func firstDERPIPv4(host string) (netip.Addr, bool) {
	if host == "" {
		return netip.Addr{}, false
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		return addr, addr.Is4()
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	addrs, err := derpLookupNetIP(ctx, "ip4", host)
	if err != nil {
		return netip.Addr{}, false
	}
	for _, addr := range addrs {
		addr = addr.Unmap()
		if addr.Is4() {
			return addr, true
		}
	}
	return netip.Addr{}, false
}

func derpFallbackHostnames(host, controlURL string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, 4)
	add := func(candidate string) {
		candidate = strings.Trim(candidate, ".")
		if candidate == "" || seen[candidate] {
			return
		}
		seen[candidate] = true
		out = append(out, candidate)
	}

	add(host)
	if !strings.Contains(host, ".") {
		add(host + ".lan")
	}
	if controlHost := controlURLHostname(controlURL); controlHost != "" {
		parts := strings.Split(controlHost, ".")
		if len(parts) > 2 && !strings.Contains(host, ".") {
			add(host + "." + strings.Join(parts[1:], "."))
		}
		add(controlHost)
	}
	return out
}

func shouldPinCustomDERPIPv4(host, controlURL string) bool {
	host = strings.Trim(strings.ToLower(host), ".")
	controlHost := strings.Trim(strings.ToLower(controlURLHostname(controlURL)), ".")
	if host == "" || isOfficialTailscaleDERPHost(host) || net.ParseIP(host) != nil {
		return false
	}
	if controlHost == "" {
		return true
	}
	if isOfficialTailscaleControlHost(controlHost) {
		return false
	}
	if host == controlHost || strings.HasSuffix(host, "."+controlHost) {
		return true
	}
	parts := strings.Split(controlHost, ".")
	if len(parts) > 2 {
		parentDomain := strings.Join(parts[1:], ".")
		return host == parentDomain || strings.HasSuffix(host, "."+parentDomain)
	}
	return false
}

func isOfficialTailscaleDERPHost(host string) bool {
	return strings.HasSuffix(host, ".tailscale.com") || strings.HasSuffix(host, ".tailscale.io")
}

func isOfficialTailscaleControlHost(host string) bool {
	return host == "login.tailscale.com" ||
		host == "controlplane.tailscale.com" ||
		strings.HasSuffix(host, ".tailscale.com")
}

func controlURLHostname(controlURL string) string {
	if controlURL == "" {
		return ""
	}
	u, err := url.Parse(controlURL)
	if err != nil {
		return ""
	}
	return u.Hostname()
}
