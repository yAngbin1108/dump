//
//  SKLog.h
//  Blade
//
//  Append-only diagnostic log written to the app's Documents/sk.log.
//
//  This file is the ONLY place anything is logged. There is deliberately no
//  copy written outside the container: no live mirror into the Files-app shared
//  area, no per-line duplication. Documents is already the right location —
//  UIFileSharingEnabled puts it under Files > On My iPhone > Blade, which is
//  the same shared area, so the log is retrievable without being scattered
//  into the shared root.
//

#ifndef SKLog_h
#define SKLog_h

#import <Foundation/Foundation.h>

// printf-style, newline terminated, flushed after every line.
void SKLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// Absolute path of the log file (handy to print at startup).
NSString *SKLogPath(void);

// A live sink for every line SKLog() writes, in addition to the file.
//
// Without this the file was the only destination, so everything that reports
// through SKLog() — the kernelcache fetcher's [kc] lines, and every printf()
// reached through SKLogCaptureStdout() — was invisible in the UI. The TUI only
// renders what the screen appends, so a failed acquisition showed the caller's
// one-line "fetch failed" and nothing about which step produced it.
//
// The sink is called on whatever thread logged, so it must marshal to the main
// thread itself. Pass NULL to remove it.
typedef void (^SKLogSinkBlock)(NSString *line);
void SKLogSetSink(SKLogSinkBlock sink);


// Ring buffer of the most recent log lines, newest last (max ~800).
//
// The UI needs the tail of the log without re-reading the file on every redraw,
// and without a second destination: SKLog() already builds the line, so it is
// kept in memory here too. Each element carries the "hh:mm:ss.mmm  " prefix.
NSArray<NSString *> *SKLogRecentLines(void);

// Drop the in-memory buffer (a fresh run should not inherit the old noise).
void SKLogClearRecentLines(void);

// Redirect stdout and stderr into the log.
//
// The exploit chain and the kernelcache fetcher report everything through
// printf() — offsets.m alone has 81 of them, sbx_escape() has more — and an iOS
// app has no terminal, so all of it was being written into nothing. The only
// visible trace of a failure was whatever the caller happened to wrap itself,
// which is why "sbx_escape rc=-1" and a kernelcache download that never
// finished arrived with no explanation attached.
//
// Call this before anything that can print. Idempotent.
void SKLogCaptureStdout(void);

#endif /* SKLog_h */
