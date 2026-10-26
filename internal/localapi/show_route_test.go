package localapi

import (
	"net/http"
	"testing"
)

func TestShowRouteServed(t *testing.T) {
	s := New(nil, "tok", t.TempDir())
	addr, err := s.Start()
	if err != nil {
		t.Skip("port busy:", err)
	}
	defer s.Close()
	req, _ := http.NewRequest(http.MethodPost, "http://"+addr+"/show", nil)
	req.Header.Set("X-Spate-Token", "tok")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || !s.ShowPending() {
		t.Fatalf("POST /show over HTTP: %d", resp.StatusCode)
	}
}
