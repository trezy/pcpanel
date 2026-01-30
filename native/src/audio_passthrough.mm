// PC Panel Pro - Audio Passthrough Native Addon
// Routes audio from virtual PCPanel devices to real output device
// Direct AUHAL connection for low-latency passthrough

#include <napi.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#import <Foundation/Foundation.h>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstring>
#include <chrono>
#include <cmath>

// Logging macro that uses NSLog (appears in Console.app)
#define PCPANEL_LOG(fmt, ...) NSLog(@"[PCPanel Audio] " fmt, ##__VA_ARGS__)

// Helper: Get device's nominal sample rate
static Float64 getDeviceSampleRate(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress propAddr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    Float64 sampleRate = 0;
    UInt32 propSize = sizeof(sampleRate);
    OSStatus status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nullptr, &propSize, &sampleRate);

    if (status != noErr || sampleRate == 0) {
        return 48000.0;  // Fallback
    }
    return sampleRate;
}

// Helper: Set device's sample rate
static bool setDeviceSampleRate(AudioDeviceID deviceID, Float64 sampleRate) {
    AudioObjectPropertyAddress propAddr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    // Check if writable
    Boolean isSettable = false;
    OSStatus status = AudioObjectIsPropertySettable(deviceID, &propAddr, &isSettable);
    if (status != noErr || !isSettable) {
        return false;
    }

    status = AudioObjectSetPropertyData(deviceID, &propAddr, 0, nullptr, sizeof(sampleRate), &sampleRate);
    return status == noErr;
}

// Audio passthrough using direct AUHAL connection
class AudioPassthrough {
public:
    AudioPassthrough()
        : inputDevice_(kAudioObjectUnknown)
        , outputDevice_(kAudioObjectUnknown)
        , auGraph_(nullptr)
        , inputUnit_(nullptr)
        , outputUnit_(nullptr)
        , running_(false)
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

        // Get sample rates from both devices
        Float64 inputSampleRate = getDeviceSampleRate(inputDevice_);
        Float64 outputSampleRate = getDeviceSampleRate(outputDevice_);

        PCPANEL_LOG(@"Input device sample rate: %.0f Hz", inputSampleRate);
        PCPANEL_LOG(@"Output device sample rate: %.0f Hz", outputSampleRate);

        // Try to match sample rates if they differ
        if (inputSampleRate != outputSampleRate) {
            PCPANEL_LOG(@"Sample rate mismatch, attempting to set input device to %.0f Hz", outputSampleRate);
            if (setDeviceSampleRate(inputDevice_, outputSampleRate)) {
                inputSampleRate = outputSampleRate;
                PCPANEL_LOG(@"Successfully set input device sample rate to %.0f Hz", outputSampleRate);
            } else {
                PCPANEL_LOG(@"Warning: Could not set input sample rate - audio may have pitch issues");
            }
        }

        // Create AUGraph
        OSStatus status = NewAUGraph(&auGraph_);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to create AUGraph: %d", (int)status);
            return false;
        }

        // Add input (AUHAL) node for virtual device
        AudioComponentDescription inputDesc = {
            kAudioUnitType_Output,
            kAudioUnitSubType_HALOutput,
            kAudioUnitManufacturer_Apple,
            0, 0
        };
        AUNode inputNode;
        status = AUGraphAddNode(auGraph_, &inputDesc, &inputNode);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to add input node: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Add output (AUHAL) node for real device
        AudioComponentDescription outputDesc = {
            kAudioUnitType_Output,
            kAudioUnitSubType_HALOutput,
            kAudioUnitManufacturer_Apple,
            0, 0
        };
        AUNode outputNode;
        status = AUGraphAddNode(auGraph_, &outputDesc, &outputNode);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to add output node: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Open the graph to get AudioUnit instances
        status = AUGraphOpen(auGraph_);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to open AUGraph: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Get the AudioUnit instances
        status = AUGraphNodeInfo(auGraph_, inputNode, nullptr, &inputUnit_);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to get input unit: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        status = AUGraphNodeInfo(auGraph_, outputNode, nullptr, &outputUnit_);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to get output unit: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Configure input unit (from virtual device)
        // Enable input on the input unit
        UInt32 enableIO = 1;
        status = AudioUnitSetProperty(inputUnit_,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input,
                                       1,  // input element
                                       &enableIO,
                                       sizeof(enableIO));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to enable input IO: %d", (int)status);
        }

        // Disable output on input unit (we're only using it for input)
        enableIO = 0;
        status = AudioUnitSetProperty(inputUnit_,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output,
                                       0,  // output element
                                       &enableIO,
                                       sizeof(enableIO));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to disable output IO on input unit: %d", (int)status);
        }

        // Set the input device
        status = AudioUnitSetProperty(inputUnit_,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       0,
                                       &inputDevice_,
                                       sizeof(inputDevice_));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to set input device: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Set the output device
        status = AudioUnitSetProperty(outputUnit_,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       0,
                                       &outputDevice_,
                                       sizeof(outputDevice_));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to set output device: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Re-read sample rate after setting device (may have changed)
        Float64 sampleRate = getDeviceSampleRate(inputDevice_);

        // Create stream format (use same format for both - 48kHz stereo Float32)
        AudioStreamBasicDescription streamFormat;
        memset(&streamFormat, 0, sizeof(streamFormat));
        streamFormat.mSampleRate = sampleRate;
        streamFormat.mFormatID = kAudioFormatLinearPCM;
        streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        streamFormat.mBitsPerChannel = 32;
        streamFormat.mChannelsPerFrame = 2;
        streamFormat.mFramesPerPacket = 1;
        streamFormat.mBytesPerFrame = 4;
        streamFormat.mBytesPerPacket = 4;

        // Store format for reference
        format_ = streamFormat;

        // Set stream format on the output of the input unit (what we read from input)
        status = AudioUnitSetProperty(inputUnit_,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output,
                                       1,  // input element
                                       &streamFormat,
                                       sizeof(streamFormat));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to set input unit output format: %d", (int)status);
        }

        // Set the format on the input of the output unit
        status = AudioUnitSetProperty(outputUnit_,
                                       kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input,
                                       0,  // output element
                                       &streamFormat,
                                       sizeof(streamFormat));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to set output unit input format: %d", (int)status);
        }

        // Set up render callback on output unit to pull directly from input
        AURenderCallbackStruct outputCallback;
        outputCallback.inputProc = OutputRenderCallback;
        outputCallback.inputProcRefCon = this;
        status = AudioUnitSetProperty(outputUnit_,
                                       kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input,
                                       0,  // output element
                                       &outputCallback,
                                       sizeof(outputCallback));
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to set output render callback: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Initialize the graph
        status = AUGraphInitialize(auGraph_);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to initialize AUGraph: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        // Start the graph
        status = AUGraphStart(auGraph_);
        if (status != noErr) {
            PCPANEL_LOG(@"Failed to start AUGraph: %d", (int)status);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
            return false;
        }

        running_ = true;
        PCPANEL_LOG(@"Audio passthrough started at %.0f Hz", sampleRate);
        return true;
    }

    void stop() {
        if (!running_) {
            return;
        }

        running_ = false;

        if (auGraph_) {
            AUGraphStop(auGraph_);
            AUGraphUninitialize(auGraph_);
            AUGraphClose(auGraph_);
            DisposeAUGraph(auGraph_);
            auGraph_ = nullptr;
        }

        inputUnit_ = nullptr;
        outputUnit_ = nullptr;

        PCPANEL_LOG(@"Audio passthrough stopped");
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
        auto now = std::chrono::steady_clock::now().time_since_epoch().count();
        auto elapsed = now - lastActivityTime_.load();
        return elapsed < 500000000LL;  // 500ms in nanoseconds
    }

