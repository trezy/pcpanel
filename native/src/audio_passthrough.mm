// PC Panel Pro - Audio Passthrough Native Addon
// Routes audio from virtual PCPanel devices to real output device

#include <napi.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstring>
#include <chrono>
#include <cmath>

// =============================================================================
// Simple Linear Interpolation Sample Rate Converter
// =============================================================================
class SampleRateConverter {
public:
    SampleRateConverter(double inputRate, double outputRate, int channels = 2)
        : inputRate_(inputRate)
        , outputRate_(outputRate)
        , channels_(channels)
        , ratio_(inputRate / outputRate)
        , phase_(0.0)
    {
        // Pre-allocate for typical buffer sizes
        lastSamples_.resize(channels, 0.0f);
    }

    // Convert input samples to output sample rate
    // Returns the number of output frames produced
    size_t convert(const float* input, size_t inputFrames, float* output, size_t maxOutputFrames) {
        if (inputRate_ == outputRate_) {
            // No conversion needed
            size_t framesToCopy = std::min(inputFrames, maxOutputFrames);
            memcpy(output, input, framesToCopy * channels_ * sizeof(float));
            return framesToCopy;
        }

        size_t outputFrames = 0;
        size_t inputIdx = 0;

        while (outputFrames < maxOutputFrames && inputIdx < inputFrames) {
            // Calculate which input samples we're interpolating between
            double inputPos = phase_;
            size_t idx0 = static_cast<size_t>(inputPos);
            double frac = inputPos - idx0;

            if (idx0 >= inputFrames) break;

            size_t idx1 = idx0 + 1;
            if (idx1 >= inputFrames) idx1 = idx0;  // Clamp at end

            // Linear interpolation for each channel
            for (int ch = 0; ch < channels_; ch++) {
                float s0 = input[idx0 * channels_ + ch];
                float s1 = input[idx1 * channels_ + ch];
                output[outputFrames * channels_ + ch] = s0 + (s1 - s0) * static_cast<float>(frac);
            }

            outputFrames++;
            phase_ += ratio_;

            // Keep track of how far we've consumed the input
            inputIdx = static_cast<size_t>(phase_);
        }

        // Adjust phase for next call (keep fractional part relative to remaining input)
        phase_ -= inputFrames;
        if (phase_ < 0) phase_ = 0;

        return outputFrames;
    }

    // Reset state
    void reset() {
        phase_ = 0.0;
        std::fill(lastSamples_.begin(), lastSamples_.end(), 0.0f);
    }

    // Calculate how many output frames we'd get for given input frames
    size_t getOutputFrameCount(size_t inputFrames) const {
        if (inputRate_ == outputRate_) return inputFrames;
        return static_cast<size_t>(inputFrames * outputRate_ / inputRate_);
    }

    double getInputRate() const { return inputRate_; }
    double getOutputRate() const { return outputRate_; }

private:
    double inputRate_;
    double outputRate_;
    int channels_;
    double ratio_;
    double phase_;
    std::vector<float> lastSamples_;
};

// Simple lock-free ring buffer for audio passthrough
// No drift compensation - relies on matched sample rates
class RingBuffer {
public:
    RingBuffer(size_t sizeInFrames, UInt32 /* channelCount */, UInt32 bytesPerFrame)
        : capacity_(sizeInFrames * bytesPerFrame)
        , buffer_(capacity_)
        , writePos_(0)
        , readPos_(0)
    {}

    void write(const void* data, size_t bytes) {
        const uint8_t* src = static_cast<const uint8_t*>(data);
        size_t wp = writePos_.load(std::memory_order_relaxed);
        size_t rp = readPos_.load(std::memory_order_acquire);

        // Calculate available space (leave 1 byte to distinguish full from empty)
        size_t used = (wp >= rp) ? (wp - rp) : (capacity_ - rp + wp);
        size_t space = capacity_ - used - 1;

        size_t toWrite = std::min(bytes, space);
        if (toWrite == 0) return;  // Buffer full, drop samples

        size_t writeIdx = wp % capacity_;
        size_t firstChunk = std::min(toWrite, capacity_ - writeIdx);

        memcpy(buffer_.data() + writeIdx, src, firstChunk);
        if (toWrite > firstChunk) {
            memcpy(buffer_.data(), src + firstChunk, toWrite - firstChunk);
        }

        writePos_.store((wp + toWrite) % capacity_, std::memory_order_release);
    }

    size_t read(void* data, size_t bytes) {
        uint8_t* dst = static_cast<uint8_t*>(data);
        size_t wp = writePos_.load(std::memory_order_acquire);
        size_t rp = readPos_.load(std::memory_order_relaxed);

        size_t available = (wp >= rp) ? (wp - rp) : (capacity_ - rp + wp);
        size_t toRead = std::min(bytes, available);

        if (toRead > 0) {
            size_t readIdx = rp % capacity_;
            size_t firstChunk = std::min(toRead, capacity_ - readIdx);

            memcpy(dst, buffer_.data() + readIdx, firstChunk);
            if (toRead > firstChunk) {
                memcpy(dst + firstChunk, buffer_.data(), toRead - firstChunk);
            }

            readPos_.store((rp + toRead) % capacity_, std::memory_order_release);
        }

        // Fill remaining with silence
        if (toRead < bytes) {
            memset(dst + toRead, 0, bytes - toRead);
        }

        return toRead;
    }

    void reset() {
        writePos_.store(0, std::memory_order_relaxed);
        readPos_.store(0, std::memory_order_relaxed);
    }

    size_t getAvailable() const {
        size_t wp = writePos_.load(std::memory_order_relaxed);
        size_t rp = readPos_.load(std::memory_order_relaxed);
        return (wp >= rp) ? (wp - rp) : (capacity_ - rp + wp);
    }

private:
    size_t capacity_;
    std::vector<uint8_t> buffer_;
    std::atomic<size_t> writePos_;
    std::atomic<size_t> readPos_;
};

