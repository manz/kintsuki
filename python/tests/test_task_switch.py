"""Shadow stacks across task switches: a TCS onto another stack parks the live
frames and resumes that stack's, for both the callstack and the profiler.

`asm/test_task_switch.s` swaps a kernel stack and a task stack with TCS: the
task is entered through a fabricated frame and yields from inside a call, the
two cases a single shadow stack gets wrong.
"""

from __future__ import annotations

from kintsuki import Emu, FnStat

FRAME_WORK = 0x008100
RUN_TASK = 0x008200
KERNEL_AFTER = 0x008300
TASK_STEP = 0x008500
YIELD = 0x008600
TASK_WORK = 0x008700


def _profile(emu: Emu, frames: int = 4) -> dict[int, FnStat]:
    emu.profile_start()
    emu.run_frames(frames)
    return {s.pc: s for s in emu.profile_stop()}


def test_kernel_frames_pair_across_switches(assemble_rom):
    """Each kernel call is popped by its own return, not by the task's."""
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_task_switch.s")))
        stats = _profile(emu)
        frame_work = stats[FRAME_WORK].calls
        assert frame_work > 10
        assert stats[RUN_TASK].calls in (frame_work, frame_work + 1)
        assert stats[KERNEL_AFTER].calls in (frame_work, frame_work - 1)


def test_task_frames_pair_across_yields(assemble_rom):
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_task_switch.s")))
        stats = _profile(emu)
        steps = stats[TASK_STEP].calls
        assert steps > 10
        assert stats[YIELD].calls in (steps, steps + 1)
        assert stats[TASK_WORK].calls in (2 * steps, 2 * steps + 1, 2 * steps + 2)


def test_parked_time_is_not_counted(assemble_rom):
    """task_step spans a yield, but the kernel's time while the task is parked
    stays out of its inclusive cycles: two task_work calls plus a little."""
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_task_switch.s")))
        stats = _profile(emu)
        step, work = stats[TASK_STEP], stats[TASK_WORK]
        per_step = step.incl_cycles / step.calls
        per_work = work.incl_cycles / work.calls
        assert 2 * per_work < per_step < 3 * per_work


def test_kernel_time_stays_on_the_kernel(assemble_rom):
    """frame_work = run_task + kernel_after (4x task_work), none of the task's
    time: below 5x task_work, above 4x."""
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_task_switch.s")))
        stats = _profile(emu)
        frame, work = stats[FRAME_WORK], stats[TASK_WORK]
        per_frame = frame.incl_cycles / frame.calls
        per_work = work.incl_cycles / work.calls
        assert 4 * per_work < per_frame < 5 * per_work


def test_local_frame_tcs_is_not_a_switch(assemble_rom):
    """kernel_after moves S by 16 bytes with TCS and back: still one frame,
    every call the same length."""
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_task_switch.s")))
        after = _profile(emu)[KERNEL_AFTER]
        assert after.excl_cycles == after.incl_cycles
        assert after.max_cycles - after.min_cycles < after.min_cycles // 10


def test_callstack_shows_only_the_running_stack(assemble_rom):
    """Inside task_work the backtrace is the task's: task_step -> task_work,
    with none of the parked kernel frames."""
    seen: list[set[int]] = []
    with Emu() as emu:
        emu.load_rom(str(assemble_rom("test_task_switch.s")))

        def on_work(pc: int, _value: int) -> None:
            seen.append({target for _, target, _ in emu.callstack()})

        emu.add_exec_callback(TASK_WORK, TASK_WORK, on_work)
        emu.run_frames(2)
    assert len(seen) > 10
    for targets in seen[2:]:
        assert targets == {TASK_STEP, TASK_WORK}