private:
    // This callback provides audio to the output unit (pulls directly from input)
    static OSStatus OutputRenderCallback(void* inRefCon,
                                          AudioUnitRenderActionFlags* ioActionFlags,
                                          const AudioTimeStamp* inTimeStamp,
                                          UInt32 inBusNumber,
                                          UInt32 inNumberFrames,
                                          AudioBufferList* ioData) {
        (void)inBusNumber;
        auto* self = static_cast<AudioPassthrough*>(inRefCon);

        // Render directly from the input unit
        OSStatus status = AudioUnitRender(self->inputUnit_,
                                           ioActionFlags,
                                           inTimeStamp,
                                           1,  // input element
                                           inNumberFrames,
                                           ioData);

        if (status != noErr) {
            // Fill with silence on error
            for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
            }
            return noErr;
        }

        // Apply volume and check for activity
        float volume = self->volume_;
        bool foundActivity = false;

        for (UInt32 buf = 0; buf < ioData->mNumberBuffers; buf++) {
            Float32* samples = (Float32*)ioData->mBuffers[buf].mData;
            UInt32 sampleCount = ioData->mBuffers[buf].mDataByteSize / sizeof(Float32);

            for (UInt32 i = 0; i < sampleCount; i++) {
                // Check for activity
                if (!foundActivity && std::fabs(samples[i]) > 0.001f) {
                    foundActivity = true;
                }
                // Apply volume
                samples[i] *= volume;
            }
        }

        if (foundActivity) {
            self->lastActivityTime_.store(
                std::chrono::steady_clock::now().time_since_epoch().count()
            );
        }

        return noErr;
    }

    AudioDeviceID inputDevice_;
    AudioDeviceID outputDevice_;
    AUGraph auGraph_;
    AudioUnit inputUnit_;
    AudioUnit outputUnit_;
    AudioStreamBasicDescription format_;
    std::atomic<bool> running_;
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

    PCPANEL_LOG(@"Starting passthrough for device: %s", inputName.c_str());

    // Find device that has INPUT streams (for reading loopback audio)
    AudioDeviceID inputDevice = findDeviceByName(inputName, false);  // false = look for input capability
    if (inputDevice == kAudioObjectUnknown) {
        // Fallback: try finding by output capability (older approach)
        inputDevice = findDeviceByName(inputName, true);
    }
    if (inputDevice == kAudioObjectUnknown) {
        PCPANEL_LOG(@"Input device not found: %s", inputName.c_str());
        Napi::Error::New(env, "Input device not found: " + inputName).ThrowAsJavaScriptException();
        return env.Null();
    }

    AudioDeviceID outputDevice = getDefaultOutputDevice();
    if (outputDevice == kAudioObjectUnknown) {
        PCPANEL_LOG(@"No default output device");
        Napi::Error::New(env, "No default output device").ThrowAsJavaScriptException();
        return env.Null();
    }

    // Don't passthrough to itself
    if (inputDevice == outputDevice) {
        PCPANEL_LOG(@"Skipping passthrough - input and output are same device");
        return Napi::Boolean::New(env, true);
    }

    std::lock_guard<std::mutex> lock(g_mutex);

    auto passthrough = std::make_unique<AudioPassthrough>();
    if (!passthrough->start(inputDevice, outputDevice)) {
        PCPANEL_LOG(@"Failed to start passthrough for: %s", inputName.c_str());
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

    PCPANEL_LOG(@"Stopping all passthroughs");

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