// Audio passthrough manager
class AudioPassthrough {
public:
    AudioPassthrough()
        : inputDevice_(kAudioObjectUnknown)
        , outputDevice_(kAudioObjectUnknown)
        , inputProcID_(nullptr)
        , outputProcID_(nullptr)
        , running_(false)
        , ringBuffer_(nullptr)
        , volume_(1.0f)
        , lastActivityTime_(0)
    {}

    ~AudioPassthrough() {
        stop();
    }

    bool start(AudioDeviceID inputDevice, AudioDeviceID outputDevice) {
        if (running_) {
            stop();
        }

        inputDevice_ = inputDevice;
        outputDevice_ = outputDevice;

        // Get the output device's sample rate first - this is the rate we need to match
        AudioObjectPropertyAddress propAddr = {
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };

        Float64 outputSampleRate = 0;
        UInt32 propSize = sizeof(outputSampleRate);
        OSStatus status = AudioObjectGetPropertyData(outputDevice_, &propAddr, 0, nullptr,
                                                      &propSize, &outputSampleRate);
        if (status != noErr || outputSampleRate == 0) {
            outputSampleRate = 48000; // Default fallback
        }

        // Get virtual device's current sample rate
        Float64 inputSampleRate = 0;
        propSize = sizeof(inputSampleRate);
        status = AudioObjectGetPropertyData(inputDevice_, &propAddr, 0, nullptr,
                                            &propSize, &inputSampleRate);

        // Set the virtual device's sample rate to match the output device
        if (inputSampleRate != outputSampleRate) {
            Float64 newRate = outputSampleRate;
            propSize = sizeof(newRate);
            AudioObjectSetPropertyData(inputDevice_, &propAddr, 0, nullptr,
                                       propSize, &newRate);
        }

        // Get stream format from the INPUT scope of our virtual device
        AudioStreamBasicDescription inputFormat;
        propSize = sizeof(inputFormat);
        propAddr.mSelector = kAudioDevicePropertyStreamFormat;
        propAddr.mScope = kAudioDevicePropertyScopeInput;

        status = AudioObjectGetPropertyData(inputDevice_, &propAddr, 0, nullptr,
                                            &propSize, &inputFormat);
        if (status != noErr) {
            // Fallback: try output scope if input scope fails
            propAddr.mScope = kAudioDevicePropertyScopeOutput;
            status = AudioObjectGetPropertyData(inputDevice_, &propAddr, 0, nullptr,
                                                &propSize, &inputFormat);
            if (status != noErr) {
                return false;
            }
        }

        // Create ring buffer (2 seconds of audio for more headroom)
        UInt32 bytesPerFrame = inputFormat.mBytesPerFrame;
        if (bytesPerFrame == 0) {
            bytesPerFrame = inputFormat.mChannelsPerFrame * sizeof(Float32);
        }

        ringBuffer_ = std::make_unique<RingBuffer>(
            static_cast<size_t>(outputSampleRate * 2),  // 2 seconds buffer
            inputFormat.mChannelsPerFrame,
            bytesPerFrame
        );

        format_ = inputFormat;

        // Create input IOProc (reads from virtual device)
        status = AudioDeviceCreateIOProcID(inputDevice_, InputIOProc, this, &inputProcID_);
        if (status != noErr) {
            fprintf(stderr, "Failed to create input IOProc (error %d)\n", status);
            return false;
        }

        // Create output IOProc (writes to real device)
        status = AudioDeviceCreateIOProcID(outputDevice_, OutputIOProc, this, &outputProcID_);
        if (status != noErr) {
            AudioDeviceDestroyIOProcID(inputDevice_, inputProcID_);
            inputProcID_ = nullptr;
            fprintf(stderr, "Failed to create output IOProc (error %d)\n", status);
            return false;
        }

        // Start both IOProcs
        status = AudioDeviceStart(inputDevice_, inputProcID_);
        if (status != noErr) {
            AudioDeviceDestroyIOProcID(inputDevice_, inputProcID_);
            AudioDeviceDestroyIOProcID(outputDevice_, outputProcID_);
            inputProcID_ = nullptr;
            outputProcID_ = nullptr;
            fprintf(stderr, "Failed to start input IOProc (error %d)\n", status);
            return false;
        }

        status = AudioDeviceStart(outputDevice_, outputProcID_);
        if (status != noErr) {
            AudioDeviceStop(inputDevice_, inputProcID_);
            AudioDeviceDestroyIOProcID(inputDevice_, inputProcID_);
            AudioDeviceDestroyIOProcID(outputDevice_, outputProcID_);
            inputProcID_ = nullptr;
            outputProcID_ = nullptr;
            fprintf(stderr, "Failed to start output IOProc (error %d)\n", status);
            return false;
        }

        running_ = true;
        return true;
    }

    void stop() {
        if (!running_) {
            return;
        }

        running_ = false;

        if (inputProcID_) {
            AudioDeviceStop(inputDevice_, inputProcID_);
            AudioDeviceDestroyIOProcID(inputDevice_, inputProcID_);
            inputProcID_ = nullptr;
        }

        if (outputProcID_) {
            AudioDeviceStop(outputDevice_, outputProcID_);
            AudioDeviceDestroyIOProcID(outputDevice_, outputProcID_);
            outputProcID_ = nullptr;
        }

        ringBuffer_.reset();
    }

    bool isRunning() const {
        return running_;
    }

    void setVolume(float volume) {
        volume_ = std::max(0.0f, std::min(1.0f, volume));
    }

    float getVolume() const {
        return volume_;
    }

