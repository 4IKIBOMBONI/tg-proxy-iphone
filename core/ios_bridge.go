package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// iOS bridge
//
// The upstream Android core ships logs to logcat via androidLogProxy(). On iOS
// the NetworkExtension process that hosts this archive cannot write to logcat
// and the main app lives in a separate process, so we keep a small in-memory
// ring buffer of the most recent log lines. The PacketTunnelProvider drains it
// periodically via GetLogs() and forwards the lines to the app through the
// shared App Group container.
// ---------------------------------------------------------------------------

const iosLogRingSize = 500

var (
	iosLogMu    sync.Mutex
	iosLogRing  [iosLogRingSize]string
	iosLogHead  int
	iosLogCount int
)

// iosCaptureLog is called from androidLogWriter.Write for every emitted log
// line. It splits multi-line writes and stores each line (with a wall-clock
// timestamp) in the ring buffer.
func iosCaptureLog(p []byte) {
	text := strings.TrimRight(string(p), "\n")
	if text == "" {
		return
	}
	ts := time.Now().Format("15:04:05")
	iosLogMu.Lock()
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		iosLogRing[iosLogHead] = ts + " " + line
		iosLogHead = (iosLogHead + 1) % iosLogRingSize
		if iosLogCount < iosLogRingSize {
			iosLogCount++
		}
	}
	iosLogMu.Unlock()
}

func drainLogs() string {
	iosLogMu.Lock()
	defer iosLogMu.Unlock()
	if iosLogCount == 0 {
		return ""
	}
	lines := make([]string, 0, iosLogCount)
	start := (iosLogHead - iosLogCount + iosLogRingSize) % iosLogRingSize
	for i := 0; i < iosLogCount; i++ {
		lines = append(lines, iosLogRing[(start+i)%iosLogRingSize])
	}
	return strings.Join(lines, "\n")
}

// GetLogs returns the buffered log lines joined by "\n". The caller owns the
// returned C string and must release it with FreeString.
//
//export GetLogs
func GetLogs() *C.char {
	return C.CString(drainLogs())
}

//export ClearLogs
func ClearLogs() {
	iosLogMu.Lock()
	iosLogHead = 0
	iosLogCount = 0
	iosLogMu.Unlock()
}

// GetStatsRu returns the compact Russian one-line stats summary used by the UI.
// The caller owns the returned C string and must release it with FreeString.
//
//export GetStatsRu
func GetStatsRu() *C.char {
	return C.CString(stats.SummaryRu())
}
