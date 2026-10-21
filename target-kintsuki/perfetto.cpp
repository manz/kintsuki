#include "perfetto.hpp"

// Field numbers from perfetto's protos (trace_packet.proto, track_event.proto,
// track_descriptor.proto, interned_data.proto, debug_annotation.proto).
namespace {
enum : uint32_t {
  kTracePacket = 1,              // Trace.packet
  kTimestamp = 8,                // TracePacket
  kSequenceId = 10,
  kTrackEvent = 11,
  kInternedData = 12,
  kSequenceFlags = 13,
  kTrackDescriptor = 60,
  kTrackUuid = 1,                // TrackDescriptor
  kTrackName = 2,
  kTrackParent = 5,
  kEventAnnotations = 4,         // TrackEvent
  kEventType = 9,
  kEventNameIid = 10,
  kEventTrack = 11,
  kInternEventNames = 2,         // InternedData
  kInternIid = 1,                // EventName
  kInternName = 2,
  kAnnotationUint = 3,           // DebugAnnotation
  kAnnotationName = 10,
};
enum : uint64_t { kSliceBegin = 1, kSliceEnd = 2, kInstant = 3 };
enum : uint64_t { kStateCleared = 1, kNeedsState = 2 };
constexpr uint32_t kSequence = 1;
constexpr size_t kFlushAt = 1u << 20;

void varint(std::string& out, uint64_t v) {
  while(v >= 0x80) {
    out.push_back(char((v & 0x7F) | 0x80));
    v >>= 7;
  }
  out.push_back(char(v));
}

void tag(std::string& out, uint32_t field, uint32_t wire) { varint(out, (uint64_t(field) << 3) | wire); }

void uintField(std::string& out, uint32_t field, uint64_t v) {
  tag(out, field, 0);
  varint(out, v);
}

void bytesField(std::string& out, uint32_t field, const std::string& v) {
  tag(out, field, 2);
  varint(out, v.size());
  out += v;
}
}  // namespace

namespace kintsuki {

bool PerfettoTrace::open(const char* path) {
  close();
  file_ = std::fopen(path, "wb");
  if(!file_) return false;
  written_ = 0;
  nextUuid_ = 1;
  names_.clear();
  std::string first;
  uintField(first, kSequenceId, kSequence);
  uintField(first, kSequenceFlags, kStateCleared);
  packet(first);
  return true;
}

void PerfettoTrace::close() {
  if(!file_) return;
  flush();
  std::fclose(file_);
  file_ = nullptr;
}

uint64_t PerfettoTrace::track(const std::string& name, uint64_t parent) {
  uint64_t uuid = nextUuid_++;
  std::string desc;
  uintField(desc, kTrackUuid, uuid);
  bytesField(desc, kTrackName, name);
  if(parent) uintField(desc, kTrackParent, parent);
  std::string body;
  bytesField(body, kTrackDescriptor, desc);
  packet(body);
  return uuid;
}

void PerfettoTrace::begin(uint64_t track, uint64_t ts_ns, const std::string& name,
                          const std::vector<TraceArg>& args) {
  event(kSliceBegin, track, ts_ns, &name, args);
}

void PerfettoTrace::end(uint64_t track, uint64_t ts_ns) {
  event(kSliceEnd, track, ts_ns, nullptr, {});
}

void PerfettoTrace::instant(uint64_t track, uint64_t ts_ns, const std::string& name,
                            const std::vector<TraceArg>& args) {
  event(kInstant, track, ts_ns, &name, args);
}

void PerfettoTrace::event(int type, uint64_t track, uint64_t ts_ns, const std::string* name,
                          const std::vector<TraceArg>& args) {
  if(!file_) return;
  std::string body;
  uintField(body, kTimestamp, ts_ns);
  uintField(body, kSequenceId, kSequence);
  uintField(body, kSequenceFlags, kNeedsState);
  std::string ev;
  uintField(ev, kEventType, uint64_t(type));
  uintField(ev, kEventTrack, track);
  if(name) {
    auto it = names_.find(*name);
    uint64_t iid;
    if(it == names_.end()) {
      iid = names_.size() + 1;
      names_.emplace(*name, iid);
      std::string entry, interned;
      uintField(entry, kInternIid, iid);
      bytesField(entry, kInternName, *name);
      bytesField(interned, kInternEventNames, entry);
      bytesField(body, kInternedData, interned);
    } else {
      iid = it->second;
    }
    uintField(ev, kEventNameIid, iid);
  }
  for(auto& a : args) {
    std::string ann;
    bytesField(ann, kAnnotationName, a.name);
    uintField(ann, kAnnotationUint, a.value);
    bytesField(ev, kEventAnnotations, ann);
  }
  bytesField(body, kTrackEvent, ev);
  packet(body);
}

void PerfettoTrace::packet(const std::string& body) {
  bytesField(buf_, kTracePacket, body);
  if(buf_.size() >= kFlushAt) flush();
}

void PerfettoTrace::flush() {
  if(!file_ || buf_.empty()) return;
  std::fwrite(buf_.data(), 1, buf_.size(), file_);
  written_ += buf_.size();
  buf_.clear();
}

}  // namespace kintsuki