    bool hasAudioActivity() const {
        // Consider audio active if we've seen non-silent audio in the last 500ms
        auto now = std::chrono::steady_clock::now().time_since_epoch().count();
        auto elapsed = now - lastActivityTime_.load();
        // 500ms in nanoseconds
        return elapsed < 500000000LL;
    }

private:
    static OSStatus InputIOProc(AudioObjectID /* device */,
                                 const AudioTimeStamp* /* now */,
                                 const AudioBufferList* inputData,
                                 const AudioTimeStamp* /* inputTime */,
                                 AudioBufferList* /* outputData */,
                                 const AudioTimeStamp* /* outputTime */,
                                 void* clientData) {
        auto* self = static_cast<AudioPassthrough*>(clientData);

        // Read from the INPUT side of the virtual device
        // The driver's loopback puts output audio into the input stream
        if (inputData && inputData->mNumberBuffers > 0) {
            for (UInt32 i = 0; i < inputData->mNumberBuffers; i++) {
                const AudioBuffer& buf = inputData->mBuffers[i];
                if (buf.mData && buf.mDataByteSize > 0) {
                    self->ringBuffer_->write(buf.mData, buf.mDataByteSize);

                    // Check for non-silent audio (any sample above -60dB threshold)
                    const Float32* samples = static_cast<const Float32*>(buf.mData);
                    UInt32 sampleCount = buf.mDataByteSize / sizeof(Float32);
                    for (UInt32 j = 0; j < sampleCount; j++) {
                        if (std::fabs(samples[j]) > 0.001f) {
                            self->lastActivityTime_.store(
                                std::chrono::steady_clock::now().time_since_epoch().count()
                            );
                            break;
                        }
                    }
                }
            }
        }

        return noErr;
    }

    static OSStatus OutputIOProc(AudioObjectID /* device */,
                                  const AudioTimeStamp* /* now */,
                                  const AudioBufferList* /* inputData */,
                                  const AudioTimeStamp* /* inputTime */,
                                  AudioBufferList* outputData,
                                  const AudioTimeStamp* /* outputTime */,
                                  void* clientData) {
        auto* self = static_cast<AudioPassthrough*>(clientData);

        if (outputData && outputData->mNumberBuffers > 0) {
            for (UInt32 i = 0; i < outputData->mNumberBuffers; i++) {
                AudioBuffer& buf = outputData->mBuffers[i];
                if (buf.mData && buf.mDataByteSize > 0) {
                    self->ringBuffer_->read(buf.mData, buf.mDataByteSize);

                    // Apply volume
                    float volume = self->volume_;
                    if (volume < 1.0f) {
                        Float32* samples = static_cast<Float32*>(buf.mData);
                        UInt32 sampleCount = buf.mDataByteSize / sizeof(Float32);
                        for (UInt32 j = 0; j < sampleCount; j++) {
                            samples[j] *= volume;
                        }
                    }
                }
            }
        }

        return noErr;
    }

    AudioDeviceID inputDevice_;
    AudioDeviceID outputDevice_;
    AudioDeviceIOProcID inputProcID_;
    AudioDeviceIOProcID outputProcID_;
    std::atomic<bool> running_;
    std::unique_ptr<RingBuffer> ringBuffer_;
    AudioStreamBasicDescription format_;
    std::atomic<float> volume_;
    std::atomic<int64_t> lastActivityTime_;
};

// Store passthrough instances with their device names for activity lookup
struct PassthroughInfo {
    std::unique_ptr<AudioPassthrough> passthrough;
    std::string deviceName;
    AudioDeviceID inputDeviceId;
};

// Global passthrough instances (one per channel)
std::vector<PassthroughInfo> g_passthroughs;
std::mutex g_mutex;

// Helper function to find device by name
AudioDeviceID findDeviceByName(const std::string& name, bool isOutput) {
    AudioObjectPropertyAddress propAddr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 propSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddr,
                                                      0, nullptr, &propSize);
    if (status != noErr) {
        return kAudioObjectUnknown;
    }

    UInt32 deviceCount = propSize / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> devices(deviceCount);

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddr,
                                        0, nullptr, &propSize, devices.data());
    if (status != noErr) {
        return kAudioObjectUnknown;
    }

    for (AudioDeviceID deviceID : devices) {
        // Check if device has the right direction
        propAddr.mSelector = kAudioDevicePropertyStreams;
        propAddr.mScope = isOutput ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput;

        status = AudioObjectGetPropertyDataSize(deviceID, &propAddr, 0, nullptr, &propSize);
        if (status != noErr || propSize == 0) {
            continue;
        }

        // Get device name
        propAddr.mSelector = kAudioObjectPropertyName;
        propAddr.mScope = kAudioObjectPropertyScopeGlobal;

        CFStringRef deviceName = nullptr;
        propSize = sizeof(deviceName);
        status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nullptr, &propSize, &deviceName);
        if (status != noErr || !deviceName) {
            continue;
        }

        char nameBuf[256];
        if (CFStringGetCString(deviceName, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8)) {
            if (name == nameBuf) {
                CFRelease(deviceName);
                return deviceID;
            }
        }
        CFRelease(deviceName);
    }

    return kAudioObjectUnknown;
}

// Get default output device
AudioDeviceID getDefaultOutputDevice() {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 propSize = sizeof(deviceID);
    AudioObjectPropertyAddress propAddr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddr, 0, nullptr, &propSize, &deviceID);
    return deviceID;
}

// NOTE: App name detection for audio clients is not currently implemented.
// CoreAudio's kAudioDevicePropertyClientList and kAudioHardwarePropertyProcessObjectList
// are not accessible from HAL plugin context. A future phase will implement this
// using a privileged helper daemon with access to private AudioHardwareService APIs.

// ============================================================================
// AudioMixer - BEACN-style multi-input mixer
// Reads from multiple PCPanel devices and mixes to a single output
// ============================================================================

class AudioMixer {
public:
    struct InputChannel {
        AudioDeviceID deviceId;
        std::string name;
        AudioDeviceIOProcID inputProcID;
        std::unique_ptr<RingBuffer> ringBuffer;
        std::unique_ptr<SampleRateConverter> converter;  // For sample rate conversion
        Float64 inputSampleRate;                         // Actual input device sample rate
        std::atomic<float> gain;
        std::atomic<bool> enabled;
        std::atomic<int64_t> lastActivityTime;
        std::atomic<float> peakLevel;      // Peak level (0.0-1.0)
        std::atomic<float> rmsLevel;       // RMS level (0.0-1.0)

