package main

import (
	"errors"
	"strings"
	"testing"
)

const testKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

func testProfile(keepalive string) string {
	peerOption := ""
	if keepalive != "" {
		peerOption = "PersistentKeepalive = " + keepalive + "\n"
	}
	return "[Interface]\n" +
		"PrivateKey = " + testKey + "\n" +
		"Address = 10.0.0.2/32\n" +
		"DNS = 1.1.1.1\n" +
		"MTU = 1340\n" +
		"[Peer]\n" +
		"PublicKey = " + testKey + "\n" +
		"Endpoint = 198.51.100.1:2408\n" +
		"AllowedIPs = 0.0.0.0/0\n" + peerOption
}

func TestHealthResultTracksTransitionsAndErrors(t *testing.T) {
	stack := &stackHandle{}
	if !recordHealthResult(stack, errors.New("probe failed")) {
		t.Fatal("the initial failed probe must establish health state")
	}
	stack.healthMu.RLock()
	if stack.healthy || stack.healthErr != "probe failed" || stack.checkedAt.IsZero() {
		t.Fatalf("unexpected failed health state: healthy=%v error=%q checked=%v", stack.healthy, stack.healthErr, stack.checkedAt)
	}
	stack.healthMu.RUnlock()
	if recordHealthResult(stack, errors.New("probe still failed")) {
		t.Fatal("a repeated failure must not be treated as a health transition")
	}
	if !recordHealthResult(stack, nil) {
		t.Fatal("a successful probe must report recovery")
	}
	stack.healthMu.RLock()
	defer stack.healthMu.RUnlock()
	if !stack.healthy || stack.healthErr != "" {
		t.Fatalf("unexpected recovered health state: healthy=%v error=%q", stack.healthy, stack.healthErr)
	}
}

func TestParseProfileDefaultsPersistentKeepaliveForNAT(t *testing.T) {
	parsed, err := parseProfile(testProfile(""), true, false)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Count(parsed.ipc.String(), "persistent_keepalive_interval=25\n"); got != 1 {
		t.Fatalf("expected one 25-second keepalive, got %d in %q", got, parsed.ipc.String())
	}
}

func TestParseProfileHonorsExplicitPersistentKeepalive(t *testing.T) {
	for _, value := range []string{"0", "10"} {
		t.Run(value, func(t *testing.T) {
			parsed, err := parseProfile(testProfile(value), true, false)
			if err != nil {
				t.Fatal(err)
			}
			want := "persistent_keepalive_interval=" + value + "\n"
			if got := strings.Count(parsed.ipc.String(), want); got != 1 {
				t.Fatalf("expected explicit setting %q exactly once, got %d in %q", want, got, parsed.ipc.String())
			}
			if value != "25" && strings.Contains(parsed.ipc.String(), "persistent_keepalive_interval=25\n") {
				t.Fatalf("explicit setting %q was overridden by the default", value)
			}
		})
	}
}
