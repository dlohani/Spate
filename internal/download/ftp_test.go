package download

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// ftpTestServer is a tiny passive-mode FTP server: USER/PASS, TYPE, SIZE,
// MDTM, REST, EPSV, RETR, QUIT. It records REST offsets so tests can prove
// segmented fetching, and can pretend not to support REST.
type ftpTestServer struct {
	ln      net.Listener
	data    []byte
	noREST  bool
	mu      sync.Mutex
	offsets []int64
	logins  int
}

func newFTPTestServer(t *testing.T, data []byte, noREST bool) *ftpTestServer {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &ftpTestServer{ln: ln, data: data, noREST: noREST}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.serve(c)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return s
}

func (s *ftpTestServer) url(path string) string {
	return "ftp://user:secret@" + s.ln.Addr().String() + path
}

func (s *ftpTestServer) serve(c net.Conn) {
	defer c.Close()
	r := bufio.NewReader(c)
	reply := func(code int, msg string) { fmt.Fprintf(c, "%d %s\r\n", code, msg) }
	reply(220, "test ftp")
	var rest int64
	var dataLn net.Listener
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		cmd, arg, _ := strings.Cut(strings.TrimRight(line, "\r\n"), " ")
		switch strings.ToUpper(cmd) {
		case "USER":
			reply(331, "password")
		case "PASS":
			if arg != "secret" {
				reply(530, "bad password")
				return
			}
			s.mu.Lock()
			s.logins++
			s.mu.Unlock()
			reply(230, "ok")
		case "TYPE":
			reply(200, "binary")
		case "SIZE":
			if arg != "/pub/blob.bin" {
				reply(550, "no such file")
				continue
			}
			reply(213, strconv.Itoa(len(s.data)))
		case "MDTM":
			reply(213, "20260101120000")
		case "REST":
			if s.noREST {
				reply(502, "not implemented")
				continue
			}
			rest, _ = strconv.ParseInt(arg, 10, 64)
			reply(350, "restarting")
		case "EPSV":
			dataLn, _ = net.Listen("tcp", "127.0.0.1:0")
			reply(229, fmt.Sprintf("Entering Extended Passive Mode (|||%d|)", dataLn.Addr().(*net.TCPAddr).Port))
		case "RETR":
			if dataLn == nil {
				reply(425, "use EPSV first")
				continue
			}
			s.mu.Lock()
			s.offsets = append(s.offsets, rest)
			s.mu.Unlock()
			reply(150, "sending")
			dc, err := dataLn.Accept()
			dataLn.Close()
			dataLn = nil
			if err != nil {
				reply(426, "data connection failed")
				continue
			}
			_, _ = dc.Write(s.data[rest:])
			dc.Close()
			rest = 0
			reply(226, "done")
		case "QUIT":
			reply(221, "bye")
			return
		default:
			reply(502, "not implemented")
		}
	}
}

func TestFTPProbeAndSegmentedDownload(t *testing.T) {
	data := make([]byte, 1<<20)
	for i := range data {
		data[i] = byte(i*7 + i>>8)
	}
	srv := newFTPTestServer(t, data, false)

	probe, err := Probe(context.Background(), nil, newRequestConfig(Options{}), srv.url("/pub/blob.bin"))
	if err != nil {
		t.Fatalf("Probe: %v", err)
	}
	if probe.Size != int64(len(data)) || !probe.AcceptRanges || probe.LastModified != "20260101120000" {
		t.Fatalf("probe = %+v", probe)
	}
	if _, err := Probe(context.Background(), nil, newRequestConfig(Options{}), srv.url("/pub/missing.bin")); err == nil {
		t.Fatal("probe of a missing file should fail")
	}

	out := filepath.Join(t.TempDir(), "blob.bin")
	d := New(srv.url("/pub/blob.bin"), out, Options{Conns: 3, MinSegment: 128 << 10, WindowSize: 128 << 10, SHA256: sha256hex(data)})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(out)
	if len(got) != len(data) {
		t.Fatalf("size = %d, want %d", len(got), len(data))
	}
	srv.mu.Lock()
	defer srv.mu.Unlock()
	distinct := map[int64]bool{}
	for _, o := range srv.offsets {
		distinct[o] = true
	}
	if len(distinct) < 3 {
		t.Fatalf("expected several REST offsets (segmented fetch), got %v", srv.offsets)
	}
	if srv.logins < 3 {
		t.Fatalf("expected one session per connection, got %d logins", srv.logins)
	}
}

func TestFTPWithoutRESTStreamsWhole(t *testing.T) {
	data := make([]byte, 300<<10)
	for i := range data {
		data[i] = byte(i % 251)
	}
	srv := newFTPTestServer(t, data, true)
	out := filepath.Join(t.TempDir(), "blob.bin")
	d := New(srv.url("/pub/blob.bin"), out, Options{Conns: 4, SHA256: sha256hex(data)})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(out)
	if len(got) != len(data) {
		t.Fatalf("size = %d, want %d", len(got), len(data))
	}
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if len(srv.offsets) != 1 || srv.offsets[0] != 0 {
		t.Fatalf("expected a single whole-file RETR, got offsets %v", srv.offsets)
	}
}

func TestFTPBadPasswordIsPermanent(t *testing.T) {
	srv := newFTPTestServer(t, []byte("x"), false)
	u := "ftp://user:wrong@" + srv.ln.Addr().String() + "/pub/blob.bin"
	_, err := Probe(context.Background(), nil, newRequestConfig(Options{}), u)
	if err == nil || isTransient(err) {
		t.Fatalf("bad password: err=%v transient=%v; want a permanent error", err, err != nil && isTransient(err))
	}
}
