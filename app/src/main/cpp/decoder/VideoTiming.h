#ifndef SCRCPY_VIDEO_TIMING_H
#define SCRCPY_VIDEO_TIMING_H

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>

namespace scrcpy {

// No dependency on the codec: the same scheduling policy is exercised by tests.
class VideoFrameClock {
public:
    using Clock = std::chrono::steady_clock;

    Clock::time_point target(int64_t ptsUs, Clock::time_point now, int32_t frameRate) {
        if (ptsUs < 0) {
            initialized_ = false;
            return now;
        }
        auto next = now;
        if (initialized_ && ptsUs >= lastPtsUs_) {
            const int64_t deltaUs = ptsUs - lastPtsUs_;
            // Bound a single discontinuity, not the lifetime of the stream.
            // Rolling the origin preserves pacing past 60 seconds and hours.
            if (deltaUs <= 60LL * 1000 * 1000) {
                next = lastTarget_ + std::chrono::microseconds(deltaUs);
                const int64_t safeFrameRate = std::max<int32_t>(1, frameRate);
                const int64_t frameIntervalUs =
                    (1000000LL + safeFrameRate - 1) / safeFrameRate;
                // max_fps is only an upper bound. The encoder cadence is
                // variable, so a valid observed PTS interval may be longer
                // than the interval implied by the configured maximum.
                const int64_t observedIntervalUs = std::max<int64_t>(0, deltaUs);
                const int64_t expectedIntervalUs =
                    std::max(frameIntervalUs, observedIntervalUs);
                const auto maxLead = std::chrono::microseconds(
                    std::min<int64_t>(50000, expectedIntervalUs + 2000));
                // Do not make touch feedback wait behind an implausible future
                // timestamp. One complete frame interval plus a small scheduler
                // tolerance is valid; anything beyond that is queued latency.
                if (next - now > maxLead || now - next > std::chrono::milliseconds(250)) {
                    next = now;
                }
            }
        }
        initialized_ = true;
        lastPtsUs_ = ptsUs;
        lastTarget_ = next;
        return next;
    }

private:
    bool initialized_ = false;
    int64_t lastPtsUs_ = 0;
    Clock::time_point lastTarget_ {};
};

class VideoBufferGate {
public:
    using Clock = std::chrono::steady_clock;
    // Buffer capacity/watermarks stay unchanged. Only the intentional wait is
    // bounded, so a static screen's first update cannot wait for more input.
    static constexpr int32_t MAX_WAIT_MS = 32;

    void begin(Clock::time_point now) {
        started_ = true;
        start_ = now;
    }

    bool shouldWait(size_t queued, size_t watermark, Clock::time_point now) {
        if (queued >= watermark) {
            return false;
        }
        if (!started_ && queued > 0) {
            begin(now);
        }
        return !started_ || now - start_ < std::chrono::milliseconds(MAX_WAIT_MS);
    }

private:
    bool started_ = false;
    Clock::time_point start_ {};
};

} // namespace scrcpy
#endif