        InputChannel()
            : deviceId(kAudioObjectUnknown)
            , inputProcID(nullptr)
            , inputSampleRate(48000.0)
            , gain(1.0f)
            , enabled(true)
            , lastActivityTime(0)
            , peakLevel(0.0f)
            , rmsLevel(0.0f)
        {}

        // Move constructor
        InputChannel(InputChannel&& other) noexcept
            : deviceId(other.deviceId)
            , name(std::move(other.name))
            , inputProcID(other.inputProcID)
            , ringBuffer(std::move(other.ringBuffer))
            , converter(std::move(other.converter))
            , inputSampleRate(other.inputSampleRate)
            , gain(other.gain.load())
            , enabled(other.enabled.load())
            , lastActivityTime(other.lastActivityTime.load())
            , peakLevel(other.peakLevel.load())
            , rmsLevel(other.rmsLevel.load())
        {
            other.deviceId = kAudioObjectUnknown;
            other.inputProcID = nullptr;
        }

        // Move assignment
        InputChannel& operator=(InputChannel&& other) noexcept {
            if (this != &other) {
                deviceId = other.deviceId;
                name = std::move(other.name);
                inputProcID = other.inputProcID;
                ringBuffer = std::move(other.ringBuffer);
                converter = std::move(other.converter);
                inputSampleRate = other.inputSampleRate;
                gain.store(other.gain.load());
                enabled.store(other.enabled.load());
                lastActivityTime.store(other.lastActivityTime.load());
                peakLevel.store(other.peakLevel.load());
                rmsLevel.store(other.rmsLevel.load());
                other.deviceId = kAudioObjectUnknown;
                other.inputProcID = nullptr;
            }
            return *this;
        }
    };

    AudioMixer(const std::string& name)
        : name_(name)
        , outputDevice_(kAudioObjectUnknown)
        , outputProcID_(nullptr)
        , running_(false)
        , masterVolume_(1.0f)
        , outputSampleRate_(48000.0)
    {}

    ~AudioMixer() {
        stop();
    }

    bool addInput(const std::string& deviceName) {
        AudioDeviceID deviceId = findDeviceByName(deviceName, false);
        if (deviceId == kAudioObjectUnknown) {
            deviceId = findDeviceByName(deviceName, true);
        }
        if (deviceId == kAudioObjectUnknown) {
            fprintf(stderr, "[AudioMixer] Device not found: %s\n", deviceName.c_str());
            return false;
        }

        std::lock_guard<std::mutex> lock(mutex_);

        // Check if already added
        for (const auto& ch : inputs_) {
            if (ch.name == deviceName) {
                return true;  // Already exists
            }
        }

        InputChannel channel;
        channel.deviceId = deviceId;
        channel.name = deviceName;
        channel.gain.store(1.0f);
        channel.enabled.store(true);

        inputs_.push_back(std::move(channel));
        fprintf(stderr, "[AudioMixer] Added input: %s (device %u)\n", deviceName.c_str(), deviceId);
        return true;
    }

