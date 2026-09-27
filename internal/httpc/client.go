// Package httpc builds the shared HTTP client used for all transfers.
//
// The transport is tuned for many parallel byte-range connections to a single
// host. Note: this maximizes use of the bandwidth the link already provides and
// defeats per-connection/server-side throttling. It does not, and is not meant
// to, evade an ISP's aggregate rate shaping or data cap.
package httpc

import (
	"net"
	"net/http"
	"time"
)

// New returns an *http.Client tuned for segmented downloads with up to
// maxConns simultaneous connections to one host.
func New(maxConns int) *http.Client {
	if maxConns < 1 {
		maxConns = 1
	}
	t := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   15 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2: true,
		// Allow many idle connections to the same host so segment workers reuse
		// sockets instead of re-dialing.
		MaxIdleConns:          maxConns * 2,
		MaxIdleConnsPerHost:   maxConns * 2,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		// Keep Content-Length and Range byte counts exact: a compressed body
		// would report transfer-encoded sizes that don't line up with offsets.
		DisableCompression: true,
	}
	return &http.Client{
		Transport: t,
		// No whole-request timeout: downloads are long-lived. Cancellation is
		// driven by context instead.
		Timeout: 0,
	}
}
