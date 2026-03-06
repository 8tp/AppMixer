// AppMixerDriver - HAL AudioServerPlugIn for per-app volume control
// Minimal virtual audio device that scales per-client output before mixing.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

// ========== Constants ==========

#define kPlugIn_BundleID        "com.appmixer.driver"
#define kDevice_UID             "AppMixerDevice_UID"
#define kDevice_ModelUID        "AppMixerDevice_ModelUID"
#define kDevice_Name            "AppMixer"
#define kDevice_Manufacturer    "AppMixer"
#define kSampleRate             48000.0
#define kBitsPerChannel         32
#define kBytesPerChannel        4
#define kChannelCount           2
#define kBufferFrameSize        512
#define kRingBufferFrames       (kBufferFrameSize * 128) // ~1.4 seconds

// Object IDs
enum {
    kObjectID_PlugIn          = kAudioObjectPlugInObject,
    kObjectID_Device          = 2,
    kObjectID_Stream_Output   = 3,
    kObjectID_Stream_Input    = 4,
    kObjectID_Volume_Control  = 5,
    kObjectID_Mute_Control    = 6,
};

// Shared memory for per-PID volumes
#define kShmPath        "/tmp/appmixer_volumes"
#define kMaxVolEntries  64

#pragma pack(push, 1)
typedef struct {
    int32_t pid;
    float   volume;
} VolEntry;

typedef struct {
    uint32_t count;
    VolEntry entries[kMaxVolEntries];
} ShmVolumes;
#pragma pack(pop)

// ========== Driver State ==========

typedef struct {
    UInt32  clientID;
    pid_t   pid;
} ClientEntry;

#define kMaxClients 256

static struct {
    AudioServerPlugInHostRef host;

    // IO state
    _Atomic bool        ioRunning;
    UInt64              ioAnchorHostTime;
    Float64             hostTicksPerFrame;
    UInt32              ioClientCount;
    UInt64              numberTimeStamps;
    Float64             previousTicks;

    // Ring buffer (output → input loopback) - indexed by sample time like BlackHole
    float               ringBuffer[kRingBufferFrames * kChannelCount];
    Float64             lastOutputSampleTime;
    bool                isBufferClear;

    // Client tracking
    os_unfair_lock      clientLock;
    ClientEntry         clients[kMaxClients];
    UInt32              clientCount;

    // Per-PID volumes (from shared memory)
    ShmVolumes*         shmPtr;
    int                 shmFd;

    // Master volume/mute (controlled by F10/F11/F12)
    Float32             masterVolume;   // 0.0 - 1.0
    UInt32              masterMute;     // 0 or 1
} gState;

// ========== Helpers ==========

static float getVolumeForPID(pid_t pid) {
    if (!gState.shmPtr) return 1.0f;
    ShmVolumes* shm = gState.shmPtr;
    uint32_t count = shm->count;
    if (count > kMaxVolEntries) count = kMaxVolEntries;
    for (uint32_t i = 0; i < count; i++) {
        if (shm->entries[i].pid == (int32_t)pid) {
            float v = shm->entries[i].volume;
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            return v;
        }
    }
    return 1.0f;
}

static pid_t pidForClient(UInt32 clientID) {
    os_unfair_lock_lock(&gState.clientLock);
    for (UInt32 i = 0; i < gState.clientCount; i++) {
        if (gState.clients[i].clientID == clientID) {
            pid_t pid = gState.clients[i].pid;
            os_unfair_lock_unlock(&gState.clientLock);
            return pid;
        }
    }
    os_unfair_lock_unlock(&gState.clientLock);
    return 0;
}

static void openSharedMemory(void) {
    gState.shmFd = open(kShmPath, O_RDONLY);
    if (gState.shmFd >= 0) {
        gState.shmPtr = mmap(NULL, sizeof(ShmVolumes), PROT_READ, MAP_SHARED, gState.shmFd, 0);
        if (gState.shmPtr == MAP_FAILED) gState.shmPtr = NULL;
    }
}

// ========== Driver Interface Implementation ==========

static HRESULT AppMixer_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        *outInterface = inDriver;
        result = S_OK;
    }
    CFRelease(requestedUUID);
    return result;
}

static ULONG AppMixer_AddRef(void* inDriver) { return 1; }
static ULONG AppMixer_Release(void* inDriver) { return 1; }

// ---- Initialize ----