    bool setInputGain(const std::string& deviceName, float gain) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& ch : inputs_) {
            if (ch.name == deviceName) {
                ch.gain.store(std::max(0.0f, std::min(1.0f, gain)));
                return true;
            }
        }
        return false;
    }

    bool setInputEnabled(const std::string& deviceName, bool enabled) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& ch : inputs_) {
            if (ch.name == deviceName) {
                ch.enabled.store(enabled);
                return true;
            }
        }
        return false;
    }

    void setMasterVolume(float volume) {
        masterVolume_.store(std::max(0.0f, std::min(1.0f, volume)));
    }

    bool setOutput(AudioDeviceID outputDevice) {
        if (running_) {
            fprintf(stderr, "[AudioMixer] Cannot change output while running\n");
            return false;
        }
        outputDevice_ = outputDevice;
        return true;
    }

    bool start() {
        if (running_) {
            return true;
        }

        // Use default output if not set
        if (outputDevice_ == kAudioObjectUnknown) {
            outputDevice_ = getDefaultOutputDevice();
        }
        if (outputDevice_ == kAudioObjectUnknown) {
            fprintf(stderr, "[AudioMixer] No output device\n");
            return false;
        }

        // Get output device's actual sample rate - we'll use this as our target
        AudioObjectPropertyAddress propAddr = {
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        Float64 outputSampleRate = 48000.0;
        UInt32 propSize = sizeof(outputSampleRate);
        AudioObjectGetPropertyData(outputDevice_, &propAddr, 0, nullptr, &propSize, &outputSampleRate);

        fprintf(stderr, "[AudioMixer] Output device %u sample rate: %.0f Hz\n",
                outputDevice_, outputSampleRate);

        // Store output sample rate for use in OutputIOProc
        outputSampleRate_ = outputSampleRate;

        std::lock_guard<std::mutex> lock(mutex_);

        // Set up each input channel
        for (auto& ch : inputs_) {
            // Get the input device's actual sample rate
            Float64 inputSampleRate = 48000.0;
            UInt32 rateSize = sizeof(inputSampleRate);
            AudioObjectGetPropertyData(ch.deviceId, &propAddr, 0, nullptr, &rateSize, &inputSampleRate);

            // Store the input sample rate for this channel
            ch.inputSampleRate = inputSampleRate;

            fprintf(stderr, "[AudioMixer] Input %s sample rate: %.0f Hz\n",
                    ch.name.c_str(), inputSampleRate);

            // Create sample rate converter if rates don't match
            if (inputSampleRate != outputSampleRate) {
                fprintf(stderr, "[AudioMixer] Creating sample rate converter for %s: %.0f -> %.0f Hz\n",
                        ch.name.c_str(), inputSampleRate, outputSampleRate);
                ch.converter = std::make_unique<SampleRateConverter>(inputSampleRate, outputSampleRate, 2);
            } else {
                ch.converter.reset();  // No conversion needed
                fprintf(stderr, "[AudioMixer] No sample rate conversion needed for %s\n", ch.name.c_str());
            }

            // Create ring buffer (10 seconds at stereo Float32)
            // Large buffer to absorb any timing variations between IOProcs
            ch.ringBuffer = std::make_unique<RingBuffer>(
                static_cast<size_t>(inputSampleRate * 10),
                2,  // stereo
                sizeof(Float32) * 2
            );

            // Create input IOProc
            OSStatus status = AudioDeviceCreateIOProcID(ch.deviceId, InputIOProc, this, &ch.inputProcID);
            if (status != noErr) {
                fprintf(stderr, "[AudioMixer] Failed to create input IOProc for %s: %d\n",
                        ch.name.c_str(), status);
                continue;
            }

            // Start input
            status = AudioDeviceStart(ch.deviceId, ch.inputProcID);
            if (status != noErr) {
                fprintf(stderr, "[AudioMixer] Failed to start input for %s: %d\n",
                        ch.name.c_str(), status);
                AudioDeviceDestroyIOProcID(ch.deviceId, ch.inputProcID);
                ch.inputProcID = nullptr;
                continue;
            }

            fprintf(stderr, "[AudioMixer] Started input: %s\n", ch.name.c_str());
        }

        // Create output IOProc
        OSStatus status = AudioDeviceCreateIOProcID(outputDevice_, OutputIOProc, this, &outputProcID_);
        if (status != noErr) {
            fprintf(stderr, "[AudioMixer] Failed to create output IOProc: %d\n", status);
            stopInputs();
            return false;
        }

        // Start output
        status = AudioDeviceStart(outputDevice_, outputProcID_);
        if (status != noErr) {
            fprintf(stderr, "[AudioMixer] Failed to start output: %d\n", status);
            AudioDeviceDestroyIOProcID(outputDevice_, outputProcID_);
            outputProcID_ = nullptr;
            stopInputs();
            return false;
        }

        running_ = true;
        fprintf(stderr, "[AudioMixer] Started successfully\n");
        return true;
    }

    void stop() {
        if (!running_) {
            return;
        }

        running_ = false;

        std::lock_guard<std::mutex> lock(mutex_);

        // Stop output
        if (outputProcID_) {
            AudioDeviceStop(outputDevice_, outputProcID_);
            AudioDeviceDestroyIOProcID(outputDevice_, outputProcID_);
            outputProcID_ = nullptr;
        }

        stopInputs();
        fprintf(stderr, "[AudioMixer] Stopped\n");
    }

    bool isRunning() const { return running_; }
    const std::string& getName() const { return name_; }

    // Get input channel activity info
    bool getInputActivity(const std::string& deviceName) const {
        for (const auto& ch : inputs_) {
            if (ch.name == deviceName) {
                auto now = std::chrono::steady_clock::now().time_since_epoch().count();
                auto elapsed = now - ch.lastActivityTime.load();
                return elapsed < 500000000LL;  // 500ms
            }
        }
        return false;
    }

    // Get all input levels for UI metering
    struct LevelInfo {
        std::string name;
        float peak;
        float rms;
    };

    std::vector<LevelInfo> getLevels() const {
        std::vector<LevelInfo> levels;
        for (const auto& ch : inputs_) {
            LevelInfo info;
            info.name = ch.name;
            info.peak = ch.peakLevel.load(std::memory_order_relaxed);
            info.rms = ch.rmsLevel.load(std::memory_order_relaxed);
            levels.push_back(info);
        }
        return levels;
    }

private:
    void stopInputs() {
        for (auto& ch : inputs_) {
            if (ch.inputProcID) {
                AudioDeviceStop(ch.deviceId, ch.inputProcID);
                AudioDeviceDestroyIOProcID(ch.deviceId, ch.inputProcID);
                ch.inputProcID = nullptr;
            }
            ch.ringBuffer.reset();
        }
    }

    // Input IOProc - called for each input device
    static OSStatus InputIOProc(AudioObjectID device,
                                 const AudioTimeStamp* /* now */,
                                 const AudioBufferList* inputData,
                                 const AudioTimeStamp* /* inputTime */,
                                 AudioBufferList* /* outputData */,
                                 const AudioTimeStamp* /* outputTime */,
                                 void* clientData) {
        auto* self = static_cast<AudioMixer*>(clientData);

        // Find the channel for this device
        InputChannel* channel = nullptr;
        for (auto& ch : self->inputs_) {
            if (ch.deviceId == device) {
                channel = &ch;
                break;
            }
        }

        if (!channel || !channel->ringBuffer || !channel->enabled.load()) {
            return noErr;
        }

        if (inputData && inputData->mNumberBuffers > 0) {
            for (UInt32 i = 0; i < inputData->mNumberBuffers; i++) {
                const AudioBuffer& buf = inputData->mBuffers[i];
                if (buf.mData && buf.mDataByteSize > 0) {
                    channel->ringBuffer->write(buf.mData, buf.mDataByteSize);

                    // Calculate peak and RMS levels
                    const Float32* samples = static_cast<const Float32*>(buf.mData);
                    UInt32 sampleCount = buf.mDataByteSize / sizeof(Float32);

                    float peak = 0.0f;
                    float sumSquares = 0.0f;
                    bool hasAudio = false;

                    for (UInt32 j = 0; j < sampleCount; j++) {
                        float absVal = std::fabs(samples[j]);
                        if (absVal > peak) {
                            peak = absVal;
                        }
                        sumSquares += samples[j] * samples[j];
                        if (absVal > 0.001f) {
                            hasAudio = true;
                        }
                    }

                    // Calculate RMS
                    float rms = sampleCount > 0 ? std::sqrt(sumSquares / sampleCount) : 0.0f;

                    // Store levels (atomic, lock-free)
                    channel->peakLevel.store(peak, std::memory_order_relaxed);
                    channel->rmsLevel.store(rms, std::memory_order_relaxed);

                    // Update activity time if audio detected
                    if (hasAudio) {
                        channel->lastActivityTime.store(
                            std::chrono::steady_clock::now().time_since_epoch().count()
                        );
                    }
                }
            }
        }

        return noErr;
    }

    // Output IOProc - mixes all inputs and writes to output
    static OSStatus OutputIOProc(AudioObjectID /* device */,
                                  const AudioTimeStamp* /* now */,
                                  const AudioBufferList* /* inputData */,
                                  const AudioTimeStamp* /* inputTime */,
                                  AudioBufferList* outputData,
                                  const AudioTimeStamp* /* outputTime */,
                                  void* clientData) {
        auto* self = static_cast<AudioMixer*>(clientData);

        if (!outputData || outputData->mNumberBuffers == 0) {
            return noErr;
        }

        for (UInt32 bufIdx = 0; bufIdx < outputData->mNumberBuffers; bufIdx++) {
            AudioBuffer& outBuf = outputData->mBuffers[bufIdx];
            if (!outBuf.mData || outBuf.mDataByteSize == 0) {
                continue;
            }

            // Clear output buffer
            memset(outBuf.mData, 0, outBuf.mDataByteSize);

            Float32* outSamples = static_cast<Float32*>(outBuf.mData);
            UInt32 outputFrameCount = outBuf.mDataByteSize / sizeof(Float32) / 2;  // stereo frames
            UInt32 outputSampleCount = outputFrameCount * 2;  // total samples

            // Mix all enabled inputs
            for (auto& ch : self->inputs_) {
                if (!ch.enabled.load() || !ch.ringBuffer) {
                    continue;
                }

                float gain = ch.gain.load();

                if (ch.converter) {
                    // Sample rate conversion needed
                    // Calculate how many input frames we need based on the conversion ratio
                    double ratio = ch.inputSampleRate / self->outputSampleRate_;
                    size_t inputFramesNeeded = static_cast<size_t>(outputFrameCount * ratio) + 2;  // +2 for interpolation safety
                    size_t inputBytesNeeded = inputFramesNeeded * 2 * sizeof(Float32);

                    // Read input samples at the input sample rate
                    std::vector<Float32> inputBuffer(inputFramesNeeded * 2);
                    size_t bytesRead = ch.ringBuffer->read(inputBuffer.data(), inputBytesNeeded);
                    if (bytesRead == 0) {
                        continue;
                    }

                    size_t inputFramesRead = bytesRead / (2 * sizeof(Float32));

                    // Convert to output sample rate
                    std::vector<Float32> convertedBuffer(outputFrameCount * 2);
                    size_t convertedFrames = ch.converter->convert(
                        inputBuffer.data(), inputFramesRead,
                        convertedBuffer.data(), outputFrameCount
                    );

                    // Mix converted samples into output with gain
                    size_t samplesToMix = convertedFrames * 2;
                    for (size_t i = 0; i < samplesToMix && i < outputSampleCount; i++) {
                        outSamples[i] += convertedBuffer[i] * gain;
                    }
                } else {
                    // No sample rate conversion needed - direct read
                    std::vector<Float32> tempBuffer(outputSampleCount);
                    size_t bytesRead = ch.ringBuffer->read(tempBuffer.data(), outBuf.mDataByteSize);
                    if (bytesRead == 0) {
                        continue;
                    }

                    UInt32 samplesRead = bytesRead / sizeof(Float32);

                    // Mix into output with gain
                    for (UInt32 i = 0; i < samplesRead && i < outputSampleCount; i++) {
                        outSamples[i] += tempBuffer[i] * gain;
                    }
                }
            }

            // Apply master volume and clipping protection
            float masterVol = self->masterVolume_.load();
            for (UInt32 i = 0; i < outputSampleCount; i++) {
                outSamples[i] *= masterVol;
                // Soft clipping
                if (outSamples[i] > 1.0f) outSamples[i] = 1.0f;
                else if (outSamples[i] < -1.0f) outSamples[i] = -1.0f;
            }
        }

        return noErr;
    }

    std::string name_;
    std::vector<InputChannel> inputs_;
    AudioDeviceID outputDevice_;
    AudioDeviceIOProcID outputProcID_;
    std::atomic<bool> running_;
    std::atomic<float> masterVolume_;
    Float64 outputSampleRate_;  // Output device sample rate
    std::mutex mutex_;
};

