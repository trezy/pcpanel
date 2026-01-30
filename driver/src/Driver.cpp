// PC Panel Pro Audio Driver
// Creates virtual audio output devices with loopback for passthrough
// Phase 3: Multiple virtual devices (9 channels)

#include <aspl/Driver.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Device.hpp>
#include <aspl/Stream.hpp>
#include <aspl/VolumeControl.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/ControlRequestHandler.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <vector>
#include <os/log.h>

namespace {

// Lock-free ring buffer for audio loopback
// Stores audio written to output for reading by input
class LoopbackBuffer {
public:
    static constexpr size_t kBufferFrames = 48000 * 5; // 5 seconds at 48kHz (increased from 1s)
    static constexpr size_t kChannels = 2;
    static constexpr size_t kBufferSize = kBufferFrames * kChannels * sizeof(Float32);

    LoopbackBuffer() : buffer_(kBufferSize, 0), writePos_(0), readPos_(0), underrunCount_(0), logCounter_(0) {}

    void write(const void* data, size_t bytes) {
        const uint8_t* src = static_cast<const uint8_t*>(data);
        size_t wp = writePos_.load(std::memory_order_relaxed);
        size_t rp = readPos_.load(std::memory_order_acquire);

        // Calculate available space (using wrapped positions)
        size_t used = wp - rp;  // This works due to unsigned wraparound
        if (used > kBufferSize) {
            // Read position is ahead - shouldn't happen but handle gracefully
            used = 0;
        }
        size_t space = kBufferSize - used;

        size_t toWrite = std::min(bytes, space);
        if (toWrite == 0) {
            return;  // Buffer full
        }

        size_t writeIdx = wp % kBufferSize;
        size_t firstChunk = std::min(toWrite, kBufferSize - writeIdx);

        std::memcpy(buffer_.data() + writeIdx, src, firstChunk);
        if (toWrite > firstChunk) {
            std::memcpy(buffer_.data(), src + firstChunk, toWrite - firstChunk);
        }

        writePos_.store(wp + toWrite, std::memory_order_release);
    }

    size_t read(void* data, size_t bytes) {
        uint8_t* dst = static_cast<uint8_t*>(data);
        size_t wp = writePos_.load(std::memory_order_acquire);
        size_t rp = readPos_.load(std::memory_order_relaxed);

        size_t available = wp - rp;  // Works with unsigned wraparound
        if (available > kBufferSize) {
            // Write wrapped around - reset to avoid stale data
            available = 0;
        }

        size_t toRead = std::min(bytes, available);

        // Log periodically to diagnose timing issues
        if (++logCounter_ % 500 == 0) {  // Every 500 reads (~10 seconds at typical callback rates)
            size_t underruns = underrunCount_.load();
            os_log(OS_LOG_DEFAULT, "PCPanel Loopback: available=%zu requested=%zu underruns=%zu",
                   available, bytes, underruns);
        }

        if (toRead > 0) {
            size_t readIdx = rp % kBufferSize;
            size_t firstChunk = std::min(toRead, kBufferSize - readIdx);

            std::memcpy(dst, buffer_.data() + readIdx, firstChunk);
            if (toRead > firstChunk) {
                std::memcpy(dst + firstChunk, buffer_.data(), toRead - firstChunk);
            }

            readPos_.store(rp + toRead, std::memory_order_release);
        }

        // Fill remaining with silence
        if (toRead < bytes) {
            std::memset(dst + toRead, 0, bytes - toRead);
            if (toRead == 0) {
                underrunCount_.fetch_add(1);
                os_log(OS_LOG_DEFAULT, "PCPanel Loopback UNDERRUN: requested=%zu available=%zu total_underruns=%zu",
                       bytes, available, underrunCount_.load() + 1);
            }
        }

        return toRead;
    }

