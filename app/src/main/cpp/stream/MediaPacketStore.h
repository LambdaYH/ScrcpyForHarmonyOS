#ifndef SCRCPY_MEDIA_PACKET_STORE_H
#define SCRCPY_MEDIA_PACKET_STORE_H

#include "stream/EncodedPacket.h"
#include "concurrentqueue/concurrentqueue.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <vector>

template <typename PacketT>
struct PacketStoreTraits;

template <>
struct PacketStoreTraits<EncodedVideoPacket> {
    static void reset(EncodedVideoPacket* packet) {
        packet->pts = 0;
        packet->submitFlags = 0;
        packet->isKeyFrame = false;
    }

    static EncodedVideoPacket* reclaimQueuedPacket(std::deque<EncodedVideoPacket*>& queue, uint64_t& droppedCount) {
        auto dropIt = std::find_if(queue.begin(), queue.end(),
                                   [](const EncodedVideoPacket* packet) { return !packet->isKeyFrame; });
        if (dropIt == queue.end() && !queue.empty()) {
            dropIt = queue.begin();
        }
        if (dropIt == queue.end()) {
            return nullptr;
        }
        EncodedVideoPacket* packet = *dropIt;
        queue.erase(dropIt);
        ++droppedCount;
        return packet;
    }
};

template <>
struct PacketStoreTraits<EncodedAudioPacket> {
    static void reset(EncodedAudioPacket* packet) {
        packet->pts = 0;
        packet->submitFlags = 0;
    }

    static EncodedAudioPacket* reclaimQueuedPacket(std::deque<EncodedAudioPacket*>& queue, uint64_t& droppedCount) {
        if (queue.empty()) {
            return nullptr;
        }
        EncodedAudioPacket* packet = queue.front();
        queue.pop_front();
        ++droppedCount;
        return packet;
    }
};

template <typename PacketT>
class MediaPacketStore {
public:
    void initialize(size_t poolSize) {
        reset();

        std::lock_guard<std::mutex> lock(mutex_);
        storage_.reserve(poolSize);
        for (size_t i = 0; i < poolSize; ++i) {
            auto packet = std::make_unique<PacketT>();
            freePackets_.enqueue(packet.get());
            storage_.push_back(std::move(packet));
        }
    }

    void reset() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.clear();
            storage_.clear();
            latestConfig_.clear();
            latestConfigFlags_ = 0;
            latestConfigSerial_ = 0;
            droppedCount_ = 0;
        }
        PacketT* packet = nullptr;
        while (freePackets_.try_dequeue(packet)) {
        }
        cv_.notify_all();
    }

    PacketT* acquireForWrite() {
        PacketT* packet = nullptr;
        if (freePackets_.try_dequeue(packet)) {
            return packet;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        // No free packet available: reclaim a fully queued packet instead of
        // blocking the upstream reader. This keeps overload handling at the
        // frame level rather than pushing it back down to the raw ADB byte stream.
        return PacketStoreTraits<PacketT>::reclaimQueuedPacket(queue_, droppedCount_);
    }

    PacketT* acquireFreeForWrite() {
        PacketT* packet = nullptr;
        if (freePackets_.try_dequeue(packet)) {
            return packet;
        }
        return nullptr;
    }

    PacketT* waitAcquireFreeForWrite(int32_t timeoutMs, const std::atomic<bool>& running) {
        PacketT* packet = acquireFreeForWrite();
        if (packet) {
            return packet;
        }

        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this, &packet, &running]() {
            return !running.load() || freePackets_.try_dequeue(packet);
        });
        return packet;
    }

    void enqueue(PacketT* packet) {
        if (!packet) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push_back(packet);
        }
        cv_.notify_one();
    }

    bool waitDequeue(PacketT*& packet,
                     const std::atomic<bool>& running,
                     const std::atomic<bool>& readerDone) {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this, &running, &readerDone]() {
            return !queue_.empty() || !running.load() || readerDone.load();
        });
        if (queue_.empty()) {
            return false;
        }
        packet = queue_.front();
        queue_.pop_front();
        return true;
    }

    bool waitDequeueTimed(PacketT*& packet,
                          int32_t timeoutMs,
                          const std::atomic<bool>& running,
                          const std::atomic<bool>& readerDone) {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this, &running, &readerDone]() {
            return !queue_.empty() || !running.load() || readerDone.load();
        });
        if (queue_.empty()) {
            return false;
        }
        packet = queue_.front();
        queue_.pop_front();
        return true;
    }

    void recycle(PacketT* packet) {
        if (!packet) {
            return;
        }
        PacketStoreTraits<PacketT>::reset(packet);
        freePackets_.enqueue(packet);
        cv_.notify_one();
    }

    void cacheConfig(const uint8_t* data, size_t len, uint32_t flags) {
        std::lock_guard<std::mutex> lock(mutex_);
        latestConfig_.assign(data, data + len);
        latestConfigFlags_ = flags;
        ++latestConfigSerial_;
    }

    bool copyPendingConfig(std::vector<uint8_t>& out,
                           uint32_t& flags,
                           uint64_t& serial,
                           uint64_t lastSerial) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (latestConfigSerial_ == 0 || latestConfigSerial_ == lastSerial || latestConfig_.empty()) {
            return false;
        }
        out = latestConfig_;
        flags = latestConfigFlags_;
        serial = latestConfigSerial_;
        return true;
    }

    size_t queuedSize() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return queue_.size();
    }

    uint64_t droppedCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return droppedCount_;
    }

    void notifyAll() {
        cv_.notify_all();
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<PacketT*> queue_;
    moodycamel::ConcurrentQueue<PacketT*> freePackets_;
    std::vector<std::unique_ptr<PacketT>> storage_;
    std::vector<uint8_t> latestConfig_;
    uint32_t latestConfigFlags_ = 0;
    uint64_t latestConfigSerial_ = 0;
    uint64_t droppedCount_ = 0;
};

#endif // SCRCPY_MEDIA_PACKET_STORE_H
