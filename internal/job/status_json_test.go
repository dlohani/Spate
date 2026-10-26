package job

import (
	"encoding/json"
	"errors"
	"reflect"
	"sort"
	"testing"
	"time"
)

func TestStatusJSONFieldSet(t *testing.T) {
	at := time.Unix(1_800_000_000, 0)
	st := Status{ID: "job-1", URL: "http://x/a", Out: "/dl/a", State: Pending, Priority: 2,
		Bytes: 10, Total: 100, Retries: 1, StartAt: at, FinishedAt: at, Err: errors.New("boom")}
	b, err := json.Marshal(st.JSON())
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	want := []string{"bytes", "error", "finishedAt", "id", "out", "priority", "retries", "startAt", "state", "total", "url"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("keys = %v, want %v", keys, want)
	}
	if m["state"] != "pending" || m["startAt"] != float64(at.Unix()) || m["error"] != "boom" {
		t.Fatalf("values: %v", m)
	}
	// Optional fields are omitted when unset; an empty list is [] not null.
	b, _ = json.Marshal(StatusesJSON(nil))
	if string(b) != "[]" {
		t.Fatalf("empty list = %s", b)
	}
	b, _ = json.Marshal(Status{ID: "j", State: Done}.JSON())
	if s := string(b); contains(s, "startAt") || contains(s, "error") || contains(s, "finishedAt") {
		t.Fatalf("unset optionals present: %s", s)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool { _, ok := index(s, sub); return ok })()
}

func index(s, sub string) (int, bool) {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i, true
		}
	}
	return -1, false
}
