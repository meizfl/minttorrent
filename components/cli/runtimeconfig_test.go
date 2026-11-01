package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadRuntimeConfigUsesFilePathsAndValues(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "vpn"), 0o700); err != nil {
		t.Fatal(err)
	}
	vpn := filepath.Join(dir, "vpn", "warp.conf")
	if err := os.WriteFile(vpn, []byte("[Interface]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(dir, "config.toml")
	contents := "[vpn]\nconfig = \"vpn/warp.conf\" # operator profile\nautostart = true\n[torrent]\nwebui_port = 4102\nlisten_port = 51413\n[torrent.storage]\ndownload_path = \"data with spaces/downloads\"\n"
	if err := os.WriteFile(config, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readRuntimeConfig(config, filepath.Join(dir, "profile"))
	if err != nil {
		t.Fatal(err)
	}
	if got.webUIPort != 4102 || got.listenPort != 51413 || !got.vpnAutostart {
		t.Fatalf("unexpected runtime values: %+v", got)
	}
	if got.downloadDir != filepath.Join(dir, "data with spaces", "downloads") || got.vpnConfig != vpn {
		t.Fatalf("relative paths were not resolved from config file: %+v", got)
	}
}

func TestReadRuntimeConfigDefaultsAndRejectsUnsupportedOptions(t *testing.T) {
	dir := t.TempDir()
	vpn := filepath.Join(dir, "vpn.conf")
	if err := os.WriteFile(vpn, []byte("[Interface]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(dir, "config.toml")
	if err := os.WriteFile(config, []byte("[vpn]\nconfig=\"vpn.conf\"\n[torrent]\nwebui_port=4101\nlisten_port=0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := readRuntimeConfig(config, filepath.Join(dir, "profile"))
	if err != nil {
		t.Fatal(err)
	}
	if got.listenPort != 0 || got.downloadDir != filepath.Join(dir, "profile", "downloads") || got.vpnAutostart {
		t.Fatalf("unexpected defaults: %+v", got)
	}
	if err := os.WriteFile(config, []byte("[vpn]\nconfig=\"vpn.conf\"\n[torrent]\nwebui_port=4101\nlisten_port=0\n[torrent.storage]\ndownload_path=\"\"\n[network]\nstack=\"auto\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err = readRuntimeConfig(config, filepath.Join(dir, "profile")); err == nil || !strings.Contains(err.Error(), "unsupported setting") {
		t.Fatalf("unsupported setting was silently accepted: %v", err)
	}
}