static OSStatus AppMixer_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gState.host = inHost;
    gState.clientLock = OS_UNFAIR_LOCK_INIT;

    // Calculate timing
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 nsPerTick = (Float64)timebase.numer / (Float64)timebase.denom;
    Float64 nsPerFrame = 1000000000.0 / kSampleRate;
    gState.hostTicksPerFrame = nsPerFrame / nsPerTick;

    gState.masterVolume = 1.0f;
    gState.masterMute = 0;

    openSharedMemory();
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc,
    const AudioServerPlugInClientInfo* ci, AudioObjectID* outID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AppMixer_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID devID) {
    return kAudioHardwareUnsupportedOperationError;
}

// ---- Client Management ----

static OSStatus AppMixer_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID devID,
    const AudioServerPlugInClientInfo* ci) {
    os_unfair_lock_lock(&gState.clientLock);
    if (gState.clientCount < kMaxClients) {
        gState.clients[gState.clientCount].clientID = ci->mClientID;
        gState.clients[gState.clientCount].pid = ci->mProcessID;
        gState.clientCount++;
    }
    os_unfair_lock_unlock(&gState.clientLock);
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID devID,
    const AudioServerPlugInClientInfo* ci) {
    os_unfair_lock_lock(&gState.clientLock);
    for (UInt32 i = 0; i < gState.clientCount; i++) {
        if (gState.clients[i].clientID == ci->mClientID) {
            gState.clients[i] = gState.clients[gState.clientCount - 1];
            gState.clientCount--;
            break;
        }
    }
    os_unfair_lock_unlock(&gState.clientLock);
    return kAudioHardwareNoError;
}

// ---- IO Operations ----

