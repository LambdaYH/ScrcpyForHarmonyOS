#include "../../main/cpp/decoder/VideoTiming.h"

#include <cassert>
#include <chrono>
#include <cstdint>
#include <iostream>

using Clock = scrcpy::VideoFrameClock::Clock;
using namespace std::chrono_literals;

static void assertUs(const char* name, Clock::duration actual, Clock::duration expected) {
    assert(actual == expected);
    std::cout << name << "="
              << std::chrono::duration_cast<std::chrono::microseconds>(actual).count() << "us\n";
}

static void testContinuousAcrossLongTimeline() {
    for (const int32_t fps : {30, 60, 120}) {
        scrcpy::VideoFrameClock clock;
        const auto origin = Clock::time_point{};
        clock.target(0, origin, fps);
        const int64_t frameCount = 600LL * fps;
        // Feed every frame so each delta remains one frame, including the 60/90/600s boundaries.
        for (int64_t frame = 1; frame <= frameCount; ++frame) {
            const int64_t ptsUs = frame * 1'000'000 / fps;
            const auto dispatch = origin + std::chrono::microseconds(ptsUs - 5'000);
            const auto target = clock.target(ptsUs, dispatch, fps);
            if (ptsUs == 60'000'000 || ptsUs == 90'000'000 || ptsUs == 600'000'000) {
                assertUs("continuous_boundary_wait_5ms", target - dispatch, 5ms);
            } else {
                assert(target - dispatch == 5ms);
            }
        }
    }
}

static void testDiscontinuitiesAndRates() {
    for (const int32_t fps : {30, 60, 120}) {
        const auto t0 = Clock::time_point{};

        scrcpy::VideoFrameClock clock;
        clock.target(1'000'000, t0, fps);
        const auto frame = clock.target(1'000'000 + 5'000, t0, fps);
        assertUs("fps_wait_5ms", frame - t0, 5ms);

        const auto future = clock.target(1'000'000 + 5'000 + 40'000, t0, fps);
        assertUs("future_over_frame_rebase", future - t0, 0us);
        const auto afterFuture = clock.target(1'000'000 + 5'000 + 40'000 + 5'000, t0, fps);
        assertUs("future_rebase_no_debt", afterFuture - t0, 5ms);

        scrcpy::VideoFrameClock lagClock;
        lagClock.target(1'000'000, t0, fps);
        const auto lag = lagClock.target(1'100'000, t0 + 400ms, fps);
        assertUs("lag_over_250ms_rebase", lag - (t0 + 400ms), 0us);
        const auto afterLag = lagClock.target(1'105'000, t0 + 400ms, fps);
        assertUs("after_lag_rebase_wait_5ms", afterLag - (t0 + 400ms), 5ms);

        scrcpy::VideoFrameClock backwardsClock;
        backwardsClock.target(2'000'000, t0, fps);
        const auto backwards = backwardsClock.target(1'000'000, t0 + 10ms, fps);
        assertUs("pts_backwards_rebase", backwards - (t0 + 10ms), 0us);

        scrcpy::VideoFrameClock zeroClock;
        const auto zero = zeroClock.target(0, t0 + 701ms, fps);
        assertUs("pts_zero_rebase", zero - (t0 + 701ms), 0us);

        scrcpy::VideoFrameClock negativeClock;
        negativeClock.target(1'000'000, t0, fps);
        const auto negative = negativeClock.target(-1, t0 + 702ms, fps);
        assertUs("pts_negative_reset", negative - (t0 + 702ms), 0us);

        scrcpy::VideoFrameClock hugeClock;
        hugeClock.target(1'000'000, t0, fps);
        const auto huge = hugeClock.target(900'000'000'000LL, t0 + 10ms, fps);
        assertUs("pts_huge_jump_rebase", huge - (t0 + 10ms), 0us);
        const auto afterHuge = hugeClock.target(900'000'000'000LL + 5'000, t0 + 10ms, fps);
        assertUs("after_huge_rebase_wait_5ms", afterHuge - (t0 + 10ms), 5ms);
    }
}

static void testStartupAndRebufferGates() {
    const auto t0 = Clock::time_point{};

    scrcpy::VideoBufferGate startup;
    // Empty queue does not start the deadline. The first observed frame starts
    // it at the supplied timestamp; 31ms still waits and 32ms releases.
    assert(startup.shouldWait(0, 10, t0));
    assert(startup.shouldWait(1, 10, t0 + 1ms));
    assert(startup.shouldWait(9, 10, t0 + 31ms));
    assert(startup.shouldWait(9, 10, t0 + 32ms));
    assert(!startup.shouldWait(9, 10, t0 + 33ms));
    assert(!startup.shouldWait(10, 10, t0 + 1ms));

    scrcpy::VideoBufferGate emptyThenFirst;
    assert(emptyThenFirst.shouldWait(0, 10, t0));
    assert(emptyThenFirst.shouldWait(1, 10, t0 + 10ms));
    assert(emptyThenFirst.shouldWait(1, 10, t0 + 41ms));
    assert(!emptyThenFirst.shouldWait(1, 10, t0 + 42ms));

    scrcpy::VideoBufferGate rebuffer;
    rebuffer.begin(t0);
    assert(rebuffer.shouldWait(1, 2, t0));
    assert(!rebuffer.shouldWait(1, 2, t0 + 32ms));

    scrcpy::VideoBufferGate rebufferSecond;
    rebufferSecond.begin(t0);
    assert(!rebufferSecond.shouldWait(2, 2, t0 + 1ms));
    std::cout << "startup_rebuffer_gate_pass=1\n";
}

int main() {
    testContinuousAcrossLongTimeline();
    testDiscontinuitiesAndRates();
    testStartupAndRebufferGates();
    std::cout << "VIDEO_TIMING_REGRESSION_PASS\n";
    return 0;
}
