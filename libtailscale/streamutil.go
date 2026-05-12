package libtailscale

import (
	"io"
	"log"
)

// adaptInputStream wraps an InputStream into an io.ReadCloser.
func adaptInputStream(in InputStream) io.ReadCloser {
	if in == nil {
		return nil
	}
	r, w := io.Pipe()
	go func() {
		defer w.Close()
		for {
			b, err := in.Read()
			if err != nil {
				log.Printf("error reading from inputstream: %v", err)
				return
			}
			if b == nil {
				return
			}
			if _, err := w.Write(b); err != nil {
				log.Printf("error writing to pipe: %v", err)
				return
			}
		}
	}()
	return r
}
