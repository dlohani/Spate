// Package httpc builds the shared HTTP client used for all transfers.
//
// The transport is tuned for many parallel byte-range connections to a single
// host. Note: this maximizes use of the bandwidth the link already provides and
// defeats per-connection/server-side throttling. It does not, and is not meant
// to, evade an ISP's aggregate rate shaping or data cap.
package httpc

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
)

// Config tunes the shared client.
type Config struct {
	MaxConns int    // parallel connections to one host
	Proxy    string // explicit proxy URL (http/https/socks5); "" uses env
	Insecure bool   // skip TLS certificate verification
}

// New returns an *http.Client tuned for segmented downloads. An explicit proxy
// URL (which may include user:pass credentials) overrides the environment; an
// empty proxy falls back to HTTP(S)_PROXY.
func New(cfg Config) (*http.Client, error) {
	maxConns := cfg.MaxConns
	if maxConns < 1 {
		maxConns = 1
	}
	proxyFn := http.ProxyFromEnvironment
	if cfg.Proxy != "" {
		pu, err := url.Parse(cfg.Proxy)
		if err != nil {
			return nil, fmt.Errorf("invalid proxy URL %q: %w", cfg.Proxy, err)
		}
		proxyFn = http.ProxyURL(pu)
	}
	t := &http.Transport{
		Proxy: proxyFn,
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
	if cfg.Insecure {
		t.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // opt-in via -insecure
	}
	return &http.Client{
		Transport: t,
		// No whole-request timeout: downloads are long-lived. Cancellation is
		// driven by context instead.
		Timeout: 0,
	}, nil
}
