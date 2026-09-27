package download

import (
	"context"
	"net/http"
)

// requestConfig carries per-request customization applied to every HTTP request
// the engine makes (probe and segment fetches): custom headers, a Cookie header,
// and HTTP Basic auth.
type requestConfig struct {
	header http.Header
	user   string
	pass   string
}

// newRequestConfig builds a requestConfig from Options.
func newRequestConfig(o Options) requestConfig {
	h := http.Header{}
	for k, v := range o.Headers {
		h.Set(k, v)
	}
	if o.Cookie != "" {
		h.Set("Cookie", o.Cookie)
	}
	return requestConfig{header: h, user: o.BasicUser, pass: o.BasicPassword}
}

// newRequest builds a request with the config's headers and auth applied.
func (rc requestConfig) newRequest(ctx context.Context, method, url string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return nil, err
	}
	for k, vals := range rc.header {
		for _, v := range vals {
			req.Header.Set(k, v)
		}
	}
	if rc.user != "" || rc.pass != "" {
		req.SetBasicAuth(rc.user, rc.pass)
	}
	return req, nil
}