// Global mixer instances
std::vector<std::unique_ptr<AudioMixer>> g_mixers;
std::mutex g_mixerMutex;

// ============================================================================
// N-API wrapper functions
// ============================================================================

// N-API wrapper functions
Napi::Value ListAudioDevices(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    AudioObjectPropertyAddress propAddr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 propSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propAddr,
                                                      0, nullptr, &propSize);
    if (status != noErr) {
        return env.Null();
    }

    UInt32 deviceCount = propSize / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> devices(deviceCount);

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propAddr,
                                        0, nullptr, &propSize, devices.data());
    if (status != noErr) {
        return env.Null();
    }

    Napi::Array result = Napi::Array::New(env);
    uint32_t index = 0;

    for (AudioDeviceID deviceID : devices) {
        // Get device name
        propAddr.mSelector = kAudioObjectPropertyName;
        CFStringRef deviceName = nullptr;
        propSize = sizeof(deviceName);
        status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nullptr, &propSize, &deviceName);
        if (status != noErr || !deviceName) {
            continue;
        }

        char nameBuf[256];
        if (!CFStringGetCString(deviceName, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8)) {
            CFRelease(deviceName);
            continue;
        }
        CFRelease(deviceName);

        // Check if has output
        propAddr.mSelector = kAudioDevicePropertyStreams;
        propAddr.mScope = kAudioDevicePropertyScopeOutput;
        status = AudioObjectGetPropertyDataSize(deviceID, &propAddr, 0, nullptr, &propSize);
        bool hasOutput = (status == noErr && propSize > 0);

        // Check if has input
        propAddr.mScope = kAudioDevicePropertyScopeInput;
        status = AudioObjectGetPropertyDataSize(deviceID, &propAddr, 0, nullptr, &propSize);
        bool hasInput = (status == noErr && propSize > 0);

        Napi::Object device = Napi::Object::New(env);
        device.Set("id", Napi::Number::New(env, deviceID));
        device.Set("name", Napi::String::New(env, nameBuf));
        device.Set("hasOutput", Napi::Boolean::New(env, hasOutput));
        device.Set("hasInput", Napi::Boolean::New(env, hasInput));

        result[index++] = device;
    }

    return result;
}

