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

	filchOpts := filch.Options{
		ReplaceStderr: true,
	}

	var filchErr error
	if logDir != "" {
		logPath := filepath.Join(logDir, "ipn.log.")
		logcfg.Buffer, filchErr = filch.New(logPath, filchOpts)
	}

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