    void clear() {
        writePos_.store(0, std::memory_order_relaxed);
        readPos_.store(0, std::memory_order_relaxed);
        underrunCount_.store(0, std::memory_order_relaxed);
        // Zero out buffer to prevent stale audio playback
        std::memset(buffer_.data(), 0, buffer_.size());
    }

private:
    std::vector<uint8_t> buffer_;
    std::atomic<size_t> writePos_;
    std::atomic<size_t> readPos_;
    std::atomic<size_t> underrunCount_;
    mutable size_t logCounter_;
};

// I/O handler that implements loopback
class LoopbackIOHandler : public aspl::IORequestHandler {
public:
    explicit LoopbackIOHandler(std::shared_ptr<LoopbackBuffer> buffer)
        : buffer_(std::move(buffer))
    {}

    // Called when apps write audio to our output
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
                           Float64 zeroTimestamp,
                           Float64 timestamp,
                           const void* bytes,
                           UInt32 bytesCount) override {
        static int writeCount = 0;
        if (writeCount++ < 20) {
            // Log to system log (viewable via Console.app or `log stream`)
            os_log(OS_LOG_DEFAULT, "PCPanel: OnWriteMixedOutput called, bytes=%u", bytesCount);
        }
        // Store the audio in our loopback buffer
        buffer_->write(bytes, bytesCount);
    }

    // Called when something reads from our input
    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
                          const std::shared_ptr<aspl::Stream>& stream,
                          Float64 zeroTimestamp,
                          Float64 timestamp,
                          void* bytes,
                          UInt32 bytesCount) override {
        static int readCount = 0;
        if (readCount++ < 20) {
            os_log(OS_LOG_DEFAULT, "PCPanel: OnReadClientInput called, bytes=%u", bytesCount);
        }
        // Return audio from our loopback buffer
        buffer_->read(bytes, bytesCount);
    }

private:
    std::shared_ptr<LoopbackBuffer> buffer_;
};

// Control handler
class LoopbackControlHandler : public aspl::ControlRequestHandler {
public:
    explicit LoopbackControlHandler(std::shared_ptr<LoopbackBuffer> buffer)
        : buffer_(std::move(buffer))
    {}

    OSStatus OnStartIO() override {
        buffer_->clear();
        return kAudioHardwareNoError;
    }

    void OnStopIO() override {
        // Clear buffer to prevent stale audio from being played back
        buffer_->clear();
    }

private:
    std::shared_ptr<LoopbackBuffer> buffer_;
};

// Custom device with loopback support
class PCPanelDevice : public aspl::Device {
public:
    explicit PCPanelDevice(std::shared_ptr<const aspl::Context> context,
                          const aspl::DeviceParameters& params,
                          int channelIndex)
        : aspl::Device(context, params)
        , channelIndex_(channelIndex)
        , loopbackBuffer_(std::make_shared<LoopbackBuffer>())
    {
        // Set up I/O and control handlers
        auto ioHandler = std::make_shared<LoopbackIOHandler>(loopbackBuffer_);
        auto controlHandler = std::make_shared<LoopbackControlHandler>(loopbackBuffer_);

        SetIOHandler(ioHandler);
        SetControlHandler(controlHandler);

        // Keep references alive
        ioHandler_ = ioHandler;
        controlHandler_ = controlHandler;
    }

    // Return list of supported sample rates - support both 48000 and 44100
    // 48000 is listed first as preferred (modern macOS standard)
    std::vector<AudioValueRange> GetAvailableSampleRates() const override
    {
        return {
            AudioValueRange{48000.0, 48000.0},
            AudioValueRange{44100.0, 44100.0}
        };
    }