Napi::Value StartPassthrough(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsString()) {
        Napi::TypeError::New(env, "Input device name required").ThrowAsJavaScriptException();
        return env.Null();
    }

    std::string inputName = info[0].As<Napi::String>().Utf8Value();

    // Find device that has INPUT streams (for reading loopback audio)
    AudioDeviceID inputDevice = findDeviceByName(inputName, false);  // false = look for input capability
    if (inputDevice == kAudioObjectUnknown) {
        // Fallback: try finding by output capability (older approach)
        inputDevice = findDeviceByName(inputName, true);
    }
    if (inputDevice == kAudioObjectUnknown) {
        Napi::Error::New(env, "Input device not found: " + inputName).ThrowAsJavaScriptException();
        return env.Null();
    }

    AudioDeviceID outputDevice = getDefaultOutputDevice();
    if (outputDevice == kAudioObjectUnknown) {
        Napi::Error::New(env, "No default output device").ThrowAsJavaScriptException();
        return env.Null();
    }

    // Don't passthrough to itself
    if (inputDevice == outputDevice) {
        return Napi::Boolean::New(env, true);
    }

    std::lock_guard<std::mutex> lock(g_mutex);

    auto passthrough = std::make_unique<AudioPassthrough>();
    if (!passthrough->start(inputDevice, outputDevice)) {
        Napi::Error::New(env, "Failed to start passthrough").ThrowAsJavaScriptException();
        return env.Null();
    }

    PassthroughInfo ptInfo;
    ptInfo.passthrough = std::move(passthrough);
    ptInfo.deviceName = inputName;
    ptInfo.inputDeviceId = inputDevice;
    g_passthroughs.push_back(std::move(ptInfo));
    return Napi::Number::New(env, static_cast<double>(g_passthroughs.size() - 1));
}

Napi::Value StopPassthrough(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsNumber()) {
        Napi::TypeError::New(env, "Passthrough index required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t index = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());

    std::lock_guard<std::mutex> lock(g_mutex);

    if (index >= g_passthroughs.size() || !g_passthroughs[index].passthrough) {
        return Napi::Boolean::New(env, false);
    }

    g_passthroughs[index].passthrough->stop();
    g_passthroughs[index].passthrough.reset();

    return Napi::Boolean::New(env, true);
}

Napi::Value StopAllPassthrough(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    std::lock_guard<std::mutex> lock(g_mutex);

    for (auto& pt : g_passthroughs) {
        if (pt.passthrough) {
            pt.passthrough->stop();
        }
    }
    g_passthroughs.clear();

    return Napi::Boolean::New(env, true);
}

Napi::Value SetPassthroughVolume(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 2 || !info[0].IsNumber() || !info[1].IsNumber()) {
        Napi::TypeError::New(env, "Index and volume required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t index = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());
    float volume = info[1].As<Napi::Number>().FloatValue();

    std::lock_guard<std::mutex> lock(g_mutex);

    if (index >= g_passthroughs.size() || !g_passthroughs[index].passthrough) {
        return Napi::Boolean::New(env, false);
    }

    g_passthroughs[index].passthrough->setVolume(volume);
    return Napi::Boolean::New(env, true);
}

Napi::Value GetDefaultOutputDevice(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    AudioDeviceID deviceID = getDefaultOutputDevice();
    if (deviceID == kAudioObjectUnknown) {
        return env.Null();
    }

    // Get device name
    AudioObjectPropertyAddress propAddr = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFStringRef deviceName = nullptr;
    UInt32 propSize = sizeof(deviceName);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nullptr, &propSize, &deviceName);

    if (status != noErr || !deviceName) {
        return env.Null();
    }

    char nameBuf[256];
    CFStringGetCString(deviceName, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);
    CFRelease(deviceName);

    Napi::Object result = Napi::Object::New(env);
    result.Set("id", Napi::Number::New(env, deviceID));
    result.Set("name", Napi::String::New(env, nameBuf));

    return result;
}

// Get whether a device is currently running (has active audio)
Napi::Value GetDeviceIsRunning(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsNumber()) {
        Napi::TypeError::New(env, "Device ID required").ThrowAsJavaScriptException();
        return env.Null();
    }

    AudioDeviceID deviceID = static_cast<AudioDeviceID>(info[0].As<Napi::Number>().Uint32Value());

    AudioObjectPropertyAddress propAddr = {
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 isRunning = 0;
    UInt32 propSize = sizeof(isRunning);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nullptr, &propSize, &isRunning);

    if (status != noErr) {
        return Napi::Boolean::New(env, false);
    }

    return Napi::Boolean::New(env, isRunning != 0);
}

// Get activity status for all PCPanel devices based on actual audio data
Napi::Value GetDeviceActivity(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    std::lock_guard<std::mutex> lock(g_mutex);

    Napi::Object result = Napi::Object::New(env);

    // Check each passthrough for audio activity
    for (const auto& pt : g_passthroughs) {
        if (pt.passthrough && !pt.deviceName.empty()) {
            Napi::Object deviceInfo = Napi::Object::New(env);
            deviceInfo.Set("id", Napi::Number::New(env, static_cast<double>(pt.inputDeviceId)));
            deviceInfo.Set("name", Napi::String::New(env, pt.deviceName));
            deviceInfo.Set("isActive", Napi::Boolean::New(env, pt.passthrough->hasAudioActivity()));

            // App names not yet implemented - requires privileged helper daemon
            Napi::Array appsArray = Napi::Array::New(env, 0);
            deviceInfo.Set("apps", appsArray);

            result.Set(pt.deviceName, deviceInfo);
        }
    }

    return result;
}

