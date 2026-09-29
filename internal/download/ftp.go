package download

// Minimal FTP / FTPS (explicit TLS) client for downloads: SIZE, MDTM, REST and
// RETR over a passive data connection. That is enough to probe a file, fetch
// byte ranges on several connections (one control + data pair per segment)
// and resume, mirroring what HTTP ranges give the engine. Not a general FTP
// client: no listings, no uploads, no active mode.

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const ftpReplyTimeout = 30 * time.Second

// ftpError is a server reply outside what a command expected. 4xx replies are
// transient ("try again later"), 5xx permanent (login, missing file).
type ftpError struct {
	code int
	msg  string
}

func (e *ftpError) Error() string      { return fmt.Sprintf("ftp: %d %s", e.code, e.msg) }
func (e *ftpError) transient() bool    { return e.code >= 400 && e.code < 500 }
func (e *ftpError) tooManyConns() bool { return e.code == 421 }

// isFTP reports whether rawURL is an ftp:// or ftps:// URL.
func isFTP(rawURL string) bool {
	u, err := url.Parse(rawURL)
	return err == nil && (u.Scheme == "ftp" || u.Scheme == "ftps")
}

type ftpConn struct {
	ctrl   net.Conn
	r      *bufio.Reader
	tlsCfg *tls.Config // set for ftps: data connections are wrapped too
	host   string
	done   chan struct{} // closed by Close; stops the ctx watcher
}

// ftpDial opens and logs in a control connection. Credentials: user:pass in
// the URL, else the engine's BasicUser/BasicPassword, else anonymous.
func ftpDial(ctx context.Context, u *url.URL, opts Options) (*ftpConn, error) {
	host, port := u.Hostname(), u.Port()
	if port == "" {
		port = "21"
	}
	d := net.Dialer{Timeout: 20 * time.Second}
	c, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, &netError{err}
	}
	f := &ftpConn{ctrl: c, r: bufio.NewReader(c), host: host, done: make(chan struct{})}
	// Cancellation: closing the control connection unblocks any pending reply.
	go func() {
		select {
		case <-ctx.Done():
			f.ctrl.Close()
		case <-f.done:
		}
	}()
	if _, _, err := f.expect(220); err != nil { // greeting
		f.Close()
		return nil, err
	}
	if u.Scheme == "ftps" {
		f.tlsCfg = &tls.Config{ServerName: host, InsecureSkipVerify: opts.Insecure} //nolint:gosec // user opt-in
		if _, _, err := f.cmd("AUTH TLS", 234); err != nil {
			f.Close()
			return nil, err
		}
		tc := tls.Client(c, f.tlsCfg)
		if err := tc.HandshakeContext(ctx); err != nil {
			f.Close()
			return nil, &netError{err}
		}
		f.ctrl, f.r = tc, bufio.NewReader(tc)
		if _, _, err := f.cmd("PBSZ 0", 200); err != nil {
			f.Close()
			return nil, err
		}
		if _, _, err := f.cmd("PROT P", 200); err != nil {
			f.Close()
			return nil, err
		}
	}
	user, pass := "anonymous", "cascade@"
	if u.User != nil {
		user = u.User.Username()
		if p, ok := u.User.Password(); ok {
			pass = p
		}
	}
	if opts.BasicUser != "" {
		user, pass = opts.BasicUser, opts.BasicPassword
	}
	code, msg, err := f.cmd("USER "+user, 0)
	if err == nil && code == 331 {
		code, msg, err = f.cmd("PASS "+pass, 0)
	}
	if err == nil && code != 230 {
		err = &ftpError{code, msg}
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	if _, _, err := f.cmd("TYPE I", 200); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// Close ends the session (QUIT is best effort) and stops the ctx watcher.
func (f *ftpConn) Close() error {
	select {
	case <-f.done:
		return nil
	default:
	}
	close(f.done)
	_ = f.ctrl.SetDeadline(time.Now().Add(2 * time.Second))
	_, _ = f.ctrl.Write([]byte("QUIT\r\n"))
	return f.ctrl.Close()
}

// cmd sends one command and reads the reply. want != 0 turns any other code
// into an *ftpError.
func (f *ftpConn) cmd(line string, want int) (int, string, error) {
	_ = f.ctrl.SetDeadline(time.Now().Add(ftpReplyTimeout))
	if _, err := f.ctrl.Write([]byte(line + "\r\n")); err != nil {
		return 0, "", &netError{err}
	}
	return f.expect(want)
}

// expect reads one (possibly multi-line) reply.
func (f *ftpConn) expect(want int) (int, string, error) {
	_ = f.ctrl.SetDeadline(time.Now().Add(ftpReplyTimeout))
	line, err := f.r.ReadString('\n')
	if err != nil {
		return 0, "", &netError{err}
	}
	line = strings.TrimRight(line, "\r\n")
	if len(line) < 3 {
		return 0, "", fmt.Errorf("ftp: malformed reply %q", line)
	}
	code, err := strconv.Atoi(line[:3])
	if err != nil {
		return 0, "", fmt.Errorf("ftp: malformed reply %q", line)
	}
	msg := strings.TrimSpace(line[3:])
	if len(line) > 3 && line[3] == '-' { // multi-line: ends with "<code> ..."
		end := line[:3] + " "
		for {
			l, err := f.r.ReadString('\n')
			if err != nil {
				return 0, "", &netError{err}
			}
			if strings.HasPrefix(l, end) {
				msg = strings.TrimSpace(l[4:])
				break
			}
		}
	}
	if want != 0 && code != want {
		return code, msg, &ftpError{code, msg}
	}
	return code, msg, nil
}

// passive opens a data connection via EPSV, falling back to PASV.
func (f *ftpConn) passive(ctx context.Context) (net.Conn, error) {
	var addr string
	if _, msg, err := f.cmd("EPSV", 229); err == nil {
		// "Entering Extended Passive Mode (|||port|)"
		if i, j := strings.Index(msg, "(|||"), strings.LastIndex(msg, "|)"); i >= 0 && j > i {
			addr = net.JoinHostPort(f.host, msg[i+4:j])
		}
	}
	if addr == "" {
		_, msg, err := f.cmd("PASV", 227)
		if err != nil {
			return nil, err
		}
		// "Entering Passive Mode (h1,h2,h3,h4,p1,p2)"
		i, j := strings.Index(msg, "("), strings.LastIndex(msg, ")")
		if i < 0 || j <= i {
			return nil, fmt.Errorf("ftp: bad PASV reply %q", msg)
		}
		p := strings.Split(msg[i+1:j], ",")
		if len(p) != 6 {
			return nil, fmt.Errorf("ftp: bad PASV reply %q", msg)
		}
		hi, _ := strconv.Atoi(p[4])
		lo, _ := strconv.Atoi(p[5])
		// Use the control host; NAT'd servers often advertise a private address.
		addr = net.JoinHostPort(f.host, strconv.Itoa(hi<<8|lo))
	}
	d := net.Dialer{Timeout: 20 * time.Second}
	c, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, &netError{err}
	}
	if f.tlsCfg != nil {
		tc := tls.Client(c, f.tlsCfg)
		if err := tc.HandshakeContext(ctx); err != nil {
			c.Close()
			return nil, &netError{err}
		}
		return tc, nil
	}
	return c, nil
}