    // Override to update stream formats when sample rate changes
    OSStatus SetNominalSampleRateImpl(Float64 rate) override
    {
        os_log(OS_LOG_DEFAULT, "PCPanel: SetNominalSampleRateImpl called with rate=%.0f", rate);

        // Call parent to set the device rate
        OSStatus status = aspl::Device::SetNominalSampleRateImpl(rate);
        if (status != kAudioHardwareNoError) {
            return status;
        }

        // Update all stream formats to match the new sample rate
        for (UInt32 i = 0; i < GetStreamCount(aspl::Direction::Output); i++) {
            auto stream = GetStreamByIndex(aspl::Direction::Output, i);
            if (stream) {
                auto format = stream->GetPhysicalFormat();
                if (format.mSampleRate != rate) {
                    format.mSampleRate = rate;
                    stream->SetPhysicalFormatAsync(format);
                }
            }
        }

        for (UInt32 i = 0; i < GetStreamCount(aspl::Direction::Input); i++) {
            auto stream = GetStreamByIndex(aspl::Direction::Input, i);
            if (stream) {
                auto format = stream->GetPhysicalFormat();
                if (format.mSampleRate != rate) {
                    format.mSampleRate = rate;
                    stream->SetPhysicalFormatAsync(format);
                }
            }
        }

        return kAudioHardwareNoError;
    }

protected:
    // Override to log what IO operations CoreAudio is requesting
    OSStatus WillDoIOOperationImpl(UInt32 clientID,
                                   UInt32 operationID,
                                   Boolean* outWillDo,
                                   Boolean* outWillDoInPlace) override
    {
        static int logCount = 0;
        if (logCount++ < 50) {
            const char* opName = "Unknown";
            switch (operationID) {
                case kAudioServerPlugInIOOperationThread: opName = "Thread"; break;
                case kAudioServerPlugInIOOperationCycle: opName = "Cycle"; break;
                case kAudioServerPlugInIOOperationReadInput: opName = "ReadInput"; break;
                case kAudioServerPlugInIOOperationProcessInput: opName = "ProcessInput"; break;
                case kAudioServerPlugInIOOperationConvertInput: opName = "ConvertInput"; break;
                case kAudioServerPlugInIOOperationProcessOutput: opName = "ProcessOutput"; break;
                case kAudioServerPlugInIOOperationMixOutput: opName = "MixOutput"; break;
                case kAudioServerPlugInIOOperationProcessMix: opName = "ProcessMix"; break;
                case kAudioServerPlugInIOOperationConvertMix: opName = "ConvertMix"; break;
                case kAudioServerPlugInIOOperationWriteMix: opName = "WriteMix"; break;
            }
            os_log(OS_LOG_DEFAULT, "PCPanel: WillDoIOOperation client=%u op=%s(%u)",
                   clientID, opName, operationID);
        }

        // Call parent implementation
        return aspl::Device::WillDoIOOperationImpl(clientID, operationID, outWillDo, outWillDoInPlace);
    }

private:
    int channelIndex_;
    std::shared_ptr<LoopbackBuffer> loopbackBuffer_;
    std::shared_ptr<LoopbackIOHandler> ioHandler_;
    std::shared_ptr<LoopbackControlHandler> controlHandler_;
};

// Global driver instance (must persist for lifetime of plugin)
std::shared_ptr<aspl::Driver> g_driver;

// Device names for 9 channels (5 knobs + 4 sliders)
// K = Knob, S = Slider
constexpr const char* kDeviceNames[] = {
    "PCPanel K1",  // Knob 1 (index 0)
    "PCPanel K2",  // Knob 2 (index 1)
    "PCPanel K3",  // Knob 3 (index 2)
    "PCPanel K4",  // Knob 4 (index 3)
    "PCPanel K5",  // Knob 5 (index 4)
    "PCPanel S1",  // Slider 1 (index 5)
    "PCPanel S2",  // Slider 2 (index 6)
    "PCPanel S3",  // Slider 3 (index 7)
    "PCPanel S4",  // Slider 4 (index 8)
};

constexpr int kNumDevices = 9;

} // anonymous namespace

