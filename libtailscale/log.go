package libtailscale

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"tailscale.com/health"
	"tailscale.com/logpolicy"
	"tailscale.com/logtail"
	"tailscale.com/logtail/filch"
	"tailscale.com/types/logger"
	"tailscale.com/types/logid"
	"tailscale.com/util/clientmetric"
)

var logTag = filepath.Base(os.Args[0])

func initLogging(appCtx AppContext) {
	log.SetFlags(log.Flags() &^ log.LstdFlags)
	log.SetOutput(&iosLogWriter{appCtx: appCtx})
}

type iosLogWriter struct {
	appCtx AppContext
}

func (w *iosLogWriter) Write(data []byte) (int, error) {
	w.appCtx.Log(logTag, string(data))
	return len(data), nil
}

func (b *backend) setupLogs(logDir string, logID logid.PrivateID, logf logger.Logf, health *health.Tracker) {
	if b.netMon == nil {
		panic("netMon must be created prior to setupLogs")
	}
	transport := logpolicy.NewLogtailTransport(logtail.DefaultHost, b.netMon, health, log.Printf)

	logcfg := logtail.Config{
		Collection:          logtail.CollectionNode,
		PrivateID:           logID,
		Stderr:              log.Writer(),
		MetricsDelta:        clientmetric.EncodeLogTailMetricsDelta,
		IncludeProcID:       true,
		IncludeProcSequence: true,
		HTTPC:               &http.Client{Transport: transport},
		CompressLogs:        true,
	}
	logcfg.FlushDelayFn = func() time.Duration { return 2 * time.Minute }

	filchErr := b.configureLogBuffer(&logcfg, logDir)
	b.logger = logtail.NewLogger(logcfg, logf)

	log.SetFlags(0)
	log.SetOutput(b.logger)

	log.Printf("setupLogs: success")

	if logDir == "" {
		log.Printf("setupLogs: no logDir, storing logs in memory")
	}
	if filchErr != nil {
		log.Printf("setupLogs: filch setup failed: %v", filchErr)
	}
}

func (b *backend) configureLogBuffer(config *logtail.Config, logDir string) error {
	if logDir == "" {
		return nil
	}
	buffer, err := filch.New(filepath.Join(logDir, "ipn.log."), filch.Options{
		// This backend shares its process with Swift/NetworkExtension (and
		// XCTest). OSLog can echo logtail output to stderr; capturing fd 2
		// feeds that output back into filch and swallows host diagnostics.
		// Explicit logtail writes still use the persistent buffer below.
		ReplaceStderr: false,
	})
	if err != nil {
		// A typed nil *Filch in the Buffer interface bypasses logtail's
		// in-memory fallback and panics on the next log write.
		return err
	}
	config.Buffer = buffer
	b.logBuffer = buffer
	return nil
}
