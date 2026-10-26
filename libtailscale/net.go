package libtailscale

import (
	"log"
	"net/netip"
	"strings"

	"github.com/LiuTangLei/awgscale-ios/libtailscale/ifaceparse"
	"tailscale.com/net/dns"
	"tailscale.com/net/netmon"
	"tailscale.com/util/dnsname"
)

var googleDNSServers = []netip.Addr{
	netip.MustParseAddr("8.8.8.8"),
	netip.MustParseAddr("8.8.4.4"),
	netip.MustParseAddr("2001:4860:4860::8888"),
	netip.MustParseAddr("2001:4860:4860::8844"),
}

func (a *App) getInterfaces() ([]netmon.Interface, error) {
	jsonStr, err := a.appCtx.GetInterfacesAsJson()
	if err != nil {
		return nil, err
	}
	jsonStr = strings.TrimSpace(jsonStr)
	if jsonStr == "" {
		return nil, nil
	}
	ifaces, _, err := ifaceparse.ParseInterfacesJSONAsNetmon([]byte(jsonStr))
	return ifaces, err
}

func (b *backend) getDNSBaseConfig() (config dns.OSConfig, _ error) {
	defer func() {
		if len(config.Nameservers) == 0 && b.appCtx.ShouldUseGoogleDNSFallback() {
			log.Printf("getDNSBaseConfig: none found; falling back to Google public DNS")
			config.Nameservers = append(config.Nameservers, googleDNSServers...)
		}
	}()

	baseConfig := b.appCtx.GetPlatformDNSConfig()
	lines := strings.Split(baseConfig, "\n")
	if len(lines) == 0 {
		return dns.OSConfig{}, nil
	}

	addrs := strings.Trim(lines[0], " \n")
	for _, addr := range strings.Split(addrs, " ") {
		ip, err := netip.ParseAddr(addr)
		if err == nil {
			config.Nameservers = append(config.Nameservers, ip)
		}
	}

	if len(lines) > 1 {
		for _, s := range strings.Split(strings.Trim(lines[1], " \n"), " ") {
			domain, err := dnsname.ToFQDN(s)
			if err != nil {
				log.Printf("getDNSBaseConfig: unable to parse %q: %v", s, err)
				continue
			}
			config.SearchDomains = append(config.SearchDomains, domain)
		}
	}

	return config, nil
}
