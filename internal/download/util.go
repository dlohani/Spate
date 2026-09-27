package download

import (
	"io"
	"net/http"
)

// chunkSize is the read buffer size for streaming a segment body.
const chunkSize = 64 * 1024

// drain reads and discards up to a small bound of a response body so the
// underlying connection can be returned to the pool for reuse.
func drain(resp *http.Response) {
	if resp == nil || resp.Body == nil {
		return
	}
	_, _ = io.CopyN(io.Discard, resp.Body, 4096)
	_ = resp.Body.Close()
}
