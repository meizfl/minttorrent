package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/term"
)

const defaultBaseURL = "http://127.0.0.1:4101"

type apiClient struct {
	base        *url.URL
	client      *http.Client
	user        string
	pass        string
	cookieName  string
	cookieValue string
	status      int
	cookieNames []string
}

func newAPIClient(base, username, password string, client *http.Client) (*apiClient, error) {
	parsed, err := url.Parse(base)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, fmt.Errorf("invalid WebUI URL %q", base)
	}
	if parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return nil, errors.New("WebUI URL must not contain credentials, a path, query, or fragment")
	}
	if parsed.Scheme == "http" {
		host := parsed.Hostname()
		ip := net.ParseIP(host)
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return nil, errors.New("refusing to send WebUI credentials over non-loopback HTTP; use HTTPS")
		}
	}
	if client == nil {
		client = &http.Client{Timeout: 25 * time.Second}
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return &apiClient{base: parsed, client: client, user: username, pass: password}, nil
}

func (a *apiClient) endpoint(path string) string {
	copy := *a.base
	copy.Path = strings.TrimRight(a.base.Path, "/") + "/api/v2/" + strings.TrimLeft(path, "/")
	return copy.String()
}

func (a *apiClient) request(method, path string, body io.Reader, contentType string) ([]byte, error) {
	req, err := http.NewRequest(method, a.endpoint(path), body)
	if err != nil {
		return nil, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	base := *a.base
	base.Path = strings.TrimRight(base.Path, "/") + "/"
	req.Header.Set("Origin", strings.TrimRight(base.String(), "/"))
	req.Header.Set("Referer", base.String())
	req.Header.Set("User-Agent", "MintTorrent CLI")
	if a.cookieName != "" && a.cookieValue != "" {
		req.AddCookie(&http.Cookie{Name: a.cookieName, Value: a.cookieValue})
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, err
	}
	a.status = resp.StatusCode
	a.cookieNames = a.cookieNames[:0]
	for _, cookie := range resp.Cookies() {
		a.cookieNames = append(a.cookieNames, cookie.Name)
		if cookie.Name == "SID" || strings.HasPrefix(cookie.Name, "QBT_SID_") {
			a.cookieName = cookie.Name
			a.cookieValue = cookie.Value
		}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message := strings.TrimSpace(string(data))
		if message == "" {
			message = resp.Status
		}
		return nil, fmt.Errorf("WebUI API %s: %s", resp.Status, message)
	}
	return data, nil
}

func (a *apiClient) login() error {
	form := url.Values{"username": {a.user}, "password": {a.pass}}
	body, err := a.request(http.MethodPost, "auth/login", strings.NewReader(form.Encode()), "application/x-www-form-urlencoded")
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(body)) != "Ok." && a.cookieValue == "" {
		return fmt.Errorf("WebUI rejected the username or password (HTTP %d, login response %q, cookies: %s)", a.status, strings.TrimSpace(string(body)), strings.Join(a.cookieNames, ","))
	}
	return nil
}

func (a *apiClient) get(path string) ([]byte, error) {
	return a.request(http.MethodGet, path, nil, "")
}

func (a *apiClient) post(path string, form url.Values) ([]byte, error) {
	return a.request(http.MethodPost, path, strings.NewReader(form.Encode()), "application/x-www-form-urlencoded")
}

func (a *apiClient) uploadProfile(form url.Values, profile []byte) error {
	form.Set("profile", string(profile))
	_, err := a.post("app/minttorrentVpnImport", form)
	return err
}

func (a *apiClient) uploadTorrent(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 64<<20 {
		return errors.New("torrent file must be a regular file between 1 byte and 64 MiB")
	}
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	part, err := w.CreateFormFile("torrents", filepath.Base(path))
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, file); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	_, err = a.request(http.MethodPost, "torrents/add", &body, w.FormDataContentType())
	return err
}

