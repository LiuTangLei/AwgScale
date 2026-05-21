package libtailscale

import (
	"context"
	"net/netip"
	"reflect"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func TestAppendDNSResponseAddrsParsesAAndAAAA(t *testing.T) {
	name, err := dnsmessage.NewName("web.tailnet.ts.net.")
	if err != nil {
		t.Fatal(err)
	}

	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{Response: true})
	if err := builder.StartAnswers(); err != nil {
		t.Fatal(err)
	}
	header := dnsmessage.ResourceHeader{Name: name, Class: dnsmessage.ClassINET, TTL: 60}
	if err := builder.AResource(header, dnsmessage.AResource{A: [4]byte{100, 64, 1, 2}}); err != nil {
		t.Fatal(err)
	}
	if err := builder.AAAAResource(header, dnsmessage.AAAAResource{AAAA: [16]byte{
		0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 1,
	}}); err != nil {
		t.Fatal(err)
	}
	response, err := builder.Finish()
	if err != nil {
		t.Fatal(err)
	}

	got := appendDNSResponseAddrs(nil, response)
	want := []netip.Addr{
		netip.MustParseAddr("100.64.1.2"),
		netip.MustParseAddr("fd7a:115c:a1e0::1"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("appendDNSResponseAddrs() = %v, want %v", got, want)
	}
}

func TestInAppAddrShouldStayInTailnet(t *testing.T) {
	tests := []struct {
		addr string
		want bool
	}{
		{"100.64.1.2", true},
		{"192.168.1.10", true},
		{"127.0.0.1", true},
		{"fd7a:115c:a1e0::1", true},
		{"8.8.8.8", false},
		{"2606:4700:4700::1111", false},
	}

	for _, tt := range tests {
		got := inAppAddrShouldStayInTailnet(netip.MustParseAddr(tt.addr))
		if got != tt.want {
			t.Fatalf("inAppAddrShouldStayInTailnet(%q) = %v, want %v", tt.addr, got, tt.want)
		}
	}
}

func TestInAppHostnameShouldStayInTailnetWithoutBackend(t *testing.T) {
	tests := []struct {
		host string
		want bool
	}{
		{"nas", true},
		{"nas.", true},
		{"web.tailnet.ts.net", true},
		{"web.tailnet.ts.net.", true},
		{"web.tailnet.beta.tailscale.net", true},
		{"www.google.com", false},
	}

	for _, tt := range tests {
		got := inAppHostnameShouldStayInTailnet(nil, tt.host)
		if got != tt.want {
			t.Fatalf("inAppHostnameShouldStayInTailnet(%q) = %v, want %v", tt.host, got, tt.want)
		}
	}
}

func TestInAppSSHWaitForOutputReturnsOnAppend(t *testing.T) {
	session := &inAppSSHSession{
		done:        make(chan struct{}),
		outputReady: make(chan struct{}, 1),
	}
	waitReturned := make(chan struct{})
	go func() {
		session.waitForOutput(context.Background(), time.Second)
		close(waitReturned)
	}()

	select {
	case <-waitReturned:
		t.Fatal("waitForOutput returned before output arrived")
	case <-time.After(20 * time.Millisecond):
	}

	session.appendOutput([]byte("prompt"))

	select {
	case <-waitReturned:
	case <-time.After(time.Second):
		t.Fatal("waitForOutput did not return after output arrived")
	}

	data, truncated := session.drainOutput()
	if got := string(data); got != "prompt" {
		t.Fatalf("drainOutput() body = %q, want %q", got, "prompt")
	}
	if truncated {
		t.Fatal("drainOutput() reported truncated output")
	}
}
