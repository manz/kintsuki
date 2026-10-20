#pragma once

namespace nall::Beat::Single {

inline auto apply(std::span<const u8> source, std::span<const u8> beat, maybe<string&> manifest = {}, maybe<string&> result = {}) -> maybe<std::vector<u8>> {
  #define error(text) { if(result) *result = {"error: ", text}; return {}; }
  #define warning(text) { if(result) *result = {"warning: ", text}; return target; }
  #define success() { if(result) *result = ""; return target; }
  if(beat.size() < 19) error("beat size mismatch");

  std::vector<u8> target;

  // Every offset below comes from the patch itself: a truncated or
  // crafted beat must not index past `beat`, `source` or `target`.
  u32 beatOffset = 0;
  bool truncated = false;
  auto read = [&]() -> u8 {
    if(beatOffset >= beat.size()) { truncated = true; return 0; }
    return beat[beatOffset++];
  };

  auto decode = [&]() -> u64 {
    u64 data = 0, shift = 1;
    while(true) {
      u8 x = read();
      if(truncated) break;
      data += (x & 0x7f) * shift;
      if(x & 0x80) break;
      shift <<= 7;
      data += shift;
    }
    return data;
  };

  auto write = [&](u8 data) {
    target.push_back(data);
  };

  if(read() != 'B') error("beat header invalid");
  if(read() != 'P') error("beat header invalid");
  if(read() != 'S') error("beat header invalid");
  if(read() != '1') error("beat version mismatch");
  if(decode() != source.size()) error("source size mismatch");
  u32 targetSize = decode();
  target.reserve(std::min<u32>(targetSize, 64_MiB));  // header-declared, untrusted
  u32 metadataSize = decode();
  if(metadataSize > beat.size() - 12 - beatOffset) error("metadata size mismatch");
  for(u32 n : range(metadataSize)) {
    auto data = read();
    if(manifest) manifest->append((char)data);
  }

  enum : u32 { SourceRead, TargetRead, SourceCopy, TargetCopy };

  u32 sourceRelativeOffset = 0, targetRelativeOffset = 0;
  while(beatOffset < beat.size() - 12) {
    u64 command = decode();
    u32 mode = command & 3;
    u64 length = (command >> 2) + 1;
    if(truncated) error("beat truncated");
    if(length > targetSize - target.size()) error("target size mismatch");

    if(mode == SourceRead) {
      if(target.size() + length > source.size()) error("source read out of range");
      while(length--) write(source[target.size()]);
    } else if(mode == TargetRead) {
      if(length > beat.size() - 12 - beatOffset) error("beat truncated");
      while(length--) write(read());
    } else {
      s32 offset = decode();
      if(truncated) error("beat truncated");
      offset = offset & 1 ? -(offset >> 1) : (offset >> 1);
      if(mode == SourceCopy) {
        sourceRelativeOffset += offset;
        if((u64)sourceRelativeOffset + length > source.size()) error("source copy out of range");
        while(length--) write(source[sourceRelativeOffset++]);
      } else {
        targetRelativeOffset += offset;
        // TargetCopy may overlap the bytes it is writing (RLE), so only the
        // start has to sit inside what's been written so far.
        if(targetRelativeOffset >= target.size()) error("target copy out of range");
        while(length--) write(target[targetRelativeOffset++]);
      }
    }
  }

  u32 sourceHash = 0, targetHash = 0, beatHash = 0;
  for(u32 shift : range(0, 32, 8)) sourceHash |= read() << shift;
  for(u32 shift : range(0, 32, 8)) targetHash |= read() << shift;
  for(u32 shift : range(0, 32, 8)) beatHash   |= read() << shift;

  if(target.size() != targetSize) warning("target size mismatch");
  if(sourceHash != Hash::CRC32(source).value()) warning("source hash mismatch");
  if(targetHash != Hash::CRC32(target).value()) warning("target hash mismatch");
  if(beatHash != Hash::CRC32({beat.data(), beat.size() - 4}).value()) warning("beat hash mismatch");

  success();
  #undef error
  #undef warning
  #undef success
}

}
