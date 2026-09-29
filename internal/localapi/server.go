// Package localapi exposes a loopback HTTP endpoint that a browser extension
// (or any local helper) posts download requests to, so downloads started in a
// browser are handed to cascade automatically without copy/paste.
//
// Security model: binds to 127.0.0.1 only; /add requires a shared token; and
// requests carrying a web Origin are rejected (only browser-extension origins
// or origin-less local clients are accepted), so a random web page cannot
// enqueue downloads or trigger pairing. Native messaging is a more locked-down
// alternative (no open port); this design is chosen for cross-browser
// uniformity and one-click setup.
package localapi

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"cascade/internal/download"
	"cascade/internal/job"
)

// DefaultPort is the loopback port the extension targets first.
const DefaultPort = 8760

// Server accepts download requests over loopback and enqueues them.
type Server struct {
	mgr        *job.Manager
	token      string
	defaultDir string
	httpSrv    *http.Server
	addr       string

	// PairFunc, when set, is called on GET /pair to ask the user whether a
	// browser extension may connect. It should block until the user decides (or
	// a timeout) and return true to release the token. nil disables pairing.
	PairFunc func() bool

	// ResolveDir, when set, picks the destination folder for a hand-off that
	// doesn't specify one (category / per-site rules); else defaultDir.
	ResolveDir func(rawURL, filename string) string

	mu       sync.Mutex
	lastExt  time.Time // last contact from a browser extension (heartbeat)
	pairBusy bool      // a pairing prompt is already showing
}

// New builds a Server. token guards /add; defaultDir is where files land when a
// request doesn't specify a directory.
func New(mgr *job.Manager, token, defaultDir string) *Server {
	return &Server{mgr: mgr, token: token, defaultDir: defaultDir}
}

// Addr returns the listening address (valid after Start).
func (s *Server) Addr() string { return s.addr }

// LastExtensionContact returns when a browser extension last checked in (zero
// if never). The app shows this as a "connected" indicator.
func (s *Server) LastExtensionContact() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastExt
}

// Start binds 127.0.0.1 (DefaultPort, then two fallbacks the extension also
// probes) and serves in the background. It returns the chosen address.
func (s *Server) Start() (string, error) {
	var ln net.Listener
	var err error
	for _, p := range []int{DefaultPort, DefaultPort + 1, DefaultPort + 2} {
		ln, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err == nil {
			break
		}
	}
	if err != nil {
		return "", err
	}
	s.addr = ln.Addr().String()

	mux := http.NewServeMux()
	mux.HandleFunc("/ping", s.handlePing)
	mux.HandleFunc("/pair", s.handlePair)
	mux.HandleFunc("/add", s.handleAdd)
	mux.HandleFunc("/jobs", s.handleJobs)

	s.httpSrv = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = s.httpSrv.Serve(ln) }()
	return s.addr, nil
}

// Close stops the server.
func (s *Server) Close() error {
	if s.httpSrv != nil {
		return s.httpSrv.Close()
	}
	return nil
}

func cors(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Cascade-Token, X-Cascade-Client")
	// Chrome Private Network Access: a browser-context fetch to loopback is
	// preflighted and requires this header.
	w.Header().Set("Access-Control-Allow-Private-Network", "true")
}

// originOK accepts origin-less local clients (curl, native helpers) and browser
// extension origins, and rejects any web page origin.
func originOK(r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		return true
	}
	return strings.HasPrefix(o, "chrome-extension://") ||
		strings.HasPrefix(o, "moz-extension://") ||
		strings.HasPrefix(o, "safari-web-extension://")
}

func (s *Server) noteExtension(r *http.Request) {
	if r.Header.Get("X-Cascade-Client") == "extension" || r.URL.Query().Get("client") == "extension" {
		s.mu.Lock()
		s.lastExt = time.Now()
		s.mu.Unlock()
	}
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	s.noteExtension(r)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "app": "cascade"})
}

// handlePair lets a browser extension obtain the token after the user approves
// in the app window. Only extension origins may ask; web pages are rejected.
func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	if !originOK(r) {
		http.Error(w, "forbidden origin", http.StatusForbidden)
		return
	}
	if s.PairFunc == nil {
		http.Error(w, "pairing unavailable", http.StatusNotFound)
		return
	}
	s.mu.Lock()
	if s.pairBusy {
		s.mu.Unlock()
		http.Error(w, "pairing already in progress", http.StatusConflict)
		return
	}
	s.pairBusy = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.pairBusy = false
		s.mu.Unlock()
	}()

	s.noteExtension(r)
	if !s.PairFunc() {
		http.Error(w, "pairing declined", http.StatusForbidden)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": s.token})
}