static OSStatus AppMixer_StartIO(AudioServerPlugInDriverRef d, AudioObjectID devID, UInt32 clientID) {
    if (!atomic_load(&gState.ioRunning)) {
        gState.numberTimeStamps = 0;
        gState.previousTicks = 0;
        gState.ioAnchorHostTime = mach_absolute_time();
        gState.lastOutputSampleTime = 0;
        gState.isBufferClear = true;
        memset(gState.ringBuffer, 0, sizeof(gState.ringBuffer));
        atomic_store(&gState.ioRunning, true);

        // Re-open shared memory if not open
        if (!gState.shmPtr) openSharedMemory();
    }
    gState.ioClientCount++;
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_StopIO(AudioServerPlugInDriverRef d, AudioObjectID devID, UInt32 clientID) {
    if (gState.ioClientCount > 0) gState.ioClientCount--;
    if (gState.ioClientCount == 0) {
        atomic_store(&gState.ioRunning, false);
    }
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID devID,
    UInt32 clientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    // BlackHole-style timestamp tracking: advance when wrapping around the ring buffer
    UInt64 currentHostTime = mach_absolute_time();
    Float64 ticksPerRingBuffer = gState.hostTicksPerFrame * (Float64)kRingBufferFrames;
    Float64 nextTickOffset = gState.previousTicks + ticksPerRingBuffer;
    UInt64 nextHostTime = gState.ioAnchorHostTime + (UInt64)nextTickOffset;

    if (nextHostTime <= currentHostTime) {
        gState.numberTimeStamps++;
        gState.previousTicks = nextTickOffset;
    }

    *outSampleTime = gState.numberTimeStamps * kRingBufferFrames;
    *outHostTime = gState.ioAnchorHostTime + (UInt64)gState.previousTicks;
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID devID,
    UInt32 clientID, UInt32 opID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    *outWillDo = false;
    *outWillDoInPlace = true;

    switch (opID) {
        case kAudioServerPlugInIOOperationProcessOutput:
            // Per-client volume scaling
            *outWillDo = true;
            break;
        case kAudioServerPlugInIOOperationWriteMix:
            // Write mixed data to ring buffer
            *outWillDo = true;
            break;
        case kAudioServerPlugInIOOperationReadInput:
            // Read from ring buffer for input
            *outWillDo = true;
            break;
    }
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID devID,
    UInt32 clientID, UInt32 opID, UInt32 frameCount,
    const AudioServerPlugInIOCycleInfo* cycleInfo) {
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID devID,
    AudioObjectID streamID, UInt32 clientID, UInt32 opID, UInt32 frameCount,
    const AudioServerPlugInIOCycleInfo* cycleInfo, void* mainBuf, void* secondaryBuf) {

    // Calculate ring buffer position from sample time (like BlackHole)
    UInt64 mSampleTime = (opID == kAudioServerPlugInIOOperationReadInput)
        ? cycleInfo->mInputTime.mSampleTime
        : cycleInfo->mOutputTime.mSampleTime;
    UInt32 ringStart = (UInt32)(mSampleTime % kRingBufferFrames);
    UInt32 firstPart = kRingBufferFrames - ringStart;
    UInt32 secondPart = 0;
    if (firstPart >= frameCount) {
        firstPart = frameCount;
    } else {
        secondPart = frameCount - firstPart;
    }

    switch (opID) {
        case kAudioServerPlugInIOOperationProcessOutput: {
            // Per-client volume scaling - called once per client before mixing
            pid_t pid = pidForClient(clientID);
            float vol = getVolumeForPID(pid);
            if (vol < 0.999f) {
                float* buf = (float*)mainBuf;
                UInt32 sampleCount = frameCount * kChannelCount;
                for (UInt32 i = 0; i < sampleCount; i++) {
                    buf[i] *= vol;
                }
            }
            break;
        }
        case kAudioServerPlugInIOOperationWriteMix: {
            // Write mixed output to ring buffer (from apps to BlackHole-style loopback)
            memcpy(gState.ringBuffer + ringStart * kChannelCount,
                   mainBuf, firstPart * kChannelCount * sizeof(float));
            if (secondPart > 0) {
                memcpy(gState.ringBuffer,
                       (float*)mainBuf + firstPart * kChannelCount,
                       secondPart * kChannelCount * sizeof(float));
            }
            gState.lastOutputSampleTime = mSampleTime + frameCount;
            gState.isBufferClear = false;
            break;
        }
        case kAudioServerPlugInIOOperationReadInput: {
            // Read from ring buffer (input side)
            float* buf = (float*)mainBuf;
            if (gState.lastOutputSampleTime - frameCount < cycleInfo->mInputTime.mSampleTime
                || gState.isBufferClear) {
                // No data available yet - output silence
                memset(buf, 0, frameCount * kChannelCount * sizeof(float));
            } else {
                memcpy(buf, gState.ringBuffer + ringStart * kChannelCount,
                       firstPart * kChannelCount * sizeof(float));
                if (secondPart > 0) {
                    memcpy(buf + firstPart * kChannelCount,
                           gState.ringBuffer,
                           secondPart * kChannelCount * sizeof(float));
                }
            }
            break;
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID devID,
    UInt32 clientID, UInt32 opID, UInt32 frameCount,
    const AudioServerPlugInIOCycleInfo* cycleInfo) {
    return kAudioHardwareNoError;
}

// ---- Configuration Change ----

static OSStatus AppMixer_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d,
    AudioObjectID devID, UInt64 action, void* data) {
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d,
    AudioObjectID devID, UInt64 action, void* data) {
    return kAudioHardwareNoError;
}

// ========== Property Implementation ==========

static Boolean AppMixer_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID objID,
    pid_t clientPID, const AudioObjectPropertyAddress* addr) {
    switch (objID) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                case kAudioPlugInPropertyResourceBundle:
                    return true;
            }
            break;

        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyRelatedDevices:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertyStreams:
                case kAudioObjectPropertyControlList:
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyIcon:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyClockIsStable:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyBufferFrameSizeRange:
                case kAudioDevicePropertyStreamConfiguration:
                    return true;
            }
            break;

        case kObjectID_Stream_Output:
        case kObjectID_Stream_Input:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    return true;
            }
            break;

        case kObjectID_Volume_Control:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                    return true;
            }
            break;

        case kObjectID_Mute_Control:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioBooleanControlPropertyValue:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                    return true;
            }
            break;
    }
    return false;
}

