"""Audio capture API: ares resamples the SPC/DSP output to a 48kHz stereo
ring the Python side drains. These tests exercise the plumbing (gating,
counts, sample format) against a booting ROM. The DSP emits samples every
frame even when the program is silent, so the sample-count assertions hold
without needing an actual tune."""

from __future__ import annotations

from kintsuki import Emu


def test_audio_disabled_by_default(assemble_rom):
    rom = assemble_rom("test_rom.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        assert emu.audio_enabled is False
        emu.run_frames(30)
        # Nothing captured while disabled.
        assert emu.audio_available() == 0
        assert len(emu.read_audio()) == 0


def test_audio_sample_rate(assemble_rom):
    rom = assemble_rom("test_rom.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        assert emu.audio_sample_rate == 48000.0


def test_audio_capture_count(assemble_rom):
    rom = assemble_rom("test_rom.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.enable_audio()
        assert emu.audio_enabled is True
        emu.run_frames(30)
        avail = emu.audio_available()
        # 30 frames (~24k stereo frames) overflows the ~8192-frame ring,
        # so assert it filled rather than an exact count.
        assert avail > 0
        # Drain: interleaved stereo float32, so twice the frame count.
        buf = emu.read_audio()
        assert len(buf) == avail * 2
        # Samples are normalized floats.
        assert all(-1.0 <= s <= 1.0 for s in buf)
        # Ring is empty after a full drain.
        assert emu.audio_available() == 0
        assert len(emu.read_audio()) == 0


def test_audio_read_max_frames(assemble_rom):
    rom = assemble_rom("test_rom.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.enable_audio()
        emu.run_frames(5)
        avail = emu.audio_available()
        assert avail > 4
        partial = emu.read_audio(max_frames=4)
        assert len(partial) == 8  # 4 stereo frames
        assert emu.audio_available() == avail - 4


def test_audio_toggle_flushes(assemble_rom):
    rom = assemble_rom("test_rom.s")
    with Emu() as emu:
        emu.load_rom(str(rom))
        emu.enable_audio()
        emu.run_frames(5)
        assert emu.audio_available() > 0
        # Disabling flushes the ring so the next capture starts clean.
        emu.enable_audio(False)
        assert emu.audio_available() == 0