func (a *apiClient) addTorrent(source string) error {
	if strings.HasPrefix(source, "magnet:") {
		_, err := a.post("torrents/add", url.Values{"urls": {source}})
		return err
	}
	return a.uploadTorrent(source)
}

func printJSON(out io.Writer, data []byte) error {
	var value any
	if err := json.Unmarshal(data, &value); err != nil {
		return fmt.Errorf("invalid JSON from WebUI: %w", err)
	}
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(out, string(encoded))
	return err
}

func redacted(value any) any {
	switch object := value.(type) {
	case map[string]any:
		for key, child := range object {
			lower := strings.ToLower(key)
			if strings.Contains(lower, "password") || strings.Contains(lower, "secret") || strings.Contains(lower, "token") || strings.Contains(lower, "private_key") {
				object[key] = "[redacted]"
			} else {
				object[key] = redacted(child)
			}
		}
		return object
	case []any:
		for i := range object {
			object[i] = redacted(object[i])
		}
		return object
	default:
		return value
	}
}

func decodeJSONSettings(data []byte) (map[string]any, error) {
	settings := map[string]any{}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&settings); err != nil {
		return nil, err
	}
	return settings, nil
}

func readHiddenPassword() (string, error) {
	if password := os.Getenv("MINTTORRENT_WEBUI_PASSWORD"); password != "" {
		return password, nil
	}
	if info, err := os.Stdin.Stat(); err == nil && (info.Mode()&os.ModeCharDevice) == 0 {
		return "", errors.New("set MINTTORRENT_WEBUI_PASSWORD when stdin is not a terminal")
	}
	fmt.Fprint(os.Stderr, "WebUI password: ")
	password, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	return string(password), err
}

func run(args []string, out, errOut io.Writer) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprintln(out, `Usage:
  minttorrent vpn import PROFILE
  minttorrent vpn connect|disconnect|status
  minttorrent torrent add TORRENT_FILE|MAGNET
  minttorrent torrent list
  minttorrent config show

The WebUI URL defaults to http://127.0.0.1:4101. The username defaults to
admin. The password is read without terminal echo or from
MINTTORRENT_WEBUI_PASSWORD.`)
		return nil
	}
	if len(args) == 2 && args[0] == "vpn" && args[1] == "status" {
		return runAPI(args, out, errOut)
	}
	if len(args) == 3 && args[0] == "vpn" && args[1] == "import" {
		return runAPI(args, out, errOut)
	}
	if len(args) == 2 && args[0] == "vpn" && (args[1] == "connect" || args[1] == "disconnect") {
		return runAPI(args, out, errOut)
	}
	if len(args) == 3 && args[0] == "torrent" && args[1] == "add" {
		return runAPI(args, out, errOut)
	}
	if len(args) == 2 && args[0] == "torrent" && args[1] == "list" {
		return runAPI(args, out, errOut)
	}
	if len(args) == 2 && args[0] == "config" && args[1] == "show" {
		return runAPI(args, out, errOut)
	}
	if len(args) >= 5 && args[0] == "__launch" && args[4] == "--" {
		return launchQbittorrent(args[1], args[2], args[3], args[5:])
	}
	return fmt.Errorf("unknown or incomplete command; run 'minttorrent help'")
}