static OSStatus AppMixer_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID objID,
    pid_t clientPID, const AudioObjectPropertyAddress* addr, Boolean* outSettable) {
    *outSettable = false;
    if (objID == kObjectID_Volume_Control) {
        if (addr->mSelector == kAudioLevelControlPropertyScalarValue ||
            addr->mSelector == kAudioLevelControlPropertyDecibelValue) {
            *outSettable = true;
        }
    } else if (objID == kObjectID_Mute_Control) {
        if (addr->mSelector == kAudioBooleanControlPropertyValue) {
            *outSettable = true;
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID objID,
    pid_t clientPID, const AudioObjectPropertyAddress* addr,
    UInt32 qualifierSize, const void* qualifier, UInt32* outSize) {

    switch (objID) {
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:         *outSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:             *outSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:             *outSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer:      *outSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:      *outSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyDeviceList:         *outSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyResourceBundle:    *outSize = sizeof(CFStringRef); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyBufferFrameSize:
                    *outSize = sizeof(UInt32); break;
                case kAudioObjectPropertyOwnedObjects:
                    *outSize = 4 * sizeof(AudioObjectID); break;

                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outSize = sizeof(CFStringRef); break;

                case kAudioDevicePropertyTransportType:     *outSize = sizeof(UInt32); break;
                case kAudioDevicePropertyRelatedDevices:    *outSize = sizeof(AudioObjectID); break;
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyClockIsStable:
                    *outSize = sizeof(UInt32); break;

                case kAudioDevicePropertyStreams:
                    *outSize = sizeof(AudioObjectID) *
                        (addr->mScope == kAudioObjectPropertyScopeInput ? 1 :
                         addr->mScope == kAudioObjectPropertyScopeOutput ? 1 : 2);
                    break;

                case kAudioObjectPropertyControlList:
                    *outSize = 2 * sizeof(AudioObjectID); break;
                case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); break;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outSize = sizeof(AudioValueRange); break;
                case kAudioDevicePropertyIcon:              *outSize = sizeof(CFURLRef); break;
                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outSize = sizeof(AudioValueRange); break;
                case kAudioDevicePropertyStreamConfiguration: {
                    // One buffer with kChannelCount channels
                    *outSize = offsetof(AudioBufferList, mBuffers[1]);
                    break;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Stream_Output:
        case kObjectID_Stream_Input:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                case kAudioStreamPropertyIsActive:
                    *outSize = sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outSize = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outSize = sizeof(AudioStreamRangedDescription); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Volume_Control:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                    *outSize = sizeof(UInt32); break;
                case kAudioObjectPropertyOwnedObjects:
                    *outSize = 0; break;
                case kAudioLevelControlPropertyScalarValue:
                    *outSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelValue:
                    *outSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelRange:
                    *outSize = sizeof(AudioValueRange); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Mute_Control:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                    *outSize = sizeof(UInt32); break;
                case kAudioObjectPropertyOwnedObjects:
                    *outSize = 0; break;
                case kAudioBooleanControlPropertyValue:
                    *outSize = sizeof(UInt32); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        default:
            return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objID,
    pid_t clientPID, const AudioObjectPropertyAddress* addr,
    UInt32 qualifierSize, const void* qualifier, UInt32 inDataSize,
    UInt32* outDataSize, void* outData) {

    // Standard format used everywhere
    AudioStreamBasicDescription fmt = {
        .mSampleRate        = kSampleRate,
        .mFormatID          = kAudioFormatLinearPCM,
        .mFormatFlags       = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket    = kBytesPerChannel * kChannelCount,
        .mFramesPerPacket   = 1,
        .mBytesPerFrame     = kBytesPerChannel * kChannelCount,
        .mChannelsPerFrame  = kChannelCount,
        .mBitsPerChannel    = kBitsPerChannel,
    };

    switch (objID) {
        // ---- Plugin ----
        case kObjectID_PlugIn:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kAudioObjectPlugInObject;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                    *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    CFStringRef uid = *((CFStringRef*)qualifier);
                    if (CFEqual(uid, CFSTR(kDevice_UID)))
                        *((AudioObjectID*)outData) = kObjectID_Device;
                    else
                        *((AudioObjectID*)outData) = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID); break;
                }
                case kAudioPlugInPropertyResourceBundle:
                    *((CFStringRef*)outData) = CFSTR("");
                    *outDataSize = sizeof(CFStringRef); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        // ---- Device ----
        case kObjectID_Device:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kObjectID_PlugIn;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyName:
                    *((CFStringRef*)outData) = CFSTR(kDevice_Name);
                    *outDataSize = sizeof(CFStringRef); break;
                case kAudioObjectPropertyManufacturer:
                    *((CFStringRef*)outData) = CFSTR(kDevice_Manufacturer);
                    *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyDeviceUID:
                    *((CFStringRef*)outData) = CFSTR(kDevice_UID);
                    *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyModelUID:
                    *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID);
                    *outDataSize = sizeof(CFStringRef); break;
                case kAudioDevicePropertyTransportType:
                    *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyRelatedDevices:
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioDevicePropertyClockDomain:
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsAlive:
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceIsRunning:
                    *((UInt32*)outData) = atomic_load(&gState.ioRunning) ? 1 : 0;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyIsHidden:
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyLatency:
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertySafetyOffset:
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyClockIsStable:
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    *((UInt32*)outData) = kRingBufferFrames;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyBufferFrameSize:
                    *((UInt32*)outData) = kBufferFrameSize;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioDevicePropertyBufferFrameSizeRange: {
                    AudioValueRange* r = (AudioValueRange*)outData;
                    r->mMinimum = kBufferFrameSize;
                    r->mMaximum = kBufferFrameSize;
                    *outDataSize = sizeof(AudioValueRange); break;
                }
                case kAudioDevicePropertyStreams: {
                    AudioObjectID* ids = (AudioObjectID*)outData;
                    UInt32 count = 0;
                    if (addr->mScope == kAudioObjectPropertyScopeGlobal ||
                        addr->mScope == kAudioObjectPropertyScopeOutput) {
                        ids[count++] = kObjectID_Stream_Output;
                    }
                    if (addr->mScope == kAudioObjectPropertyScopeGlobal ||
                        addr->mScope == kAudioObjectPropertyScopeInput) {
                        ids[count++] = kObjectID_Stream_Input;
                    }
                    *outDataSize = count * sizeof(AudioObjectID); break;
                }
                case kAudioObjectPropertyControlList: {
                    AudioObjectID* ids = (AudioObjectID*)outData;
                    ids[0] = kObjectID_Volume_Control;
                    ids[1] = kObjectID_Mute_Control;
                    *outDataSize = 2 * sizeof(AudioObjectID); break;
                }
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID* ids = (AudioObjectID*)outData;
                    ids[0] = kObjectID_Stream_Output;
                    ids[1] = kObjectID_Stream_Input;
                    ids[2] = kObjectID_Volume_Control;
                    ids[3] = kObjectID_Mute_Control;
                    *outDataSize = 4 * sizeof(AudioObjectID); break;
                }
                case kAudioDevicePropertyNominalSampleRate:
                    *((Float64*)outData) = kSampleRate;
                    *outDataSize = sizeof(Float64); break;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange* r = (AudioValueRange*)outData;
                    r->mMinimum = kSampleRate;
                    r->mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioValueRange); break;
                }
                case kAudioDevicePropertyStreamConfiguration: {
                    AudioBufferList* abl = (AudioBufferList*)outData;
                    abl->mNumberBuffers = 1;
                    abl->mBuffers[0].mNumberChannels = kChannelCount;
                    abl->mBuffers[0].mDataByteSize = kBufferFrameSize * kBytesPerChannel * kChannelCount;
                    abl->mBuffers[0].mData = NULL;
                    *outDataSize = offsetof(AudioBufferList, mBuffers[1]);
                    break;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        // ---- Streams ----
        case kObjectID_Stream_Output:
        case kObjectID_Stream_Input:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioStreamPropertyIsActive:
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyDirection:
                    *((UInt32*)outData) = (objID == kObjectID_Stream_Output) ? 0 : 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyTerminalType:
                    *((UInt32*)outData) = (objID == kObjectID_Stream_Output)
                        ? kAudioStreamTerminalTypeSpeaker
                        : kAudioStreamTerminalTypeMicrophone;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyStartingChannel:
                    *((UInt32*)outData) = 1;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyLatency:
                    *((UInt32*)outData) = 0;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *((AudioStreamBasicDescription*)outData) = fmt;
                    *outDataSize = sizeof(AudioStreamBasicDescription); break;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription* rd = (AudioStreamRangedDescription*)outData;
                    rd->mFormat = fmt;
                    rd->mSampleRateRange.mMinimum = kSampleRate;
                    rd->mSampleRateRange.mMaximum = kSampleRate;
                    *outDataSize = sizeof(AudioStreamRangedDescription); break;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        // ---- Volume Control ----
        case kObjectID_Volume_Control:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioLevelControlClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioVolumeControlClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0; break;
                case kAudioControlPropertyScope:
                    *((UInt32*)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioControlPropertyElement:
                    *((UInt32*)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioLevelControlPropertyScalarValue:
                    *((Float32*)outData) = gState.masterVolume;
                    *outDataSize = sizeof(Float32); break;
                case kAudioLevelControlPropertyDecibelValue: {
                    // Convert scalar to dB: -96..0
                    Float32 vol = gState.masterVolume;
                    Float32 dB = (vol > 0.001f) ? (20.0f * log10f(vol)) : -96.0f;
                    if (dB < -96.0f) dB = -96.0f;
                    *((Float32*)outData) = dB;
                    *outDataSize = sizeof(Float32); break;
                }
                case kAudioLevelControlPropertyDecibelRange: {
                    AudioValueRange* r = (AudioValueRange*)outData;
                    r->mMinimum = -96.0;
                    r->mMaximum = 0.0;
                    *outDataSize = sizeof(AudioValueRange); break;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        // ---- Mute Control ----
        case kObjectID_Mute_Control:
            switch (addr->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *((AudioClassID*)outData) = kAudioBooleanControlClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyClass:
                    *((AudioClassID*)outData) = kAudioMuteControlClassID;
                    *outDataSize = sizeof(AudioClassID); break;
                case kAudioObjectPropertyOwner:
                    *((AudioObjectID*)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID); break;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0; break;
                case kAudioControlPropertyScope:
                    *((UInt32*)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioControlPropertyElement:
                    *((UInt32*)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(UInt32); break;
                case kAudioBooleanControlPropertyValue:
                    *((UInt32*)outData) = gState.masterMute;
                    *outDataSize = sizeof(UInt32); break;
                default: return kAudioHardwareUnknownPropertyError;
            }
            break;

        default:
            return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus AppMixer_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID objID,
    pid_t clientPID, const AudioObjectPropertyAddress* addr,
    UInt32 qualifierSize, const void* qualifier, UInt32 dataSize, const void* data) {

    if (objID == kObjectID_Volume_Control) {
        switch (addr->mSelector) {
            case kAudioLevelControlPropertyScalarValue: {
                Float32 vol = *((const Float32*)data);
                if (vol < 0.0f) vol = 0.0f;
                if (vol > 1.0f) vol = 1.0f;
                gState.masterVolume = vol;
                // Notify property changed
                AudioObjectPropertyAddress changed = {
                    kAudioLevelControlPropertyScalarValue,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                gState.host->PropertiesChanged(gState.host, kObjectID_Volume_Control, 1, &changed);
                return kAudioHardwareNoError;
            }
            case kAudioLevelControlPropertyDecibelValue: {
                Float32 dB = *((const Float32*)data);
                if (dB < -96.0f) dB = -96.0f;
                if (dB > 0.0f) dB = 0.0f;
                gState.masterVolume = powf(10.0f, dB / 20.0f);
                AudioObjectPropertyAddress changed = {
                    kAudioLevelControlPropertyScalarValue,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                gState.host->PropertiesChanged(gState.host, kObjectID_Volume_Control, 1, &changed);
                return kAudioHardwareNoError;
            }
        }
    } else if (objID == kObjectID_Mute_Control) {
        if (addr->mSelector == kAudioBooleanControlPropertyValue) {
            gState.masterMute = *((const UInt32*)data) ? 1 : 0;
            AudioObjectPropertyAddress changed = {
                kAudioBooleanControlPropertyValue,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            gState.host->PropertiesChanged(gState.host, kObjectID_Mute_Control, 1, &changed);
            return kAudioHardwareNoError;
        }
    }

    return kAudioHardwareUnsupportedOperationError;
}

// ========== Driver Interface Struct ==========

static AudioServerPlugInDriverInterface gDriverInterface = {
    // IUnknown
    NULL, // _reserved
    AppMixer_QueryInterface,
    AppMixer_AddRef,
    AppMixer_Release,
    // Driver
    AppMixer_Initialize,
    AppMixer_CreateDevice,
    AppMixer_DestroyDevice,
    AppMixer_AddDeviceClient,
    AppMixer_RemoveDeviceClient,
    AppMixer_PerformDeviceConfigurationChange,
    AppMixer_AbortDeviceConfigurationChange,
    AppMixer_HasProperty,
    AppMixer_IsPropertySettable,
    AppMixer_GetPropertyDataSize,
    AppMixer_GetPropertyData,
    AppMixer_SetPropertyData,
    AppMixer_StartIO,
    AppMixer_StopIO,
    AppMixer_GetZeroTimeStamp,
    AppMixer_WillDoIOOperation,
    AppMixer_BeginIOOperation,
    AppMixer_DoIOOperation,
    AppMixer_EndIOOperation,
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

// ========== Entry Point ==========

void* AppMixerDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}
