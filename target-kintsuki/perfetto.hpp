#pragma once
// Perfetto trace writer: hand-encoded protobuf TracePackets streamed to a
// file (open it in ui.perfetto.dev). Tracks are named lanes; slices nest per
// track; event names are interned so a slice costs ~20 bytes.

#include <cstdint>
#include <cstdio>
#include <string>
#include <unordered_map>
#include <vector>

namespace kintsuki {

struct TraceArg {
  const char* name;
  uint64_t value;
};

class PerfettoTrace {
public:
  ~PerfettoTrace() { close(); }

  bool open(const char* path);
  void close();
  bool active() const { return file_ != nullptr; }
  uint64_t bytes() const { return written_ + buf_.size(); }

  // Declares a track (lane) under `parent` (0: top level); returns its uuid.
  uint64_t track(const std::string& name, uint64_t parent = 0);
  // Declares a counter track: a value over time, drawn as a graph.
  uint64_t counterTrack(const std::string& name, uint64_t parent = 0);
  void begin(uint64_t track, uint64_t ts_ns, const std::string& name,
             const std::vector<TraceArg>& args = {});
  void end(uint64_t track, uint64_t ts_ns);
  void instant(uint64_t track, uint64_t ts_ns, const std::string& name,
               const std::vector<TraceArg>& args = {});
  // A counter track's value from `ts_ns` on.
  void counter(uint64_t track, uint64_t ts_ns, double value);
  // An instant the UI's Screenshots track shows (category android_screenshot).
  void screenshot(uint64_t track, uint64_t ts_ns, const std::vector<uint8_t>& jpeg);

private:
  uint64_t declare(const std::string& name, uint64_t parent, bool counter);
  // `extra`: TrackEvent fields already encoded, appended as is.
  void event(int type, uint64_t track, uint64_t ts_ns, const std::string* name,
             const std::vector<TraceArg>& args, const std::string& extra = {});
  void packet(const std::string& body);
  void flush();

  std::FILE* file_ = nullptr;
  std::string buf_;
  uint64_t written_ = 0;
  uint64_t nextUuid_ = 1;
  std::unordered_map<std::string, uint64_t> names_;
};

}  // namespace kintsuki
