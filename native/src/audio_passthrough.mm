// PC Panel Pro - Audio Passthrough Native Addon
// Routes audio from virtual PCPanel devices to real output device

#include <napi.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstring>
#include <chrono>
#include <cmath>

// Ring buffer for audio passthrough
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
        size_t toWrite = bytes;

        while (toWrite > 0) {
            size_t writeIdx = writePos_.load() % capacity_;
            size_t available = capacity_ - writeIdx;
            size_t chunk = std::min(toWrite, available);

            memcpy(buffer_.data() + writeIdx, src, chunk);

            src += chunk;
            toWrite -= chunk;
            writePos_.fetch_add(chunk);
        }
    }

    size_t read(void* data, size_t bytes) {
        uint8_t* dst = static_cast<uint8_t*>(data);
        size_t available = writePos_.load() - readPos_.load();
        size_t toRead = std::min(bytes, available);
        size_t totalRead = 0;

        while (totalRead < toRead) {
            size_t readIdx = readPos_.load() % capacity_;
            size_t availableInBuffer = capacity_ - readIdx;
            size_t chunk = std::min(toRead - totalRead, availableInBuffer);

            memcpy(dst + totalRead, buffer_.data() + readIdx, chunk);

            totalRead += chunk;
            readPos_.fetch_add(chunk);
        }

        // Fill remaining with silence
        if (totalRead < bytes) {
            memset(dst + totalRead, 0, bytes - totalRead);
        }

        return totalRead;
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

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("listAudioDevices", Napi::Function::New(env, ListAudioDevices));
    exports.Set("startPassthrough", Napi::Function::New(env, StartPassthrough));
    exports.Set("stopPassthrough", Napi::Function::New(env, StopPassthrough));
    exports.Set("stopAllPassthrough", Napi::Function::New(env, StopAllPassthrough));
    exports.Set("setPassthroughVolume", Napi::Function::New(env, SetPassthroughVolume));
    exports.Set("getDefaultOutputDevice", Napi::Function::New(env, GetDefaultOutputDevice));
    exports.Set("getDeviceIsRunning", Napi::Function::New(env, GetDeviceIsRunning));
    exports.Set("getDeviceActivity", Napi::Function::New(env, GetDeviceActivity));
    return exports;
}

NODE_API_MODULE(pcpanel_audio, Init)
