package libtailscale

import (
	"os"
	"path/filepath"
	"testing"

	"tailscale.com/logtail"
)

func TestLogBufferFailureLeavesMemoryFallbackAvailable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(path, []byte("file"), 0600); err != nil { t.Fatal(err) }
	b := &backend{}
	var cfg logtail.Config
	if err := b.configureLogBuffer(&cfg, path); err == nil { t.Fatal("expected filesystem error") }
	if cfg.Buffer != nil || b.logBuffer != nil {
		t.Fatal("failed buffer must be nil, not a typed nil that panics in logtail")
	}
}

func TestBackendCleanupClosesPersistentLogBuffer(t *testing.T) {
	b := &backend{}
	var cfg logtail.Config
	if err := b.configureLogBuffer(&cfg, t.TempDir()); err != nil { t.Fatal(err) }
	if _, err := cfg.Buffer.Write([]byte("persisted\n")); err != nil { t.Fatal(err) }
	(&App{}).closeBackendState(b)
	if _, err := cfg.Buffer.Write([]byte("after shutdown\n")); err == nil {
		t.Fatal("backend cleanup left the log file handles open")
	}
}
