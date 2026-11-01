package main

import (
	"bufio"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

type runtimeConfig struct {
	webUIPort    int
	listenPort   int
	downloadDir  string
	vpnConfig    string
	vpnAutostart bool
}

func readRuntimeConfig(path, profile string) (runtimeConfig, error) {
	cfg := runtimeConfig{webUIPort: 4101, listenPort: 0}
	if path == "" {
		return cfg, errors.New("runtime config path is empty")
	}
	f, err := os.Open(path)
	if err != nil {
		return cfg, fmt.Errorf("open config %q: %w", path, err)
	}
	defer f.Close()

	section := ""
	values := map[string]string{}
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 4096), 1<<20)
	lineNo := 0
	for s.Scan() {
		lineNo++
		line := strings.TrimSpace(stripTOMLComment(s.Text()))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(line[1 : len(line)-1])
			if section == "" || strings.ContainsAny(section, "[]") {
				return cfg, fmt.Errorf("config %s:%d: invalid section header", path, lineNo)
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(key) == "" {
			return cfg, fmt.Errorf("config %s:%d: expected key = value", path, lineNo)
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if strings.HasPrefix(value, "\"") {
			value, err = strconv.Unquote(value)
			if err != nil {
				return cfg, fmt.Errorf("config %s:%d: invalid quoted string: %w", path, lineNo, err)
			}
		}
		values[section+"."+key] = value
	}
	if err := s.Err(); err != nil {
		return cfg, fmt.Errorf("read config %q: %w", path, err)
	}
	for key := range values {
		switch key {
		case "torrent.webui_port", "torrent.listen_port", "torrent.storage.download_path", "vpn.config", "vpn.autostart":
		default:
			return cfg, fmt.Errorf("config %s: unsupported setting %q; remove it or use the WebUI for qBittorrent settings", path, key)
		}
	}

	parsePort := func(key string, fallback, min int) (int, error) {
		value, found := values[key]
		if !found {
			return fallback, nil
		}
		port, err := strconv.Atoi(value)
		if err != nil || port < min || port > 65535 {
			return 0, fmt.Errorf("config %s: %s must be between %d and 65535", path, key, min)
		}
		return port, nil
	}
	if cfg.webUIPort, err = parsePort("torrent.webui_port", cfg.webUIPort, 1); err != nil {
		return cfg, err
	}
	if cfg.listenPort, err = parsePort("torrent.listen_port", cfg.listenPort, 0); err != nil {
		return cfg, err
	}
	if value, found := values["vpn.autostart"]; found {
		cfg.vpnAutostart, err = strconv.ParseBool(value)
		if err != nil {
			return cfg, fmt.Errorf("config %s: vpn.autostart must be true or false", path)
		}
	}
	baseDir, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return cfg, err
	}
	if value, found := values["torrent.storage.download_path"]; found && value != "" {
		cfg.downloadDir = value
		if !filepath.IsAbs(cfg.downloadDir) {
			cfg.downloadDir = filepath.Join(baseDir, cfg.downloadDir)
		}
	} else {
		cfg.downloadDir = filepath.Join(profile, "downloads")
	}
	if !filepath.IsAbs(cfg.downloadDir) {
		cfg.downloadDir, err = filepath.Abs(cfg.downloadDir)
		if err != nil {
			return cfg, err
		}
	}
	cfg.downloadDir = filepath.Clean(cfg.downloadDir)

	vpnPath := values["vpn.config"]
	if vpnPath == "" {
		return cfg, fmt.Errorf("config %s: [vpn] config must name the VPN profile source", path)
	}
	if !filepath.IsAbs(vpnPath) {
		vpnPath = filepath.Join(baseDir, vpnPath)
	}
	cfg.vpnConfig, err = filepath.Abs(vpnPath)
	if err != nil {
		return cfg, err
	}
	if st, statErr := os.Stat(cfg.vpnConfig); statErr != nil || !st.Mode().IsRegular() {
		if statErr == nil {
			statErr = errors.New("not a regular file")
		}
		return cfg, fmt.Errorf("config %s: VPN profile %q: %w", path, cfg.vpnConfig, statErr)
	}
	return cfg, nil
}

func stripTOMLComment(line string) string {
	quoted, escaped := false, false
	for i, r := range line {
		if escaped {
			escaped = false
			continue
		}
		if quoted && r == '\\' {
			escaped = true
			continue
		}
		if r == '"' {
			quoted = !quoted
			continue
		}
		if r == '#' && !quoted {
			return line[:i]
		}
	}
	return line
}

func launchQbittorrent(binary, profile, configPath string, qbtArgs []string) error {
	profile, err := filepath.Abs(profile)
	if err != nil {
		return err
	}
	configPath, err = filepath.Abs(configPath)
	if err != nil {
		return err
	}
	cfg, err := readRuntimeConfig(configPath, profile)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(profile, 0o700); err != nil {
		return fmt.Errorf("create qBittorrent profile: %w", err)
	}
	if err = os.MkdirAll(cfg.downloadDir, 0o750); err != nil {
		return fmt.Errorf("create download directory %q: %w", cfg.downloadDir, err)
	}
	if err = os.Setenv("MINTTORRENT_DOWNLOAD_DIR", cfg.downloadDir); err != nil {
		return err
	}
	if err = os.Setenv("MINTTORRENT_VPN_CONFIG", cfg.vpnConfig); err != nil {
		return err
	}
	if err = os.Setenv("MINTTORRENT_VPN_AUTOSTART", strconv.FormatBool(cfg.vpnAutostart)); err != nil {
		return err
	}
	argv := []string{binary, "--confirm-legal-notice", "--profile=" + profile,
		fmt.Sprintf("--webui-port=%d", cfg.webUIPort)}
	listenPort := cfg.listenPort
	if listenPort == 0 {
		value, randErr := rand.Int(rand.Reader, big.NewInt(65535-10000+1))
		if randErr != nil {
			return fmt.Errorf("choose torrent listen port: %w", randErr)
		}
		listenPort = int(value.Int64()) + 10000
	}
	argv = append(argv, fmt.Sprintf("--torrenting-port=%d", listenPort))
	argv = append(argv, qbtArgs...)
	fmt.Fprintf(os.Stderr, "INFO MintTorrent config=%s webui_port=%d download_path=%s VPN_autostart=%t\n", configPath, cfg.webUIPort, cfg.downloadDir, cfg.vpnAutostart)
	fmt.Fprintf(os.Stderr, "INFO Selected BitTorrent listen port for this service run port=%d\n", listenPort)
	cmd := exec.Command(binary, argv[1:]...)
	cmd.Env = os.Environ()
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run qBittorrent: %w", err)
	}
	return nil
}
