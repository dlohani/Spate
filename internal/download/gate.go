package download

// Gating lets a policy decide whether a download may run right now, e.g. only on
// Wi-Fi or only when not on low battery. The engine checks the gate before
// starting and periodically while running; if the gate closes mid-download the
// run is stopped cleanly (leaving resumable state) and Run returns a *GateError.

// GateFunc reports whether downloading may proceed; when it may not, it returns
// a human-readable reason. A nil GateFunc imposes no restriction.
type GateFunc func() (ok bool, reason string)

// GateError is returned by Run when a policy gate blocked or interrupted the
// download. Callers (e.g. the job manager) can detect it to retry later rather
// than treat it as a hard failure.
type GateError struct{ Reason string }

func (e *GateError) Error() string { return "download gated: " + e.Reason }
