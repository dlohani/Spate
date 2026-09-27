package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestMessageFraming(t *testing.T) {
	var buf bytes.Buffer
	writeMessage(&buf, reply{OK: true, Addr: "127.0.0.1:8760", Token: "abc"})

	// 4-byte little-endian length prefix, then JSON.
	var n uint32
	if err := binary.Read(bytes.NewReader(buf.Bytes()[:4]), binary.LittleEndian, &n); err != nil {
		t.Fatal(err)
	}
	if int(n) != buf.Len()-4 {
		t.Fatalf("length prefix %d, want %d", n, buf.Len()-4)
	}

	var got reply
	if err := readMessage(&buf, &got); err != nil {
		t.Fatal(err)
	}
	if !got.OK || got.Addr != "127.0.0.1:8760" || got.Token != "abc" {
		t.Fatalf("round trip mismatch: %+v", got)
	}
}

func TestReadMessageRejectsOversize(t *testing.T) {
	var buf bytes.Buffer
	_ = binary.Write(&buf, binary.LittleEndian, uint32(2<<20))
	var v request
	if err := readMessage(&buf, &v); err == nil {
		t.Fatal("expected oversize message to be rejected")
	}
}

func TestFindAppReturnsEmptyWhenNothingListens(t *testing.T) {
	// Nothing should answer on the probe ports as "cascade" from inside a unit
	// test; this guards the "not running" path the launcher depends on.
	if a := findApp(); a != "" {
		t.Skipf("a Cascade app is running at %s; skipping", a)
	}
}