// ftpPath is the file path a URL refers to, as the server expects it.
func ftpPath(u *url.URL) string {
	if u.Path == "" {
		return "/"
	}
	return u.Path
}

// ftpProbe reports size (SIZE), a validator (MDTM) and whether REST works.
func ftpProbe(ctx context.Context, rawURL string, opts Options) (ProbeResult, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ProbeResult{}, err
	}
	f, err := ftpDial(ctx, u, opts)
	if err != nil {
		return ProbeResult{}, err
	}
	defer f.Close()
	p := ftpPath(u)
	res := ProbeResult{FinalURL: rawURL, Size: -1}
	if _, msg, err := f.cmd("SIZE "+p, 213); err == nil {
		if n, err := strconv.ParseInt(strings.TrimSpace(msg), 10, 64); err == nil {
			res.Size = n
		}
	} else {
		var fe *ftpError
		if errors.As(err, &fe) && fe.code >= 500 && fe.code != 502 {
			return ProbeResult{}, fmt.Errorf("%s: %w", p, err) // 550: no such file
		}
	}
	if _, msg, err := f.cmd("MDTM "+p, 213); err == nil {
		res.LastModified = strings.TrimSpace(msg)
	}
	_, _, err = f.cmd("REST 0", 350)
	res.AcceptRanges = err == nil
	return res, nil
}

// ftpBody streams a RETR; Close ends the transfer and the session.
type ftpBody struct {
	data net.Conn
	conn *ftpConn
}

func (b *ftpBody) Read(p []byte) (int, error) {
	_ = b.data.SetReadDeadline(time.Now().Add(ftpReplyTimeout))
	return b.data.Read(p)
}

func (b *ftpBody) Close() error {
	_ = b.data.Close()
	// The server replies 226 (complete) or 426 (we aborted a partial range);
	// either way the session is done.
	_ = b.conn.ctrl.SetDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = b.conn.expect(0)
	return b.conn.Close()
}

// ftpOpen starts a RETR at byte offset from (REST). The caller reads as much
// as it wants and closes; FTP has no end offset.
func ftpOpen(ctx context.Context, rawURL string, from int64, opts Options) (io.ReadCloser, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	f, err := ftpDial(ctx, u, opts)
	if err != nil {
		return nil, err
	}
	data, err := f.passive(ctx)
	if err != nil {
		f.Close()
		return nil, err
	}
	if from > 0 {
		if _, _, err := f.cmd(fmt.Sprintf("REST %d", from), 350); err != nil {
			data.Close()
			f.Close()
			return nil, err
		}
	}
	code, msg, err := f.cmd("RETR "+ftpPath(u), 0)
	if err == nil && code != 150 && code != 125 {
		err = &ftpError{code, msg}
	}
	if err != nil {
		data.Close()
		f.Close()
		return nil, err
	}
	return &ftpBody{data: data, conn: f}, nil
}