// ============================================================================
// Mixer N-API Functions
// ============================================================================

Napi::Value CreateMixer(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    std::string name = "Mixer";
    if (info.Length() >= 1 && info[0].IsString()) {
        name = info[0].As<Napi::String>().Utf8Value();
    }

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    auto mixer = std::make_unique<AudioMixer>(name);
    g_mixers.push_back(std::move(mixer));

    return Napi::Number::New(env, static_cast<double>(g_mixers.size() - 1));
}

Napi::Value MixerAddInput(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 2 || !info[0].IsNumber() || !info[1].IsString()) {
        Napi::TypeError::New(env, "Mixer handle and device name required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());
    std::string deviceName = info[1].As<Napi::String>().Utf8Value();

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    return Napi::Boolean::New(env, g_mixers[handle]->addInput(deviceName));
}

Napi::Value MixerSetInputGain(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 3 || !info[0].IsNumber() || !info[1].IsString() || !info[2].IsNumber()) {
        Napi::TypeError::New(env, "Mixer handle, device name, and gain required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());
    std::string deviceName = info[1].As<Napi::String>().Utf8Value();
    float gain = info[2].As<Napi::Number>().FloatValue();

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    return Napi::Boolean::New(env, g_mixers[handle]->setInputGain(deviceName, gain));
}

Napi::Value MixerSetInputEnabled(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 3 || !info[0].IsNumber() || !info[1].IsString() || !info[2].IsBoolean()) {
        Napi::TypeError::New(env, "Mixer handle, device name, and enabled required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());
    std::string deviceName = info[1].As<Napi::String>().Utf8Value();
    bool enabled = info[2].As<Napi::Boolean>().Value();

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    return Napi::Boolean::New(env, g_mixers[handle]->setInputEnabled(deviceName, enabled));
}

Napi::Value MixerSetOutput(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 2 || !info[0].IsNumber() || !info[1].IsNumber()) {
        Napi::TypeError::New(env, "Mixer handle and device ID required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());
    AudioDeviceID deviceId = static_cast<AudioDeviceID>(info[1].As<Napi::Number>().Uint32Value());

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    return Napi::Boolean::New(env, g_mixers[handle]->setOutput(deviceId));
}

Napi::Value MixerStart(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsNumber()) {
        Napi::TypeError::New(env, "Mixer handle required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    return Napi::Boolean::New(env, g_mixers[handle]->start());
}

Napi::Value MixerStop(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsNumber()) {
        Napi::TypeError::New(env, "Mixer handle required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    g_mixers[handle]->stop();
    return Napi::Boolean::New(env, true);
}

Napi::Value MixerGetLevels(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsNumber()) {
        Napi::TypeError::New(env, "Mixer handle required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Object::New(env);  // Return empty object
    }

    auto levels = g_mixers[handle]->getLevels();

    // Create result object: { deviceName: { peak, rms } }
    Napi::Object result = Napi::Object::New(env);
    for (const auto& level : levels) {
        Napi::Object channelObj = Napi::Object::New(env);
        channelObj.Set("peak", Napi::Number::New(env, level.peak));
        channelObj.Set("rms", Napi::Number::New(env, level.rms));
        result.Set(level.name, channelObj);
    }

    return result;
}

Napi::Value DestroyMixer(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    if (info.Length() < 1 || !info[0].IsNumber()) {
        Napi::TypeError::New(env, "Mixer handle required").ThrowAsJavaScriptException();
        return env.Null();
    }

    size_t handle = static_cast<size_t>(info[0].As<Napi::Number>().Int32Value());

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    if (handle >= g_mixers.size() || !g_mixers[handle]) {
        return Napi::Boolean::New(env, false);
    }

    g_mixers[handle]->stop();
    g_mixers[handle].reset();
    return Napi::Boolean::New(env, true);
}

Napi::Value StopAllMixers(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();

    std::lock_guard<std::mutex> lock(g_mixerMutex);
    for (auto& mixer : g_mixers) {
        if (mixer) {
            mixer->stop();
        }
    }
    g_mixers.clear();

    return Napi::Boolean::New(env, true);
}

// ============================================================================
// Module Init
// ============================================================================

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    // Passthrough functions
    exports.Set("listAudioDevices", Napi::Function::New(env, ListAudioDevices));
    exports.Set("startPassthrough", Napi::Function::New(env, StartPassthrough));
    exports.Set("stopPassthrough", Napi::Function::New(env, StopPassthrough));
    exports.Set("stopAllPassthrough", Napi::Function::New(env, StopAllPassthrough));
    exports.Set("setPassthroughVolume", Napi::Function::New(env, SetPassthroughVolume));
    exports.Set("getDefaultOutputDevice", Napi::Function::New(env, GetDefaultOutputDevice));
    exports.Set("getDeviceIsRunning", Napi::Function::New(env, GetDeviceIsRunning));
    exports.Set("getDeviceActivity", Napi::Function::New(env, GetDeviceActivity));

    // Mixer functions
    exports.Set("createMixer", Napi::Function::New(env, CreateMixer));
    exports.Set("mixerAddInput", Napi::Function::New(env, MixerAddInput));
    exports.Set("mixerSetInputGain", Napi::Function::New(env, MixerSetInputGain));
    exports.Set("mixerSetInputEnabled", Napi::Function::New(env, MixerSetInputEnabled));
    exports.Set("mixerSetOutput", Napi::Function::New(env, MixerSetOutput));
    exports.Set("mixerStart", Napi::Function::New(env, MixerStart));
    exports.Set("mixerStop", Napi::Function::New(env, MixerStop));
    exports.Set("mixerGetLevels", Napi::Function::New(env, MixerGetLevels));
    exports.Set("destroyMixer", Napi::Function::New(env, DestroyMixer));
    exports.Set("stopAllMixers", Napi::Function::New(env, StopAllMixers));

    return exports;
}

NODE_API_MODULE(pcpanel_audio, Init)
