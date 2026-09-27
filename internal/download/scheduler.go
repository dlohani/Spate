package download

// Work scheduling for dynamic work-stealing. A pool of workers each own one
// segment at a time. When a worker becomes free and no unassigned segment is
// left, it steals the tail of whichever active segment has the most bytes still
// to fetch, splitting that segment in two. Combined with windowed fetching (see
// fetchPiece), this keeps every connection busy until the whole file is done, so
// one slow connection can't stall the transfer.

// nextWork returns a segment index for a free worker to download, and true, or
// (-1, false) when there is no more work worth doing.
//
// It first hands out any unassigned incomplete segment. Failing that, it steals:
// it finds the active segment with the largest remaining tail and, if that tail
// is at least stealMin bytes, splits it, returning the newly created tail
// segment. stealMin must be >= 2*windowSize so the split point always lies
// beyond the victim's current in-flight window (preventing double-download).
func (c *Control) nextWork(stealMin int64) (int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// 1. Any unassigned, incomplete segment.
	for i := range c.Segments {
		if !c.assigned[i] && !c.Segments[i].Complete() {
			c.assigned[i] = true
			return i, true
		}
	}

	// 2. Steal the largest active tail.
	bestIdx := -1
	var bestRem int64
	for i := range c.Segments {
		if !c.assigned[i] {
			continue
		}
		s := c.Segments[i]
		rem := s.End - (s.Start + s.Done) + 1 // bytes not yet fetched
		if rem > bestRem {
			bestRem = rem
			bestIdx = i
		}
	}
	if bestIdx < 0 || bestRem < stealMin {
		return -1, false
	}

	v := &c.Segments[bestIdx]
	absCur := v.Start + v.Done
	mid := absCur + (v.End-absCur)/2 // both halves >= stealMin/2 >= windowSize
	tail := Segment{
		Index: len(c.Segments),
		Start: mid + 1,
		End:   v.End,
	}
	v.End = mid
	c.Segments = append(c.Segments, tail)
	c.assigned[tail.Index] = true
	c.splits++
	return tail.Index, true
}

// finish releases a segment previously handed out by nextWork.
func (c *Control) finish(idx int) {
	c.mu.Lock()
	c.assigned[idx] = false
	c.mu.Unlock()
}

// Splits returns how many work-steal splits occurred (diagnostics/tests).
func (c *Control) Splits() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.splits
}
