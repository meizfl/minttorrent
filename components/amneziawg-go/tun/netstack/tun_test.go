package netstack

import (
	"net/netip"
	"strings"
	"testing"
)

func TestFormatDNSFailureDetailsIncludesConfiguredServersInOrder(t *testing.T) {
	servers := []netip.Addr{
		netip.MustParseAddr("208.67.222.222"),
		netip.MustParseAddr("2620:119:35::35"),
		netip.MustParseAddr("2620:119:53::53"),
	}
	failures := map[netip.Addr]string{
		servers[0]: "first timeout",
		servers[2]: "last timeout",
	}

	got := formatDNSFailureDetails(servers, failures)
	if want := "208.67.222.222: first timeout; 2620:119:53::53: last timeout"; got != want {
		t.Fatalf("formatDNSFailureDetails() = %q, want %q", got, want)
	}
}

func TestFormatDNSFailureDetailsBoundsServerList(t *testing.T) {
	servers := make([]netip.Addr, 10)
	failures := make(map[netip.Addr]string, len(servers))
	for i := range servers {
		servers[i] = netip.AddrFrom4([4]byte{192, 0, 2, byte(i + 1)})
		failures[servers[i]] = "timeout"
	}

	got := formatDNSFailureDetails(servers, failures)
	if strings.Count(got, "timeout") != 8 || !strings.Contains(got, "2 additional DNS server(s) failed") {
		t.Fatalf("expected eight details and a bounded remainder, got %q", got)
	}
}