type addRequest struct {
	URL       string            `json:"url"`
	Filename  string            `json:"filename"`
	Dir       string            `json:"dir"`
	Cookie    string            `json:"cookie"`
	Referrer  string            `json:"referrer"`
	UserAgent string            `json:"userAgent"`
	Headers   map[string]string `json:"headers"`
}

// probeTimeout bounds the fetchability check done before accepting a hand-off.
const probeTimeout = 12 * time.Second

func (s *Server) handleAdd(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if !originOK(r) {
		http.Error(w, "forbidden origin", http.StatusForbidden)
		return
	}
	if !s.authOK(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.noteExtension(r)

	var req addRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if req.URL == "" {
		http.Error(w, "url required", http.StatusBadRequest)
		return
	}
	if _, err := url.ParseRequestURI(req.URL); err != nil {
		http.Error(w, "invalid url", http.StatusBadRequest)
		return
	}

	headers := map[string]string{}
	for k, v := range req.Headers {
		headers[k] = v
	}
	if req.Referrer != "" {
		headers["Referer"] = req.Referrer
	}
	if req.UserAgent != "" {
		headers["User-Agent"] = req.UserAgent
	}
	opts := download.Options{Headers: headers, Cookie: req.Cookie, Resume: true}

	// Verify the URL is fetchable with these credentials BEFORE accepting, so a
	// session-bound or POST-only link (403 to a plain GET) is refused here and
	// the extension leaves the browser's own download running. Otherwise the
	// browser copy would be cancelled and the app would fail: the user gets
	// nothing.
	pctx, cancel := context.WithTimeout(r.Context(), probeTimeout)
	defer cancel()
	if err := download.CheckFetchable(pctx, req.URL, opts); err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error": "not fetchable by the app: " + err.Error(),
		})
		return
	}

	name := req.Filename
	if name == "" {
		name = filenameFor(req.URL)
	}
	dir := req.Dir
	if dir == "" {
		if s.ResolveDir != nil {
			dir = s.ResolveDir(req.URL, name)
		} else {
			dir = s.defaultDir
		}
	}
	out := filepath.Join(dir, name)

	// Dedupe: if a download to this exact path is already queued or running
	// (e.g. the user re-clicks the link, or an orphan was auto-resumed), reuse it
	// instead of starting a second job that would write the same file.
	for _, st := range s.mgr.Statuses() {
		if st.Out == out && !st.State.Terminal() {
			writeJSON(w, http.StatusOK, map[string]any{"id": st.ID, "existing": true})
			return
		}
	}

	id, err := s.mgr.Add(job.Spec{URL: req.URL, Out: out, Options: opts})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id})
}

type jobJSON struct {
	ID      string `json:"id"`
	URL     string `json:"url"`
	Out     string `json:"out"`
	State   string `json:"state"`
	Bytes   int64  `json:"bytes"`
	Total   int64  `json:"total"`
	Retries int    `json:"retries"`
	Error   string `json:"error,omitempty"`
}

// handleJobs returns the queue with per-job state and last error (token-guarded),
// so failures are visible to the extension's Options page and to diagnostics.
func (s *Server) handleJobs(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	if !originOK(r) {
		http.Error(w, "forbidden origin", http.StatusForbidden)
		return
	}
	if !s.authOK(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	s.noteExtension(r)
	sts := s.mgr.Statuses()
	out := make([]jobJSON, 0, len(sts))
	for _, st := range sts {
		j := jobJSON{ID: st.ID, URL: st.URL, Out: st.Out, State: st.State.String(),
			Bytes: st.Bytes, Total: st.Total, Retries: st.Retries}
		if st.Err != nil {
			j.Error = st.Err.Error()
		}
		out = append(out, j)
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) authOK(r *http.Request) bool {
	got := r.Header.Get("X-Cascade-Token")
	if got == "" {
		got = r.URL.Query().Get("token")
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) == 1
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func filenameFor(rawURL string) string {
	if u, err := url.Parse(rawURL); err == nil {
		if base := path.Base(u.Path); base != "" && base != "/" && base != "." {
			return base
		}
	}
	return "download.bin"
}