// Plugin entry point - called by CoreAudio when loading the driver
extern "C" void* PCPanelDriverEntry(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    // Verify this is an audio plugin request
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    // Only create driver once
    if (g_driver) {
        return g_driver->GetReference();
    }

    // Create context (shared state for all driver objects)
    auto context = std::make_shared<aspl::Context>();

    // Create plugin (root of object hierarchy)
    auto plugin = std::make_shared<aspl::Plugin>(context);

    // Create stream format (Float32 stereo for good quality)
    // Use 48000 Hz as modern macOS standard (matches most output devices)
    AudioStreamBasicDescription streamFormat = {
        .mSampleRate = 48000,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBitsPerChannel = 32,
        .mChannelsPerFrame = 2,
        .mBytesPerFrame = 8,
        .mFramesPerPacket = 1,
        .mBytesPerPacket = 8,
    };

    // Create 9 virtual devices (5 knobs + 4 sliders)
    for (int i = 0; i < kNumDevices; i++) {
        aspl::DeviceParameters deviceParams;
        deviceParams.Name = kDeviceNames[i];
        deviceParams.Manufacturer = "PCPanel";
        deviceParams.DeviceUID = std::string("com.pcpanel.audio.device.") + std::to_string(i + 1);
        deviceParams.ModelUID = "com.pcpanel.audio.model";
        deviceParams.SampleRate = 48000;
        deviceParams.ChannelCount = 2;
        deviceParams.EnableMixing = true;
        deviceParams.Latency = 0;
        deviceParams.SafetyOffset = 0;

        auto device = std::make_shared<PCPanelDevice>(context, deviceParams, i);

        // Create output stream with controls (apps write to this)
        aspl::StreamParameters outputStreamParams;
        outputStreamParams.Direction = aspl::Direction::Output;
        outputStreamParams.StartingChannel = 1;
        outputStreamParams.Format = streamFormat;
        device->AddStreamWithControlsAsync(outputStreamParams);

        // Create input stream (passthrough reads from this)
        aspl::StreamParameters inputStreamParams;
        inputStreamParams.Direction = aspl::Direction::Input;
        inputStreamParams.StartingChannel = 1;
        inputStreamParams.Format = streamFormat;
        device->AddStreamAsync(inputStreamParams);

        // Add device to plugin
        plugin->AddDevice(device);

        os_log(OS_LOG_DEFAULT, "PCPanel: Created device %s (index %d)", kDeviceNames[i], i);
    }

    // Create Voice Chat virtual mic device (10th device)
    // This device has both input and output streams:
    // - Apps (like the PCPanel mixer) write to the output stream
    // - Apps (like Discord) read from the input stream as a microphone
    {
        aspl::DeviceParameters vcParams;
        vcParams.Name = "PCPanel Voice Chat";
        vcParams.Manufacturer = "PCPanel";
        vcParams.DeviceUID = "com.pcpanel.audio.voicechat";
        vcParams.ModelUID = "com.pcpanel.audio.model";
        vcParams.SampleRate = 48000;
        vcParams.ChannelCount = 2;
        vcParams.EnableMixing = true;
        vcParams.Latency = 0;
        vcParams.SafetyOffset = 0;

        auto vcDevice = std::make_shared<PCPanelDevice>(context, vcParams, kNumDevices);

        // Output stream (Voice Chat mixer writes to this)
        aspl::StreamParameters vcOutputParams;
        vcOutputParams.Direction = aspl::Direction::Output;
        vcOutputParams.StartingChannel = 1;
        vcOutputParams.Format = streamFormat;
        vcDevice->AddStreamWithControlsAsync(vcOutputParams);

        // Input stream with controls (apps like Discord read from this as microphone)
        aspl::StreamParameters vcInputParams;
        vcInputParams.Direction = aspl::Direction::Input;
        vcInputParams.StartingChannel = 1;
        vcInputParams.Format = streamFormat;
        vcDevice->AddStreamWithControlsAsync(vcInputParams);

        plugin->AddDevice(vcDevice);

        os_log(OS_LOG_DEFAULT, "PCPanel: Created Voice Chat device (virtual mic)");
    }

    // Create driver
    g_driver = std::make_shared<aspl::Driver>(context, plugin);

    os_log(OS_LOG_DEFAULT, "PCPanel: Driver initialized with %d channel devices + Voice Chat", kNumDevices);

    return g_driver->GetReference();
}