func runAPI(args []string, out, errOut io.Writer) error {
	base := os.Getenv("MINTTORRENT_WEBUI_URL")
	if base == "" {
		base = defaultBaseURL
	}
	username := os.Getenv("MINTTORRENT_WEBUI_USERNAME")
	if username == "" {
		username = "admin"
	}
	password, err := readHiddenPassword()
	if err != nil {
		return err
	}
	api, err := newAPIClient(base, username, password, nil)
	if err != nil {
		return err
	}
	if err := api.login(); err != nil {
		return err
	}

	switch {
	case args[0] == "vpn" && args[1] == "status":
		data, err := api.get("app/minttorrentVpnStatus")
		if err != nil {
			return err
		}
		return printJSON(out, data)
	case args[0] == "vpn" && args[1] == "connect":
		_, err := api.post("app/minttorrentVpnSet", url.Values{"enabled": {"true"}})
		if err == nil {
			fmt.Fprintln(out, "VPN enabled.")
		}
		return err
	case args[0] == "vpn" && args[1] == "disconnect":
		_, err := api.post("app/minttorrentVpnSet", url.Values{"enabled": {"false"}})
		if err == nil {
			fmt.Fprintln(out, "VPN disconnected.")
		}
		return err
	case args[0] == "vpn" && args[1] == "import":
		info, err := os.Stat(args[2])
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 128<<10 {
			return errors.New("profile must be a regular file between 1 byte and 128 KiB")
		}
		profile, err := os.ReadFile(args[2])
		if err != nil {
			return err
		}
		statusData, err := api.get("app/minttorrentVpnStatus")
		if err != nil {
			return err
		}
		settings, err := decodeJSONSettings(statusData)
		if err != nil {
			return fmt.Errorf("invalid VPN settings response: %w", err)
		}
		get := func(key string, fallback any) string {
			value, ok := settings[key]
			if !ok {
				value = fallback
			}
			return fmt.Sprint(value)
		}
		ipv4 := get("ipv4", true)
		ipv6 := get("ipv6", true)
		form := url.Values{
			"ipv4": {ipv4}, "ipv6": {ipv6}, "mtu": {get("mtu", 0)},
			"packet_queue":       {get("packet_queue", 1024)},
			"tcp_send_buffer":    {get("tcp_send_buffer", 1048576)},
			"tcp_receive_buffer": {get("tcp_receive_buffer", 1048576)},
		}
		if err := api.uploadProfile(form, profile); err != nil {
			return err
		}
		fmt.Fprintln(out, "VPN profile imported and enabled.")
		return nil
	case args[0] == "torrent" && args[1] == "add":
		if err := api.addTorrent(args[2]); err != nil {
			return err
		}
		fmt.Fprintln(out, "Torrent submitted to qBittorrent.")
		return nil
	case args[0] == "torrent" && args[1] == "list":
		data, err := api.get("torrents/info")
		if err != nil {
			return err
		}
		return printJSON(out, data)
	case args[0] == "config" && args[1] == "show":
		data, err := api.get("app/preferences")
		if err != nil {
			return err
		}
		var value any
		if err := json.Unmarshal(data, &value); err != nil {
			return err
		}
		configPath := os.Getenv("MINTTORRENT_CONFIG")
		if configPath == "" {
			configPath = filepath.Join(filepath.Dir(os.Args[0]), "..", "config", "config.toml")
		}
		profile := os.Getenv("MINTTORRENT_PROFILE")
		if profile == "" {
			configHome := os.Getenv("XDG_CONFIG_HOME")
			if configHome == "" {
				configHome = filepath.Join(os.Getenv("HOME"), ".config")
			}
			profile = filepath.Join(configHome, "MintTorrent", "qBittorrent")
		}
		runtime, err := readRuntimeConfig(configPath, profile)
		if err != nil {
			return err
		}
		result := map[string]any{
			"config_file": configPath,
			"runtime": map[string]any{
				"webui_port":         runtime.webUIPort,
				"listen_port":        runtime.listenPort,
				"listen_port_mode":   map[bool]string{true: "random 10000-65535 at each start", false: "fixed"}[runtime.listenPort == 0],
				"download_path":      runtime.downloadDir,
				"vpn_profile_source": runtime.vpnConfig,
				"vpn_autostart":      runtime.vpnAutostart,
			},
			"qbittorrent_preferences": redacted(value),
		}
		encoded, err := json.Marshal(result)
		if err != nil {
			return err
		}
		return printJSON(out, encoded)
	default:
		return fmt.Errorf("unknown or incomplete command; run 'minttorrent help'")
	}
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "minttorrent:", err)
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() >= 0 {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
}
