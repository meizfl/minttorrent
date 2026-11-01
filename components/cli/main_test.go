package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type handlerTransport struct{ handler http.Handler }

func (t handlerTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	copy := httptest.NewRequest(request.Method, request.URL.String(), request.Body)
	copy.Header = request.Header.Clone()
	recorder := httptest.NewRecorder()
	t.handler.ServeHTTP(recorder, copy)
	return recorder.Result(), nil
}

func testClient(t *testing.T, handler http.Handler) *apiClient {
	t.Helper()
	transport := handlerTransport{handler: handler}
	client, err := newAPIClient("http://127.0.0.1:4101", "admin", "secret", &http.Client{Transport: transport})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestAPILoginAndVPNStatus(t *testing.T) {
	api := testClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v2/auth/login":
			if err := r.ParseForm(); err != nil || r.Form.Get("username") != "admin" || r.Form.Get("password") != "secret" {
				http.Error(w, "bad credentials", http.StatusUnauthorized)
				return
			}
			http.SetCookie(w, &http.Cookie{Name: "QBT_SID_4101", Value: "session", Path: "/"})
			w.WriteHeader(http.StatusNoContent)
		case "/api/v2/app/minttorrentVpnStatus":
			cookie, err := r.Cookie("QBT_SID_4101")
			if err != nil || cookie.Value != "session" {
				http.Error(w, "unauthorized", http.StatusForbidden)
				return
			}
			io.WriteString(w, `{"active":true,"mtu":1280}`)
		default:
			http.NotFound(w, r)
		}
	}))
	if err := api.login(); err != nil {
		t.Fatal(err)
	}
	data, err := api.get("app/minttorrentVpnStatus")
	if err != nil {
		t.Fatal(err)
	}
	var status map[string]any
	if err := json.Unmarshal(data, &status); err != nil || status["active"] != true || status["mtu"] != float64(1280) {
		t.Fatalf("unexpected status response: %s (%v)", data, err)
	}
}

func TestLegacySIDCookie(t *testing.T) {
	api := testClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v2/auth/login" {
			http.SetCookie(w, &http.Cookie{Name: "SID", Value: "legacy-session", Path: "/"})
			io.WriteString(w, "Ok.")
			return
		}
		cookie, err := r.Cookie("SID")
		if err != nil || cookie.Value != "legacy-session" {
			http.Error(w, "unauthorized", http.StatusForbidden)
			return
		}
		io.WriteString(w, "[]")
	}))
	if err := api.login(); err != nil {
		t.Fatal(err)
	}
	if _, err := api.get("torrents/info"); err != nil {
		t.Fatal(err)
	}
}

func TestVPNProfileImportForm(t *testing.T) {
	profile := "[Interface]\nPrivateKey = test\n"
	api := testClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2/app/minttorrentVpnImport" || r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if r.Form.Get("profile") != profile || r.Form.Get("ipv4") != "true" || r.Form.Get("mtu") != "1280" {
			http.Error(w, "unexpected form values", http.StatusBadRequest)
			return
		}
		io.WriteString(w, "Ok.")
	}))
	form := url.Values{"ipv4": {"true"}, "mtu": {"1280"}}
	if err := api.uploadProfile(form, []byte(profile)); err != nil {
		t.Fatal(err)
	}
}

func TestTorrentAddMagnetAndFile(t *testing.T) {
	var sawMagnet, sawFile bool
	api := testClient(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v2/torrents/add" {
			http.NotFound(w, r)
			return
		}
		if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
			file, header, err := r.FormFile("torrents")
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			defer file.Close()
			content, _ := io.ReadAll(file)
			sawFile = header.Filename == "test.torrent" && string(content) == "torrent bytes"
		} else {
			r.ParseForm()
			sawMagnet = r.Form.Get("urls") == "magnet:?xt=urn:btih:test"
		}
		w.WriteHeader(http.StatusOK)
	}))
	if err := api.addTorrent("magnet:?xt=urn:btih:test"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "test.torrent")
	if err := os.WriteFile(path, []byte("torrent bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := api.addTorrent(path); err != nil {
		t.Fatal(err)
	}
	if !sawMagnet || !sawFile {
		t.Fatalf("torrent submissions missing: magnet=%v file=%v", sawMagnet, sawFile)
	}
}

func TestRedactedRemovesSecretFields(t *testing.T) {
	value := map[string]any{
		"web_ui_password": "hash", "nested": map[string]any{"api_token": "secret", "safe": true},
	}
	result := redacted(value).(map[string]any)
	if result["web_ui_password"] != "[redacted]" || result["nested"].(map[string]any)["api_token"] != "[redacted]" {
		t.Fatalf("sensitive configuration was not redacted: %#v", result)
	}
}

func TestDecodeJSONSettingsPreservesIntegerLexemes(t *testing.T) {
	settings, err := decodeJSONSettings([]byte(`{"packet_queue":1024,"tcp_send_buffer":1048576,"mtu":0}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := settings["tcp_send_buffer"].(json.Number).String(); got != "1048576" {
		t.Fatalf("buffer size changed during JSON decoding: %q", got)
	}
}

func TestNonLoopbackHTTPCredentialsAreRejected(t *testing.T) {
	if _, err := newAPIClient("http://192.0.2.1:4101", "admin", "secret", nil); err == nil {
		t.Fatal("expected cleartext non-loopback URL to be rejected")
	}
}
