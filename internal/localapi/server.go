// Package localapi exposes a loopback HTTP endpoint that a browser extension
// (or any local helper) posts download requests to, so downloads started in a
// browser are handed to cascade automatically without copy/paste.
//
// It binds to 127.0.0.1 only and requires a shared token, so a random web page
// cannot silently enqueue downloads. Native messaging is a more locked-down
// alternative (no open port); this loopback+token design is chosen for
// cross-browser uniformity and simple setup.
package localapi

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
	"path/filepath"
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
}

// New builds a Server. token guards /add; defaultDir is where files land when a
// request doesn't specify a directory.
func New(mgr *job.Manager, token, defaultDir string) *Server {
	return &Server{mgr: mgr, token: token, defaultDir: defaultDir}
}

// Addr returns the listening address (valid after Start).
func (s *Server) Addr() string { return s.addr }

// Start binds 127.0.0.1 (DefaultPort, then a few fallbacks) and serves in the
// background. It returns the chosen address.
func (s *Server) Start() (string, error) {
	var ln net.Listener
	var err error
	for _, p := range []int{DefaultPort, DefaultPort + 1, DefaultPort + 2, 0} {
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
	mux.HandleFunc("/add", s.handleAdd)

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
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Cascade-Token")
	// Chrome Private Network Access: a fetch from a browser context to a
	// loopback address is preflighted and requires this header, or the request
	// (including the extension's) is blocked.
	w.Header().Set("Access-Control-Allow-Private-Network", "true")
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "app": "cascade"})
}

type addRequest struct {
	URL      string            `json:"url"`
	Filename string            `json:"filename"`
	Dir      string            `json:"dir"`
	Cookie   string            `json:"cookie"`
	Referrer string            `json:"referrer"`
	Headers  map[string]string `json:"headers"`
}

func (s *Server) handleAdd(w http.ResponseWriter, r *http.Request) {
	cors(w)
	if r.Method == http.MethodOptions {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if !s.authOK(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
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
	dir := req.Dir
	if dir == "" {
		dir = s.defaultDir
	}
	name := req.Filename
	if name == "" {
		name = filenameFor(req.URL)
	}

	id, err := s.mgr.Add(job.Spec{
		URL: req.URL,
		Out: filepath.Join(dir, name),
		Options: download.Options{
			Headers: headers,
			Cookie:  req.Cookie,
		},
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id})
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
