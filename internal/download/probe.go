package download

import (
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

// ProbeResult describes what the server will let us do with a URL.
type ProbeResult struct {
	FinalURL     string // URL after following redirects
	Size         int64  // total bytes; -1 if unknown
	AcceptRanges bool   // server honors byte-range requests
	ETag         string // strong/weak validator, if any
	LastModified string // fallback validator, if any
	Filename     string // suggested name from Content-Disposition, if any
	ContentType  string // Content-Type, used to infer a file extension
}

// Validator returns the value to send in If-Range on resume, preferring ETag.
func (p ProbeResult) Validator() string {
	if p.ETag != "" {
		return p.ETag
	}
	return p.LastModified
}

// Probe inspects url with a HEAD request, falling back to a single-byte ranged
// GET when HEAD is unhelpful (some servers don't implement HEAD, or omit
// Accept-Ranges on it).
func Probe(ctx context.Context, client *http.Client, rc requestConfig, url string) (ProbeResult, error) {
	res, err := probeHEAD(ctx, client, rc, url)
	if err == nil && res.Size >= 0 && res.AcceptRanges {
		return res, nil
	}
	// HEAD was missing range info or size; confirm with a 1-byte range GET.
	gres, gerr := probeRangeGET(ctx, client, rc, url)
	if gerr != nil {
		if err != nil {
			return ProbeResult{}, fmt.Errorf("probe failed: HEAD: %v; ranged GET: %w", err, gerr)
		}
		// HEAD worked but had no range/size; return what we learned.
		return res, nil
	}
	return gres, nil
}

func probeHEAD(ctx context.Context, client *http.Client, rc requestConfig, url string) (ProbeResult, error) {
	req, err := rc.newRequest(ctx, http.MethodHead, url)
	if err != nil {
		return ProbeResult{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return ProbeResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ProbeResult{}, fmt.Errorf("HEAD %s: unexpected status %s", url, resp.Status)
	}
	r := ProbeResult{
		FinalURL:     resp.Request.URL.String(),
		Size:         resp.ContentLength, // -1 when unknown
		AcceptRanges: strings.EqualFold(resp.Header.Get("Accept-Ranges"), "bytes"),
		ETag:         resp.Header.Get("ETag"),
		LastModified: resp.Header.Get("Last-Modified"),
		Filename:     filenameFromDisposition(resp.Header.Get("Content-Disposition")),
		ContentType:  resp.Header.Get("Content-Type"),
	}
	return r, nil
}

func probeRangeGET(ctx context.Context, client *http.Client, rc requestConfig, url string) (ProbeResult, error) {
	req, err := rc.newRequest(ctx, http.MethodGet, url)
	if err != nil {
		return ProbeResult{}, err
	}
	req.Header.Set("Range", "bytes=0-0")
	resp, err := client.Do(req)
	if err != nil {
		return ProbeResult{}, err
	}
	defer resp.Body.Close()
	// Drain the (tiny) body so the connection can be reused.
	drain(resp)

	r := ProbeResult{
		FinalURL:     resp.Request.URL.String(),
		Size:         -1,
		ETag:         resp.Header.Get("ETag"),
		LastModified: resp.Header.Get("Last-Modified"),
		Filename:     filenameFromDisposition(resp.Header.Get("Content-Disposition")),
		ContentType:  resp.Header.Get("Content-Type"),
	}
	switch resp.StatusCode {
	case http.StatusPartialContent: // 206: ranges honored
		r.AcceptRanges = true
		if total := totalFromContentRange(resp.Header.Get("Content-Range")); total >= 0 {
			r.Size = total
		}
	case http.StatusOK: // 200: server ignored Range, no range support
		r.AcceptRanges = false
		r.Size = resp.ContentLength
	default:
		return ProbeResult{}, fmt.Errorf("ranged GET %s: unexpected status %s", url, resp.Status)
	}
	return r, nil
}

// totalFromContentRange parses the total size out of "bytes 0-0/12345".
// Returns -1 when the total is unknown ("*") or unparseable.
func totalFromContentRange(v string) int64 {
	i := strings.LastIndex(v, "/")
	if i < 0 {
		return -1
	}
	tail := strings.TrimSpace(v[i+1:])
	if tail == "" || tail == "*" {
		return -1
	}
	n, err := strconv.ParseInt(tail, 10, 64)
	if err != nil {
		return -1
	}
	return n
}

func filenameFromDisposition(v string) string {
	if v == "" {
		return ""
	}
	for _, part := range strings.Split(v, ";") {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(strings.ToLower(part), "filename=") {
			name := strings.Trim(part[len("filename="):], `"`)
			// Guard against path traversal in a server-supplied name.
			if i := strings.LastIndexAny(name, `/\`); i >= 0 {
				name = name[i+1:]
			}
			return name
		}
	}
	return ""
}
