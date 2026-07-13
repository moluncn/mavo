#include "CUACProbe.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/audio/IOAudioDefines.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAVO_UAC_TARGET_RATE 8000.0
#define MAVO_UAC_TEXT_CAPACITY 512U
#define MAVO_UAC_ERROR_CAPACITY 4096U
#define MAVO_UAC_SIGNAL_THRESHOLD_PCM16 256U
#define MAVO_UAC_PCM_RING_FRAMES 2048U
#define MAVO_UAC_CONVERSION_CHUNK_FRAMES 256U

typedef enum {
    MAVO_UAC_SAMPLES_UNSUPPORTED = 0,
    MAVO_UAC_SAMPLES_FLOAT32 = 1,
    MAVO_UAC_SAMPLES_INT16_NATIVE = 2,
    MAVO_UAC_SAMPLES_INT16_SWAPPED = 3
} UACSampleKind;

typedef struct {
    int16_t frames[MAVO_UAC_PCM_RING_FRAMES];
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic uint64_t dropped_frames;
} UACPCMRing;

typedef struct {
    AudioObjectID device_id;
    AudioDeviceIOProcID io_proc_id;
    char name[MAVO_UAC_TEXT_CAPACITY];
    char uid[MAVO_UAC_TEXT_CAPACITY];
    double original_sample_rate;
    double sample_rate;
    uint32_t channels;
    uint32_t buffer_frames;
    uint32_t bytes_per_frame;
    AudioStreamBasicDescription virtual_format;
    UACSampleKind sample_kind;
    uint16_t usb_vendor_id;
    uint16_t usb_product_id;
    uint32_t usb_location_id;
    uint64_t usb_ancestor_entry_id;
    int sample_rate_changed;
    int running;
} UACEndpoint;

struct MaVoUACProbe {
    UACEndpoint input;
    UACEndpoint output;
    char name[MAVO_UAC_TEXT_CAPACITY];
    char uid[MAVO_UAC_TEXT_CAPACITY];
    char last_error[MAVO_UAC_ERROR_CAPACITY];
    double sample_rate;
    uint32_t input_channels;
    uint32_t output_channels;
    int usb_binding_verified;
    _Atomic uint64_t input_callbacks;
    _Atomic uint64_t output_callbacks;
    _Atomic uint64_t input_frames;
    _Atomic uint64_t output_frames;
    _Atomic uint64_t input_bytes;
    _Atomic uint64_t output_bytes;
    _Atomic uint32_t input_peak_pcm16;
    _Atomic uint64_t input_total_samples;
    _Atomic uint64_t input_signal_samples;
    _Atomic uint32_t callbacks_in_flight;
    _Atomic uint64_t callback_sequence;
    UACPCMRing downlink_ring;
    UACPCMRing uplink_ring;
    _Atomic int uplink_flush_requested;
};

typedef struct {
    int available;
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;
    uint64_t ancestor_entry_id;
    int verified_from_uid_location;
} USBIdentity;

typedef struct {
    AudioObjectID device_id;
    char name[MAVO_UAC_TEXT_CAPACITY];
    char uid[MAVO_UAC_TEXT_CAPACITY];
    uint32_t input_channels;
    uint32_t output_channels;
    double sample_rate;
    USBIdentity usb;
    int supports_target_rate;
} UACCandidate;

static void clear_error(MaVoUACProbe *probe) {
    if (probe != NULL) {
        probe->last_error[0] = '\0';
    }
}

static void set_error(MaVoUACProbe *probe, const char *format, ...) {
    if (probe == NULL) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(probe->last_error, sizeof(probe->last_error), format, arguments);
    va_end(arguments);
}

static void append_text(char *output, size_t capacity, const char *format, ...) {
    if (output == NULL || capacity == 0) {
        return;
    }
    size_t used = strnlen(output, capacity);
    if (used >= capacity - 1) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(output + used, capacity - used, format, arguments);
    va_end(arguments);
}

static void osstatus_text(OSStatus status, char *output, size_t capacity) {
    uint32_t value = (uint32_t)status;
    unsigned char bytes[4] = {
        (unsigned char)((value >> 24) & 0xFFU),
        (unsigned char)((value >> 16) & 0xFFU),
        (unsigned char)((value >> 8) & 0xFFU),
        (unsigned char)(value & 0xFFU)
    };
    int printable = 1;
    for (size_t index = 0; index < 4; index++) {
        if (bytes[index] < 0x20U || bytes[index] > 0x7EU) {
            printable = 0;
        }
    }
    if (printable) {
        snprintf(
            output,
            capacity,
            "'%c%c%c%c' (%d)",
            bytes[0], bytes[1], bytes[2], bytes[3], (int)status
        );
    } else {
        snprintf(output, capacity, "%d (0x%08X)", (int)status, value);
    }
}

static AudioObjectPropertyAddress property_address(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope
) {
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    return address;
}

static int uint32_property(
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    uint32_t *value
) {
    AudioObjectPropertyAddress address = property_address(selector, scope);
    UInt32 size = (UInt32)sizeof(*value);
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value) == noErr;
}

static int double_property(
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    double *value
) {
    AudioObjectPropertyAddress address = property_address(selector, scope);
    UInt32 size = (UInt32)sizeof(*value);
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value) == noErr;
}

static int string_property(
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    char *output,
    size_t capacity
) {
    if (output == NULL || capacity == 0) {
        return 0;
    }
    output[0] = '\0';
    AudioObjectPropertyAddress address = property_address(
        selector,
        kAudioObjectPropertyScopeGlobal
    );
    CFStringRef value = NULL;
    UInt32 size = (UInt32)sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(
        object,
        &address,
        0,
        NULL,
        &size,
        &value
    );
    if (status != noErr || value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        if (value != NULL) {
            CFRelease(value);
        }
        return 0;
    }
    Boolean converted = CFStringGetCString(
        value,
        output,
        (CFIndex)capacity,
        kCFStringEncodingUTF8
    );
    CFRelease(value);
    return converted ? 1 : 0;
}

static uint32_t channel_count(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = property_address(
        kAudioDevicePropertyStreamConfiguration,
        scope
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr ||
        size < offsetof(AudioBufferList, mBuffers)) {
        return 0;
    }
    AudioBufferList *buffers = calloc(1, size);
    if (buffers == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers) != noErr) {
        free(buffers);
        return 0;
    }
    uint32_t count = 0;
    for (UInt32 index = 0; index < buffers->mNumberBuffers; index++) {
        count += buffers->mBuffers[index].mNumberChannels;
    }
    free(buffers);
    return count;
}

static int virtual_format(
    AudioObjectID device,
    AudioObjectPropertyScope scope,
    AudioStreamBasicDescription *format
) {
    if (format == NULL) {
        return 0;
    }
    memset(format, 0, sizeof(*format));
    AudioObjectPropertyAddress streams_address = property_address(
        kAudioDevicePropertyStreams,
        scope
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &streams_address, 0, NULL, &size) != noErr ||
        size != sizeof(AudioStreamID)) {
        return 0;
    }
    AudioStreamID *streams = calloc(1, size);
    if (streams == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(
            device,
            &streams_address,
            0,
            NULL,
            &size,
            streams
        ) != noErr) {
        free(streams);
        return 0;
    }
    AudioStreamID stream = streams[0];
    free(streams);

    AudioObjectPropertyAddress format_address = property_address(
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal
    );
    size = (UInt32)sizeof(*format);
    if (AudioObjectGetPropertyData(
            stream,
            &format_address,
            0,
            NULL,
            &size,
            format
        ) != noErr) {
        return 0;
    }
    return 1;
}

static UACSampleKind sample_kind_for_format(
    const AudioStreamBasicDescription *format
) {
    if (format == NULL || format->mFormatID != kAudioFormatLinearPCM ||
        format->mChannelsPerFrame != 1) {
        return MAVO_UAC_SAMPLES_UNSUPPORTED;
    }
    if ((format->mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 &&
        format->mBitsPerChannel == 32 &&
        format->mBytesPerFrame == sizeof(float)) {
        return MAVO_UAC_SAMPLES_FLOAT32;
    }
    if ((format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
        (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0 &&
        format->mBitsPerChannel == 16 &&
        format->mBytesPerFrame == sizeof(int16_t)) {
        return (format->mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
            ? MAVO_UAC_SAMPLES_INT16_NATIVE
            : MAVO_UAC_SAMPLES_INT16_SWAPPED;
    }
    return MAVO_UAC_SAMPLES_UNSUPPORTED;
}

static int available_rate_includes(AudioObjectID device, double wanted) {
    AudioObjectPropertyAddress address = property_address(
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr ||
        size < sizeof(AudioValueRange)) {
        double current = 0;
        return double_property(
            device,
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            &current
        ) && fabs(current - wanted) < 0.5;
    }
    AudioValueRange *ranges = calloc(1, size);
    if (ranges == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, ranges) != noErr) {
        free(ranges);
        return 0;
    }
    size_t count = size / sizeof(AudioValueRange);
    int included = 0;
    for (size_t index = 0; index < count; index++) {
        if (ranges[index].mMinimum <= wanted && wanted <= ranges[index].mMaximum) {
            included = 1;
            break;
        }
    }
    free(ranges);
    return included;
}

static int registry_integer_direct(
    io_registry_entry_t entry,
    CFStringRef key,
    uint32_t *value
) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(
        entry,
        key,
        kCFAllocatorDefault,
        0
    );
    if (property == NULL || CFGetTypeID(property) != CFNumberGetTypeID()) {
        if (property != NULL) {
            CFRelease(property);
        }
        return 0;
    }
    int converted = CFNumberGetValue(
        (CFNumberRef)property,
        kCFNumberSInt32Type,
        value
    );
    CFRelease(property);
    return converted ? 1 : 0;
}

static int is_usb_device_registry_entry(io_registry_entry_t entry) {
    return IOObjectConformsTo(entry, "IOUSBHostDevice") ||
        IOObjectConformsTo(entry, "IOUSBDevice");
}

/* Resolve to the physical USB device, not the first interface that happens to
 * repeat VID/PID/location. Pairing later relies on this device entry ID. */
static USBIdentity usb_identity_for_registry_entry(io_registry_entry_t entry) {
    USBIdentity identity = {0};
    if (entry == IO_OBJECT_NULL || IOObjectRetain(entry) != kIOReturnSuccess) {
        return identity;
    }

    io_registry_entry_t cursor = entry;
    while (cursor != IO_OBJECT_NULL) {
        if (is_usb_device_registry_entry(cursor)) {
            uint32_t vendor = 0;
            uint32_t product = 0;
            uint32_t location = 0;
            uint64_t entry_id = 0;
            if (registry_integer_direct(cursor, CFSTR("idVendor"), &vendor) &&
                registry_integer_direct(cursor, CFSTR("idProduct"), &product) &&
                registry_integer_direct(cursor, CFSTR("locationID"), &location) &&
                IORegistryEntryGetRegistryEntryID(cursor, &entry_id) == kIOReturnSuccess) {
                identity.available = 1;
                identity.vendor_id = (uint16_t)vendor;
                identity.product_id = (uint16_t)product;
                identity.location_id = location;
                identity.ancestor_entry_id = entry_id;
            }
            IOObjectRelease(cursor);
            return identity;
        }

        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t parent_result = IORegistryEntryGetParentEntry(
            cursor,
            kIOServicePlane,
            &parent
        );
        IOObjectRelease(cursor);
        cursor = parent_result == kIOReturnSuccess ? parent : IO_OBJECT_NULL;
    }
    return identity;
}

static USBIdentity usb_identity_for_audio_uid(const char *uid) {
    USBIdentity identity = {0};
    if (uid == NULL || uid[0] == '\0') {
        return identity;
    }
    CFStringRef wanted_uid = CFStringCreateWithCString(
        kCFAllocatorDefault,
        uid,
        kCFStringEncodingUTF8
    );
    if (wanted_uid == NULL) {
        return identity;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching(kIOAudioEngineClassName);
    if (matching == NULL ||
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != kIOReturnSuccess) {
        CFRelease(wanted_uid);
        return identity;
    }

    io_registry_entry_t engine = IO_OBJECT_NULL;
    while ((engine = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef engine_uid = IORegistryEntryCreateCFProperty(
            engine,
            CFSTR(kIOAudioEngineGlobalUniqueIDKey),
            kCFAllocatorDefault,
            0
        );
        int matches = engine_uid != NULL &&
            CFGetTypeID(engine_uid) == CFStringGetTypeID() &&
            CFStringCompare((CFStringRef)engine_uid, wanted_uid, 0) == kCFCompareEqualTo;
        if (engine_uid != NULL) {
            CFRelease(engine_uid);
        }
        if (matches) {
            identity = usb_identity_for_registry_entry(engine);
            IOObjectRelease(engine);
            break;
        }
        IOObjectRelease(engine);
    }
    IOObjectRelease(iterator);
    CFRelease(wanted_uid);
    return identity;
}

static int decimal_usb_interface_suffix(const char *text, uint32_t *interface_number) {
    if (text == NULL || interface_number == NULL || text[0] == '\0') {
        return 0;
    }
    uint32_t value = 0;
    size_t length = 0;
    for (const char *cursor = text; *cursor != '\0'; cursor++) {
        if (*cursor < '0' || *cursor > '9' || length >= 3) {
            return 0;
        }
        value = value * 10U + (uint32_t)(*cursor - '0');
        length++;
    }
    if (value > 255U) {
        return 0;
    }
    char canonical[4] = {0};
    snprintf(canonical, sizeof(canonical), "%u", (unsigned int)value);
    if (strcmp(text, canonical) != 0) {
        return 0;
    }
    *interface_number = value;
    return 1;
}

static int hex_digit_value(char character, uint32_t *value) {
    if (character >= '0' && character <= '9') {
        *value = (uint32_t)(character - '0');
        return 1;
    }
    if (character >= 'a' && character <= 'f') {
        *value = (uint32_t)(character - 'a') + 10U;
        return 1;
    }
    if (character >= 'A' && character <= 'F') {
        *value = (uint32_t)(character - 'A') + 10U;
        return 1;
    }
    return 0;
}

/* AppleUSBAudioEngine UIDs end in :<hex locationID>:<USB interface number>.
 * Parse from the right so manufacturer/product punctuation is never treated
 * as identity. The prefix and both terminal fields must be canonical. */
static int apple_usb_audio_uid_endpoint(
    const char *uid,
    uint32_t *location_id,
    uint32_t *interface_number
) {
    static const char prefix[] = "AppleUSBAudioEngine:";
    if (uid == NULL || location_id == NULL || interface_number == NULL ||
        strncmp(uid, prefix, sizeof(prefix) - 1U) != 0) {
        return 0;
    }

    const char *interface_separator = strrchr(uid, ':');
    uint32_t parsed_interface = 0;
    if (interface_separator == NULL ||
        !decimal_usb_interface_suffix(interface_separator + 1, &parsed_interface)) {
        return 0;
    }
    const char *location_start = interface_separator;
    while (location_start > uid && location_start[-1] != ':') {
        location_start--;
    }
    if (location_start <= uid + sizeof(prefix) - 1U ||
        location_start[-1] != ':') {
        return 0;
    }

    size_t location_length = (size_t)(interface_separator - location_start);
    if (location_length == 0 || location_length > 8) {
        return 0;
    }
    uint32_t parsed = 0;
    for (size_t index = 0; index < location_length; index++) {
        uint32_t nibble = 0;
        if (!hex_digit_value(location_start[index], &nibble)) {
            return 0;
        }
        parsed = parsed * 16U + nibble;
    }
    if (parsed == 0) {
        return 0;
    }
    char canonical_location[9] = {0};
    snprintf(
        canonical_location,
        sizeof(canonical_location),
        "%x",
        (unsigned int)parsed
    );
    if (strlen(canonical_location) != location_length ||
        memcmp(location_start, canonical_location, location_length) != 0) {
        return 0;
    }
    *location_id = parsed;
    *interface_number = parsed_interface;
    return 1;
}

typedef struct {
    unsigned int entries_at_endpoint;
    unsigned int exact_entries;
    USBIdentity exact_identity;
} USBAudioInterfaceScan;

static USBAudioInterfaceScan scan_usb_audio_interface_class(
    const char *class_name,
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t location_id,
    uint32_t interface_number
) {
    USBAudioInterfaceScan scan = {0};
    CFMutableDictionaryRef matching = IOServiceMatching(class_name);
    if (matching == NULL) {
        return scan;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) !=
        kIOReturnSuccess) {
        return scan;
    }

    io_registry_entry_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint32_t observed_vendor = 0;
        uint32_t observed_product = 0;
        uint32_t observed_location = 0;
        uint32_t observed_interface = 0;
        uint32_t interface_class = 0;
        uint32_t interface_subclass = 0;
        if (registry_integer_direct(service, CFSTR("locationID"), &observed_location) &&
            registry_integer_direct(
                service,
                CFSTR("bInterfaceNumber"),
                &observed_interface
            ) &&
            observed_location == location_id && observed_interface == interface_number) {
            scan.entries_at_endpoint++;
            USBIdentity device_identity = usb_identity_for_registry_entry(service);
            if (registry_integer_direct(service, CFSTR("idVendor"), &observed_vendor) &&
                registry_integer_direct(service, CFSTR("idProduct"), &observed_product) &&
                observed_vendor == vendor_id && observed_product == product_id &&
                registry_integer_direct(
                    service,
                    CFSTR("bInterfaceClass"),
                    &interface_class
                ) &&
                registry_integer_direct(
                    service,
                    CFSTR("bInterfaceSubClass"),
                    &interface_subclass
                ) &&
                interface_class == 1U && interface_subclass == 2U &&
                device_identity.available &&
                device_identity.vendor_id == vendor_id &&
                device_identity.product_id == product_id &&
                device_identity.location_id == location_id) {
                scan.exact_entries++;
                scan.exact_identity = device_identity;
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return scan;
}

static USBIdentity verified_usb_audio_interface_identity(
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t location_id,
    uint32_t interface_number
) {
    USBAudioInterfaceScan scan = scan_usb_audio_interface_class(
        "IOUSBHostInterface",
        vendor_id,
        product_id,
        location_id,
        interface_number
    );
    if (scan.entries_at_endpoint == 0) {
        scan = scan_usb_audio_interface_class(
            "IOUSBInterface",
            vendor_id,
            product_id,
            location_id,
            interface_number
        );
    }
    if (scan.entries_at_endpoint != 1 || scan.exact_entries != 1) {
        USBIdentity unavailable = {0};
        return unavailable;
    }
    scan.exact_identity.verified_from_uid_location = 1;
    return scan.exact_identity;
}

static int identity_matches(
    USBIdentity identity,
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t location_id
) {
    return identity.available &&
        identity.vendor_id == vendor_id &&
        identity.product_id == product_id &&
        identity.location_id == location_id;
}

static int identities_share_usb_device(USBIdentity left, USBIdentity right) {
    /* Both identities have been resolved past their interfaces to a physical
     * IOUSBHostDevice/IOUSBDevice. Require that exact common registry object. */
    return left.available && right.available &&
        left.vendor_id == right.vendor_id &&
        left.product_id == right.product_id &&
        left.location_id == right.location_id &&
        left.location_id != 0 &&
        left.ancestor_entry_id != 0 &&
        left.ancestor_entry_id == right.ancestor_entry_id;
}

static int related_devices_contains(AudioObjectID device, AudioObjectID wanted) {
    AudioObjectPropertyAddress address = property_address(
        kAudioDevicePropertyRelatedDevices,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr ||
        size < sizeof(AudioObjectID) || size % sizeof(AudioObjectID) != 0) {
        return 0;
    }
    AudioObjectID *related = calloc(1, size);
    if (related == NULL) {
        return 0;
    }
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, related) != noErr) {
        free(related);
        return 0;
    }
    size_t count = size / sizeof(AudioObjectID);
    int contains = 0;
    for (size_t index = 0; index < count; index++) {
        if (related[index] == wanted) {
            contains = 1;
            break;
        }
    }
    free(related);
    return contains;
}

static int audio_devices_are_mutually_related(
    AudioObjectID input,
    AudioObjectID output
) {
    if (input == output) {
        return 1;
    }
    return related_devices_contains(input, output) &&
        related_devices_contains(output, input);
}

static uint64_t frames_for_buffers(
    const AudioBufferList *buffers,
    uint32_t bytes_per_frame_value,
    uint32_t fallback_frames,
    uint64_t *total_bytes
) {
    uint64_t bytes = 0;
    uint64_t frames = 0;
    if (buffers != NULL) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; index++) {
            const AudioBuffer *buffer = &buffers->mBuffers[index];
            if (buffer->mData == NULL || buffer->mDataByteSize == 0) {
                continue;
            }
            bytes += buffer->mDataByteSize;
            if (bytes_per_frame_value > 0) {
                uint64_t candidate = buffer->mDataByteSize / bytes_per_frame_value;
                if (candidate > frames) {
                    frames = candidate;
                }
            }
        }
    }
    if (frames == 0 && bytes > 0) {
        frames = fallback_frames;
    }
    *total_bytes = bytes;
    return frames;
}

static void pcm_ring_reset(UACPCMRing *ring) {
    if (ring == NULL) {
        return;
    }
    atomic_store_explicit(&ring->read_index, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->write_index, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->dropped_frames, 0, memory_order_relaxed);
}

static size_t pcm_ring_write(
    UACPCMRing *ring,
    const int16_t *frames,
    size_t frame_count
) {
    if (ring == NULL || frames == NULL || frame_count == 0) {
        return 0;
    }
    uint64_t write_index = atomic_load_explicit(
        &ring->write_index,
        memory_order_relaxed
    );
    uint64_t read_index = atomic_load_explicit(
        &ring->read_index,
        memory_order_acquire
    );
    uint64_t used = write_index - read_index;
    if (used > MAVO_UAC_PCM_RING_FRAMES) {
        used = MAVO_UAC_PCM_RING_FRAMES;
    }
    size_t available = (size_t)(MAVO_UAC_PCM_RING_FRAMES - used);
    size_t accepted = frame_count < available ? frame_count : available;
    for (size_t index = 0; index < accepted; index++) {
        ring->frames[(write_index + index) % MAVO_UAC_PCM_RING_FRAMES] = frames[index];
    }
    atomic_store_explicit(
        &ring->write_index,
        write_index + accepted,
        memory_order_release
    );
    if (accepted < frame_count) {
        atomic_fetch_add_explicit(
            &ring->dropped_frames,
            frame_count - accepted,
            memory_order_relaxed
        );
    }
    return accepted;
}

static size_t pcm_ring_read(
    UACPCMRing *ring,
    int16_t *frames,
    size_t maximum_frames
) {
    if (ring == NULL || frames == NULL || maximum_frames == 0) {
        return 0;
    }
    uint64_t read_index = atomic_load_explicit(
        &ring->read_index,
        memory_order_relaxed
    );
    uint64_t write_index = atomic_load_explicit(
        &ring->write_index,
        memory_order_acquire
    );
    uint64_t available64 = write_index - read_index;
    if (available64 > MAVO_UAC_PCM_RING_FRAMES) {
        available64 = MAVO_UAC_PCM_RING_FRAMES;
    }
    size_t available = (size_t)available64;
    size_t copied = maximum_frames < available ? maximum_frames : available;
    for (size_t index = 0; index < copied; index++) {
        frames[index] = ring->frames[(read_index + index) % MAVO_UAC_PCM_RING_FRAMES];
    }
    atomic_store_explicit(
        &ring->read_index,
        read_index + copied,
        memory_order_release
    );
    return copied;
}

/* Only the ring's consumer may discard. This preserves SPSC ownership and
 * prevents a producer from overwriting storage still being read. */
static void pcm_ring_discard_from_consumer(UACPCMRing *ring) {
    if (ring == NULL) {
        return;
    }
    uint64_t write_index = atomic_load_explicit(
        &ring->write_index,
        memory_order_acquire
    );
    atomic_store_explicit(&ring->read_index, write_index, memory_order_release);
}

static void update_input_peak(MaVoUACProbe *probe, uint32_t candidate) {
    uint32_t observed = atomic_load_explicit(
        &probe->input_peak_pcm16,
        memory_order_relaxed
    );
    while (candidate > observed &&
           !atomic_compare_exchange_weak_explicit(
               &probe->input_peak_pcm16,
               &observed,
               candidate,
               memory_order_relaxed,
               memory_order_relaxed
           )) {
    }
}

static uint32_t float32_pcm16_magnitude(const unsigned char *bytes) {
    float sample = 0;
    memcpy(&sample, bytes, sizeof(sample));
    if (!isfinite(sample)) {
        return 0;
    }
    float magnitude = fabsf(sample);
    if (magnitude >= 1.0f) {
        return 32768U;
    }
    return (uint32_t)(magnitude * 32768.0f + 0.5f);
}

static uint32_t int16_pcm16_magnitude(
    const unsigned char *bytes,
    int byte_swap
) {
    uint16_t bits = 0;
    memcpy(&bits, bytes, sizeof(bits));
    if (byte_swap) {
        bits = (uint16_t)((bits >> 8) | (bits << 8));
    }
    int16_t sample = 0;
    memcpy(&sample, &bits, sizeof(sample));
    int32_t widened = sample;
    return widened < 0 ? (uint32_t)(-widened) : (uint32_t)widened;
}

static int16_t pcm16_sample_from_bytes(
    const unsigned char *bytes,
    UACSampleKind kind
) {
    if (bytes == NULL) {
        return 0;
    }
    if (kind == MAVO_UAC_SAMPLES_FLOAT32) {
        float sample = 0;
        memcpy(&sample, bytes, sizeof(sample));
        if (!isfinite(sample)) {
            return 0;
        }
        if (sample >= 1.0f) {
            return INT16_MAX;
        }
        if (sample <= -1.0f) {
            return INT16_MIN;
        }
        long scaled = lrintf(sample * 32768.0f);
        if (scaled > INT16_MAX) {
            scaled = INT16_MAX;
        } else if (scaled < INT16_MIN) {
            scaled = INT16_MIN;
        }
        return (int16_t)scaled;
    }
    uint16_t bits = 0;
    memcpy(&bits, bytes, sizeof(bits));
    if (kind == MAVO_UAC_SAMPLES_INT16_SWAPPED) {
        bits = (uint16_t)((bits >> 8) | (bits << 8));
    }
    int16_t sample = 0;
    memcpy(&sample, &bits, sizeof(sample));
    return sample;
}

static int mono_buffer_list_is_valid(const AudioBufferList *buffers) {
    return buffers != NULL &&
        buffers->mNumberBuffers == 1 &&
        buffers->mBuffers[0].mNumberChannels == 1 &&
        buffers->mBuffers[0].mData != NULL;
}

static void enqueue_input_pcm(
    MaVoUACProbe *probe,
    const AudioBufferList *input_data
) {
    if (probe == NULL || !mono_buffer_list_is_valid(input_data) ||
        probe->input.sample_kind == MAVO_UAC_SAMPLES_UNSUPPORTED) {
        return;
    }
    size_t sample_size = probe->input.sample_kind == MAVO_UAC_SAMPLES_FLOAT32
        ? sizeof(float)
        : sizeof(int16_t);
    int16_t converted[MAVO_UAC_CONVERSION_CHUNK_FRAMES];
    for (UInt32 buffer_index = 0;
         buffer_index < input_data->mNumberBuffers;
         buffer_index++) {
        const AudioBuffer *buffer = &input_data->mBuffers[buffer_index];
        if (buffer->mData == NULL || buffer->mDataByteSize < sample_size) {
            continue;
        }
        const unsigned char *source = buffer->mData;
        size_t remaining = buffer->mDataByteSize / sample_size;
        while (remaining > 0) {
            size_t chunk = remaining < MAVO_UAC_CONVERSION_CHUNK_FRAMES
                ? remaining
                : MAVO_UAC_CONVERSION_CHUNK_FRAMES;
            for (size_t index = 0; index < chunk; index++) {
                converted[index] = pcm16_sample_from_bytes(
                    source + index * sample_size,
                    probe->input.sample_kind
                );
            }
            (void)pcm_ring_write(&probe->downlink_ring, converted, chunk);
            source += chunk * sample_size;
            remaining -= chunk;
        }
    }
}

static void write_output_pcm(
    MaVoUACProbe *probe,
    AudioBufferList *output_data
) {
    if (probe == NULL || output_data == NULL) {
        return;
    }
    if (atomic_exchange_explicit(
            &probe->uplink_flush_requested,
            0,
            memory_order_acq_rel
        ) != 0) {
        pcm_ring_discard_from_consumer(&probe->uplink_ring);
    }

    for (UInt32 buffer_index = 0;
         buffer_index < output_data->mNumberBuffers;
         buffer_index++) {
        AudioBuffer *buffer = &output_data->mBuffers[buffer_index];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
    if (!mono_buffer_list_is_valid(output_data)) {
        return;
    }

    int16_t converted[MAVO_UAC_CONVERSION_CHUNK_FRAMES];
    for (UInt32 buffer_index = 0;
         buffer_index < output_data->mNumberBuffers;
         buffer_index++) {
        AudioBuffer *buffer = &output_data->mBuffers[buffer_index];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0) {
            continue;
        }
        if (probe->output.sample_kind == MAVO_UAC_SAMPLES_UNSUPPORTED ||
            probe->output.bytes_per_frame == 0) {
            continue;
        }
        size_t frame_count = buffer->mDataByteSize /
            probe->output.bytes_per_frame;
        unsigned char *destination = buffer->mData;
        while (frame_count > 0) {
            size_t chunk = frame_count < MAVO_UAC_CONVERSION_CHUNK_FRAMES
                ? frame_count
                : MAVO_UAC_CONVERSION_CHUNK_FRAMES;
            size_t copied = pcm_ring_read(
                &probe->uplink_ring,
                converted,
                chunk
            );
            if (copied < chunk) {
                memset(
                    converted + copied,
                    0,
                    (chunk - copied) * sizeof(converted[0])
                );
            }
            for (size_t index = 0; index < chunk; index++) {
                int16_t sample = converted[index];
                unsigned char *frame = destination +
                    index * probe->output.bytes_per_frame;
                if (probe->output.sample_kind == MAVO_UAC_SAMPLES_FLOAT32) {
                    float value = (float)sample / 32768.0f;
                    memcpy(frame, &value, sizeof(value));
                } else {
                    uint16_t bits = 0;
                    memcpy(&bits, &sample, sizeof(bits));
                    if (probe->output.sample_kind == MAVO_UAC_SAMPLES_INT16_SWAPPED) {
                        bits = (uint16_t)((bits >> 8) | (bits << 8));
                    }
                    memcpy(frame, &bits, sizeof(bits));
                }
            }
            destination += chunk * probe->output.bytes_per_frame;
            frame_count -= chunk;
        }
    }
}

static void accumulate_input_signal(
    MaVoUACProbe *probe,
    const AudioBufferList *input_data
) {
    if (probe == NULL || !mono_buffer_list_is_valid(input_data) ||
        probe->input.sample_kind == MAVO_UAC_SAMPLES_UNSUPPORTED) {
        return;
    }

    size_t sample_size = probe->input.sample_kind == MAVO_UAC_SAMPLES_FLOAT32
        ? sizeof(float)
        : sizeof(int16_t);
    uint64_t total_samples = 0;
    uint64_t signal_samples = 0;
    uint32_t peak = 0;
    for (UInt32 buffer_index = 0;
         buffer_index < input_data->mNumberBuffers;
         buffer_index++) {
        const AudioBuffer *buffer = &input_data->mBuffers[buffer_index];
        if (buffer->mData == NULL || buffer->mDataByteSize < sample_size) {
            continue;
        }
        size_t count = buffer->mDataByteSize / sample_size;
        const unsigned char *samples = buffer->mData;
        for (size_t sample_index = 0; sample_index < count; sample_index++) {
            const unsigned char *sample_bytes = samples + sample_index * sample_size;
            uint32_t magnitude = 0;
            if (probe->input.sample_kind == MAVO_UAC_SAMPLES_FLOAT32) {
                magnitude = float32_pcm16_magnitude(sample_bytes);
            } else {
                magnitude = int16_pcm16_magnitude(
                    sample_bytes,
                    probe->input.sample_kind == MAVO_UAC_SAMPLES_INT16_SWAPPED
                );
            }
            if (magnitude > peak) {
                peak = magnitude;
            }
            if (magnitude > MAVO_UAC_SIGNAL_THRESHOLD_PCM16) {
                signal_samples++;
            }
        }
        total_samples += count;
    }

    if (total_samples > 0) {
        atomic_fetch_add_explicit(
            &probe->input_total_samples,
            total_samples,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(
            &probe->input_signal_samples,
            signal_samples,
            memory_order_relaxed
        );
        update_input_peak(probe, peak);
    }
}

static OSStatus audio_io_proc(
    AudioObjectID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input_data,
    const AudioTimeStamp *input_time,
    AudioBufferList *output_data,
    const AudioTimeStamp *output_time,
    void *context
) {
    (void)now;
    (void)input_time;
    (void)output_time;
    MaVoUACProbe *probe = context;
    if (probe == NULL) {
        return noErr;
    }
    atomic_fetch_add_explicit(
        &probe->callbacks_in_flight,
        1,
        memory_order_acq_rel
    );
    atomic_fetch_add_explicit(
        &probe->callback_sequence,
        1,
        memory_order_relaxed
    );

    if (device == probe->input.device_id) {
        uint64_t input_bytes = 0;
        uint64_t input_frames = frames_for_buffers(
            input_data,
            probe->input.bytes_per_frame,
            probe->input.buffer_frames,
            &input_bytes
        );
        if (input_bytes > 0) {
            atomic_fetch_add_explicit(&probe->input_callbacks, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&probe->input_frames, input_frames, memory_order_relaxed);
            atomic_fetch_add_explicit(&probe->input_bytes, input_bytes, memory_order_relaxed);
            accumulate_input_signal(probe, input_data);
            enqueue_input_pcm(probe, input_data);
        }
    }

    if (device == probe->output.device_id) {
        uint64_t output_bytes = 0;
        uint64_t output_frames = frames_for_buffers(
            output_data,
            probe->output.bytes_per_frame,
            probe->output.buffer_frames,
            &output_bytes
        );
        write_output_pcm(probe, output_data);
        if (output_bytes > 0) {
            atomic_fetch_add_explicit(&probe->output_callbacks, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&probe->output_frames, output_frames, memory_order_relaxed);
            atomic_fetch_add_explicit(&probe->output_bytes, output_bytes, memory_order_relaxed);
        }
    }
    atomic_fetch_sub_explicit(
        &probe->callbacks_in_flight,
        1,
        memory_order_release
    );
    return noErr;
}

MaVoUACProbe *mavo_uac_probe_create(void) {
    MaVoUACProbe *probe = calloc(1, sizeof(MaVoUACProbe));
    if (probe != NULL) {
        if (!atomic_is_lock_free(&probe->input_callbacks) ||
            !atomic_is_lock_free(&probe->callbacks_in_flight) ||
            !atomic_is_lock_free(&probe->callback_sequence) ||
            !atomic_is_lock_free(&probe->downlink_ring.read_index) ||
            !atomic_is_lock_free(&probe->downlink_ring.write_index) ||
            !atomic_is_lock_free(&probe->uplink_ring.read_index) ||
            !atomic_is_lock_free(&probe->uplink_ring.write_index) ||
            !atomic_is_lock_free(&probe->uplink_flush_requested)) {
            free(probe);
            return NULL;
        }
        probe->input.device_id = kAudioObjectUnknown;
        probe->output.device_id = kAudioObjectUnknown;
    }
    return probe;
}

static int restore_endpoint_sample_rate(
    UACEndpoint *endpoint,
    const char *label,
    char *errors,
    size_t errors_capacity
) {
    if (endpoint == NULL || !endpoint->sample_rate_changed ||
        endpoint->device_id == kAudioObjectUnknown) {
        return MAVO_UAC_OK;
    }
    if (endpoint->running || endpoint->io_proc_id != NULL) {
        append_text(
            errors,
            errors_capacity,
            "%s%s sample rate restore deferred because its IOProc is not fully stopped",
            errors[0] == '\0' ? "" : "; ",
            label
        );
        return MAVO_UAC_NOT_OPEN;
    }
    AudioObjectPropertyAddress address = property_address(
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal
    );
    double original = endpoint->original_sample_rate;
    OSStatus status = AudioObjectSetPropertyData(
        endpoint->device_id,
        &address,
        0,
        NULL,
        (UInt32)sizeof(original),
        &original
    );
    if (status != noErr) {
        char status_text[64];
        osstatus_text(status, status_text, sizeof(status_text));
        append_text(
            errors,
            errors_capacity,
            "%srestore %s sample rate %.0f Hz failed: %s",
            errors[0] == '\0' ? "" : "; ",
            label,
            original,
            status_text
        );
        return (int)status;
    }
    for (int attempt = 0; attempt < 100; attempt++) {
        double observed = 0;
        if (double_property(
                endpoint->device_id,
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                &observed
            ) && fabs(observed - original) < 0.5) {
            endpoint->sample_rate_changed = 0;
            endpoint->sample_rate = observed;
            return MAVO_UAC_OK;
        }
        usleep(10000);
    }
    append_text(
        errors,
        errors_capacity,
        "%s%s nominal sample rate did not restore to %.0f Hz",
        errors[0] == '\0' ? "" : "; ",
        label,
        original
    );
    return MAVO_UAC_UNSUPPORTED;
}

static int stop_endpoint(
    UACEndpoint *endpoint,
    const char *label,
    char *errors,
    size_t errors_capacity
) {
    if (endpoint == NULL || endpoint->device_id == kAudioObjectUnknown) {
        return MAVO_UAC_OK;
    }

    if (endpoint->io_proc_id != NULL && endpoint->running) {
        OSStatus status = AudioDeviceStop(endpoint->device_id, endpoint->io_proc_id);
        if (status != noErr) {
            char status_text[64];
            osstatus_text(status, status_text, sizeof(status_text));
            append_text(
                errors,
                errors_capacity,
                "%sstop %s IOProc failed: %s",
                errors[0] == '\0' ? "" : "; ",
                label,
                status_text
            );
            /* Keep both the IOProc and its probe context alive. Destroying or
             * freeing either after an unconfirmed stop can race a callback. */
            return (int)status;
        }
        endpoint->running = 0;
    }
    if (endpoint->io_proc_id != NULL) {
        OSStatus status = AudioDeviceDestroyIOProcID(
            endpoint->device_id,
            endpoint->io_proc_id
        );
        if (status != noErr) {
            char status_text[64];
            osstatus_text(status, status_text, sizeof(status_text));
            append_text(
                errors,
                errors_capacity,
                "%sdestroy stopped %s IOProc failed: %s",
                errors[0] == '\0' ? "" : "; ",
                label,
                status_text
            );
            return (int)status;
        }
        endpoint->io_proc_id = NULL;
    }
    return restore_endpoint_sample_rate(endpoint, label, errors, errors_capacity);
}

static int probe_has_unresolved_io(const MaVoUACProbe *probe) {
    return probe != NULL &&
        (probe->input.running || probe->output.running ||
         probe->input.io_proc_id != NULL || probe->output.io_proc_id != NULL ||
         probe->input.sample_rate_changed || probe->output.sample_rate_changed);
}

int mavo_uac_probe_stop(MaVoUACProbe *probe) {
    if (probe == NULL) {
        return MAVO_UAC_NOT_OPEN;
    }

    char errors[MAVO_UAC_ERROR_CAPACITY] = {0};
    int first_result = stop_endpoint(
        &probe->input,
        "input",
        errors,
        sizeof(errors)
    );
    if (probe->output.device_id != probe->input.device_id) {
        int output_result = stop_endpoint(
            &probe->output,
            "output",
            errors,
            sizeof(errors)
        );
        if (first_result == MAVO_UAC_OK && output_result != MAVO_UAC_OK) {
            first_result = output_result;
        }
    } else {
        probe->output.running = 0;
        probe->output.io_proc_id = NULL;
        probe->output.sample_rate = probe->input.sample_rate;
    }

    probe->sample_rate = probe->input.sample_rate;
    if (first_result != MAVO_UAC_OK) {
        set_error(probe, "%s", errors[0] == '\0' ? "UAC IO cleanup failed" : errors);
        return first_result;
    }
    clear_error(probe);
    return MAVO_UAC_OK;
}

void mavo_uac_probe_close(MaVoUACProbe *probe) {
    if (probe == NULL) {
        return;
    }
    (void)mavo_uac_probe_stop(probe);
    if (probe_has_unresolved_io(probe)) {
        return;
    }
    memset(&probe->input, 0, sizeof(probe->input));
    memset(&probe->output, 0, sizeof(probe->output));
    probe->input.device_id = kAudioObjectUnknown;
    probe->output.device_id = kAudioObjectUnknown;
    probe->name[0] = '\0';
    probe->uid[0] = '\0';
    probe->sample_rate = 0;
    probe->input_channels = 0;
    probe->output_channels = 0;
    probe->usb_binding_verified = 0;
}

int mavo_uac_probe_try_destroy(MaVoUACProbe *probe) {
    if (probe == NULL) {
        return MAVO_UAC_OK;
    }
    mavo_uac_probe_close(probe);
    if (probe_has_unresolved_io(probe)) {
        if (probe->last_error[0] == '\0') {
            set_error(probe, "UAC callback or sample-rate cleanup remains unresolved");
        }
        return MAVO_UAC_NOT_OPEN;
    }
    free(probe);
    return MAVO_UAC_OK;
}

void mavo_uac_probe_destroy(MaVoUACProbe *probe) {
    /* Legacy short-lived probe API. Long-lived owners should use try_destroy
     * and retain the pointer when it reports unresolved callback cleanup. */
    (void)mavo_uac_probe_try_destroy(probe);
}

static void configure_endpoint(
    UACEndpoint *endpoint,
    const UACCandidate *candidate,
    AudioObjectPropertyScope scope
) {
    memset(endpoint, 0, sizeof(*endpoint));
    endpoint->device_id = candidate->device_id;
    snprintf(endpoint->name, sizeof(endpoint->name), "%s", candidate->name);
    snprintf(endpoint->uid, sizeof(endpoint->uid), "%s", candidate->uid);
    endpoint->original_sample_rate = candidate->sample_rate;
    endpoint->sample_rate = candidate->sample_rate;
    endpoint->channels = scope == kAudioObjectPropertyScopeInput
        ? candidate->input_channels
        : candidate->output_channels;
    endpoint->usb_vendor_id = candidate->usb.vendor_id;
    endpoint->usb_product_id = candidate->usb.product_id;
    endpoint->usb_location_id = candidate->usb.location_id;
    endpoint->usb_ancestor_entry_id = candidate->usb.ancestor_entry_id;
    (void)uint32_property(
        candidate->device_id,
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        &endpoint->buffer_frames
    );
    if (virtual_format(candidate->device_id, scope, &endpoint->virtual_format)) {
        endpoint->bytes_per_frame = endpoint->virtual_format.mBytesPerFrame;
        endpoint->sample_kind = sample_kind_for_format(&endpoint->virtual_format);
    }
}

int mavo_uac_probe_open_for_usb(
    MaVoUACProbe *probe,
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t location_id,
    const char *preferred_uid
) {
    if (probe == NULL) {
        return MAVO_UAC_NOT_OPEN;
    }
    mavo_uac_probe_close(probe);
    if (probe->input.device_id != kAudioObjectUnknown ||
        probe->output.device_id != kAudioObjectUnknown ||
        probe_has_unresolved_io(probe)) {
        if (probe->last_error[0] == '\0') {
            set_error(probe, "previous UAC session cleanup is unresolved");
        }
        return MAVO_UAC_NOT_OPEN;
    }
    clear_error(probe);
    if (vendor_id == 0 || product_id == 0 || location_id == 0) {
        set_error(probe, "AT USB identity is incomplete; refusing to select a UAC device");
        return MAVO_UAC_NOT_FOUND;
    }

    AudioObjectPropertyAddress devices_address = property_address(
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal
    );
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        NULL,
        &size
    );
    if (status != noErr || size < sizeof(AudioObjectID)) {
        char status_text[64];
        osstatus_text(status, status_text, sizeof(status_text));
        set_error(probe, "enumerate CoreAudio devices failed: %s", status_text);
        return status == noErr ? MAVO_UAC_NOT_FOUND : (int)status;
    }
    AudioObjectID *devices = calloc(1, size);
    if (devices == NULL) {
        set_error(probe, "allocate CoreAudio device inventory failed");
        return MAVO_UAC_NOT_OPEN;
    }
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devices_address,
        0,
        NULL,
        &size,
        devices
    );
    if (status != noErr) {
        char status_text[64];
        osstatus_text(status, status_text, sizeof(status_text));
        set_error(probe, "read CoreAudio device inventory failed: %s", status_text);
        free(devices);
        return (int)status;
    }

    size_t count = size / sizeof(AudioObjectID);
    UACCandidate *candidates = calloc(count, sizeof(UACCandidate));
    if (candidates == NULL) {
        set_error(probe, "allocate UAC candidate inventory failed");
        free(devices);
        return MAVO_UAC_NOT_OPEN;
    }

    char inventory[MAVO_UAC_ERROR_CAPACITY] = {0};
    size_t candidate_count = 0;
    int explicit_uid = preferred_uid != NULL && preferred_uid[0] != '\0';

    for (size_t index = 0; index < count; index++) {
        AudioObjectID device = devices[index];
        uint32_t transport = 0;
        uint32_t alive = 0;
        if (!uint32_property(
                device,
                kAudioDevicePropertyTransportType,
                kAudioObjectPropertyScopeGlobal,
                &transport
            ) || transport != kAudioDeviceTransportTypeUSB ||
            !uint32_property(
                device,
                kAudioDevicePropertyDeviceIsAlive,
                kAudioObjectPropertyScopeGlobal,
                &alive
            ) || alive == 0) {
            continue;
        }
        uint32_t input_channels = channel_count(device, kAudioObjectPropertyScopeInput);
        uint32_t output_channels = channel_count(device, kAudioObjectPropertyScopeOutput);
        if (input_channels == 0 && output_channels == 0) {
            continue;
        }
        char name[MAVO_UAC_TEXT_CAPACITY] = {0};
        char uid[MAVO_UAC_TEXT_CAPACITY] = {0};
        (void)string_property(device, kAudioObjectPropertyName, name, sizeof(name));
        if (!string_property(device, kAudioDevicePropertyDeviceUID, uid, sizeof(uid))) {
            continue;
        }
        double rate = 0;
        (void)double_property(
            device,
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            &rate
        );
        USBIdentity identity = usb_identity_for_audio_uid(uid);
        uint32_t uid_location = 0;
        uint32_t uid_interface = 0;
        if (!identity.available &&
            apple_usb_audio_uid_endpoint(uid, &uid_location, &uid_interface) &&
            uid_location == location_id) {
            identity = verified_usb_audio_interface_identity(
                vendor_id,
                product_id,
                uid_location,
                uid_interface
            );
        }
        int supports_target_rate = available_rate_includes(device, MAVO_UAC_TARGET_RATE);
        append_text(
            inventory,
            sizeof(inventory),
            "%s{id=%u,name=\"%s\",uid=\"%s\",in=%u,out=%u,rate=%.0f,8k=%s,usb=",
            inventory[0] == '\0' ? "" : "; ",
            device,
            name[0] == '\0' ? "(unnamed)" : name,
            uid,
            input_channels,
            output_channels,
            rate,
            supports_target_rate ? "yes" : "no"
        );
        if (identity.available) {
            append_text(
                inventory,
                sizeof(inventory),
                "%04X:%04X@%08X#%llX,source=%s}",
                identity.vendor_id,
                identity.product_id,
                identity.location_id,
                (unsigned long long)identity.ancestor_entry_id,
                identity.verified_from_uid_location
                    ? "uid+IOUSBInterface"
                    : "IOAudioEngine"
            );
        } else {
            append_text(inventory, sizeof(inventory), "unmapped}");
        }

        UACCandidate *candidate = &candidates[candidate_count++];
        candidate->device_id = device;
        snprintf(candidate->name, sizeof(candidate->name), "%s", name);
        snprintf(candidate->uid, sizeof(candidate->uid), "%s", uid);
        candidate->input_channels = input_channels;
        candidate->output_channels = output_channels;
        candidate->sample_rate = rate;
        candidate->usb = identity;
        candidate->supports_target_rate = supports_target_rate;
    }
    free(devices);

    const UACCandidate *selected_input = NULL;
    const UACCandidate *selected_output = NULL;
    unsigned int match_count = 0;
    for (size_t input_index = 0; input_index < candidate_count; input_index++) {
        const UACCandidate *input = &candidates[input_index];
        if (input->input_channels != 1 || !input->supports_target_rate ||
            !identity_matches(input->usb, vendor_id, product_id, location_id)) {
            continue;
        }
        for (size_t output_index = 0; output_index < candidate_count; output_index++) {
            const UACCandidate *output = &candidates[output_index];
            if (output->output_channels != 1 || !output->supports_target_rate ||
                !identity_matches(output->usb, vendor_id, product_id, location_id) ||
                !identities_share_usb_device(input->usb, output->usb) ||
                !audio_devices_are_mutually_related(
                    input->device_id,
                    output->device_id
                )) {
                continue;
            }
            if (explicit_uid) {
                char pair_uid[MAVO_UAC_TEXT_CAPACITY] = {0};
                if (input->device_id == output->device_id) {
                    snprintf(pair_uid, sizeof(pair_uid), "%s", input->uid);
                } else {
                    snprintf(
                        pair_uid,
                        sizeof(pair_uid),
                        "input:%s|output:%s",
                        input->uid,
                        output->uid
                    );
                }
                if (strcmp(input->uid, preferred_uid) != 0 &&
                    strcmp(output->uid, preferred_uid) != 0 &&
                    strcmp(pair_uid, preferred_uid) != 0) {
                    continue;
                }
            }
            match_count++;
            selected_input = input;
            selected_output = output;
        }
    }

    if (match_count == 0) {
        if (explicit_uid) {
            set_error(
                probe,
                "requested UAC UID \"%s\" was not part of a compatible 8 kHz input/output pair for the modem; candidates: %s",
                preferred_uid,
                inventory[0] == '\0' ? "none" : inventory
            );
        } else {
            set_error(
                probe,
                "no 8 kHz CoreAudio input/output pair is mutually related and shares physical modem USB device %04X:%04X@%08X; candidates: %s",
                vendor_id,
                product_id,
                location_id,
                inventory[0] == '\0' ? "none" : inventory
            );
        }
        free(candidates);
        return MAVO_UAC_NOT_FOUND;
    }
    if (match_count > 1) {
        set_error(
            probe,
            "multiple compatible UAC input/output pairs matched; pass either member's --uac-device-uid exactly; candidates: %s",
            inventory
        );
        free(candidates);
        return MAVO_UAC_AMBIGUOUS;
    }

    configure_endpoint(
        &probe->input,
        selected_input,
        kAudioObjectPropertyScopeInput
    );
    configure_endpoint(
        &probe->output,
        selected_output,
        kAudioObjectPropertyScopeOutput
    );
    const char *input_name = probe->input.name[0] == '\0'
        ? "(unnamed input)"
        : probe->input.name;
    const char *output_name = probe->output.name[0] == '\0'
        ? "(unnamed output)"
        : probe->output.name;
    if (probe->input.device_id == probe->output.device_id) {
        snprintf(probe->name, sizeof(probe->name), "%s", input_name);
        snprintf(probe->uid, sizeof(probe->uid), "%s", probe->input.uid);
    } else {
        snprintf(
            probe->name,
            sizeof(probe->name),
            "%s (input) + %s (output)",
            input_name,
            output_name
        );
        snprintf(
            probe->uid,
            sizeof(probe->uid),
            "input:%s|output:%s",
            probe->input.uid,
            probe->output.uid
        );
    }
    probe->sample_rate = probe->input.sample_rate;
    probe->input_channels = probe->input.channels;
    probe->output_channels = probe->output.channels;
    probe->usb_binding_verified = identities_share_usb_device(
        selected_input->usb,
        selected_output->usb
    ) && audio_devices_are_mutually_related(
        selected_input->device_id,
        selected_output->device_id
    );
    if (probe->input.sample_kind == MAVO_UAC_SAMPLES_UNSUPPORTED) {
        AudioStreamBasicDescription format = probe->input.virtual_format;
        free(candidates);
        mavo_uac_probe_close(probe);
        set_error(
            probe,
            "unsupported UAC input virtual ASBD format=0x%08X flags=0x%08X bits=%u channels=%u bytesPerFrame=%u; expected mono Float32 or signed Int16 linear PCM",
            (unsigned int)format.mFormatID,
            (unsigned int)format.mFormatFlags,
            (unsigned int)format.mBitsPerChannel,
            (unsigned int)format.mChannelsPerFrame,
            (unsigned int)format.mBytesPerFrame
        );
        return MAVO_UAC_UNSUPPORTED;
    }
    if (probe->output.sample_kind == MAVO_UAC_SAMPLES_UNSUPPORTED) {
        AudioStreamBasicDescription format = probe->output.virtual_format;
        free(candidates);
        mavo_uac_probe_close(probe);
        set_error(
            probe,
            "unsupported UAC output virtual ASBD format=0x%08X flags=0x%08X bits=%u channels=%u bytesPerFrame=%u; expected mono Float32 or signed Int16 linear PCM",
            (unsigned int)format.mFormatID,
            (unsigned int)format.mFormatFlags,
            (unsigned int)format.mBitsPerChannel,
            (unsigned int)format.mChannelsPerFrame,
            (unsigned int)format.mBytesPerFrame
        );
        return MAVO_UAC_UNSUPPORTED;
    }
    free(candidates);
    clear_error(probe);
    return MAVO_UAC_OK;
}

static int set_endpoint_target_sample_rate(
    UACEndpoint *endpoint,
    const char *label,
    char *errors,
    size_t errors_capacity
) {
    double current = 0;
    if (!double_property(
            endpoint->device_id,
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            &current
        )) {
        append_text(
            errors,
            errors_capacity,
            "%sread %s nominal sample rate failed",
            errors[0] == '\0' ? "" : "; ",
            label
        );
        return MAVO_UAC_UNSUPPORTED;
    }
    endpoint->original_sample_rate = current;
    endpoint->sample_rate = current;
    if (fabs(current - MAVO_UAC_TARGET_RATE) < 0.5) {
        return MAVO_UAC_OK;
    }
    if (!available_rate_includes(endpoint->device_id, MAVO_UAC_TARGET_RATE)) {
        append_text(
            errors,
            errors_capacity,
            "%s%s device does not advertise an 8 kHz nominal sample rate",
            errors[0] == '\0' ? "" : "; ",
            label
        );
        return MAVO_UAC_UNSUPPORTED;
    }
    AudioObjectPropertyAddress address = property_address(
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal
    );
    Boolean settable = false;
    OSStatus status = AudioObjectIsPropertySettable(endpoint->device_id, &address, &settable);
    if (status != noErr || !settable) {
        append_text(
            errors,
            errors_capacity,
            "%s%s nominal sample rate is not settable to 8 kHz",
            errors[0] == '\0' ? "" : "; ",
            label
        );
        return status == noErr ? MAVO_UAC_UNSUPPORTED : (int)status;
    }
    double target = MAVO_UAC_TARGET_RATE;
    /* A lost response must still cause close() to restore the captured rate. */
    endpoint->sample_rate_changed = 1;
    status = AudioObjectSetPropertyData(
        endpoint->device_id,
        &address,
        0,
        NULL,
        (UInt32)sizeof(target),
        &target
    );
    if (status != noErr) {
        char status_text[64];
        osstatus_text(status, status_text, sizeof(status_text));
        append_text(
            errors,
            errors_capacity,
            "%sset %s nominal sample rate to 8 kHz failed: %s",
            errors[0] == '\0' ? "" : "; ",
            label,
            status_text
        );
        return (int)status;
    }
    for (int attempt = 0; attempt < 100; attempt++) {
        double observed = 0;
        if (double_property(
                endpoint->device_id,
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                &observed
            ) && fabs(observed - target) < 0.5) {
            endpoint->sample_rate = observed;
            return MAVO_UAC_OK;
        }
        usleep(10000);
    }
    append_text(
        errors,
        errors_capacity,
        "%s%s nominal sample rate did not settle at 8 kHz",
        errors[0] == '\0' ? "" : "; ",
        label
    );
    return MAVO_UAC_UNSUPPORTED;
}

static int fail_start_and_cleanup(
    MaVoUACProbe *probe,
    int result,
    const char *start_error
) {
    int cleanup_result = mavo_uac_probe_stop(probe);
    if (cleanup_result == MAVO_UAC_OK) {
        set_error(probe, "%s", start_error);
    } else {
        char cleanup_error[MAVO_UAC_ERROR_CAPACITY] = {0};
        snprintf(cleanup_error, sizeof(cleanup_error), "%s", probe->last_error);
        set_error(
            probe,
            "%s; rollback incomplete: %s",
            start_error,
            cleanup_error[0] == '\0' ? "unknown cleanup error" : cleanup_error
        );
    }
    return result;
}

static void refresh_endpoint_format(
    UACEndpoint *endpoint,
    AudioObjectPropertyScope scope
) {
    endpoint->buffer_frames = 0;
    (void)uint32_property(
        endpoint->device_id,
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        &endpoint->buffer_frames
    );
    memset(&endpoint->virtual_format, 0, sizeof(endpoint->virtual_format));
    endpoint->sample_kind = MAVO_UAC_SAMPLES_UNSUPPORTED;
    endpoint->bytes_per_frame = 0;
    if (virtual_format(endpoint->device_id, scope, &endpoint->virtual_format)) {
        endpoint->bytes_per_frame = endpoint->virtual_format.mBytesPerFrame;
        endpoint->sample_kind = sample_kind_for_format(&endpoint->virtual_format);
    }
}

static int endpoint_format_is_bridge_ready(const UACEndpoint *endpoint) {
    if (endpoint == NULL || endpoint->sample_kind == MAVO_UAC_SAMPLES_UNSUPPORTED) {
        return 0;
    }
    const AudioStreamBasicDescription *format = &endpoint->virtual_format;
    return fabs(format->mSampleRate - MAVO_UAC_TARGET_RATE) < 0.5 &&
        format->mChannelsPerFrame == 1 &&
        format->mFramesPerPacket == 1 &&
        format->mBytesPerFrame > 0 &&
        format->mBytesPerPacket == format->mBytesPerFrame;
}

static int wait_for_endpoint_bridge_format(
    UACEndpoint *endpoint,
    AudioObjectPropertyScope scope
) {
    for (int attempt = 0; attempt < 100; attempt++) {
        refresh_endpoint_format(endpoint, scope);
        if (endpoint_format_is_bridge_ready(endpoint)) {
            return 1;
        }
        usleep(10000);
    }
    return 0;
}

int mavo_uac_probe_start_pcm_bridge(MaVoUACProbe *probe) {
    if (probe == NULL || probe->input.device_id == kAudioObjectUnknown ||
        probe->output.device_id == kAudioObjectUnknown) {
        return MAVO_UAC_NOT_OPEN;
    }
    int shared_device = probe->input.device_id == probe->output.device_id;
    int fully_running = probe->input.running &&
        (shared_device || probe->output.running);
    if (fully_running) {
        return MAVO_UAC_OK;
    }
    if (probe_has_unresolved_io(probe)) {
        set_error(probe, "a partial UAC IO session must be stopped before restart");
        return MAVO_UAC_NOT_OPEN;
    }
    clear_error(probe);
    char start_error[MAVO_UAC_ERROR_CAPACITY] = {0};
    int rate_result = set_endpoint_target_sample_rate(
        &probe->input,
        "input",
        start_error,
        sizeof(start_error)
    );
    if (rate_result != MAVO_UAC_OK) {
        return fail_start_and_cleanup(probe, rate_result, start_error);
    }
    if (!shared_device) {
        rate_result = set_endpoint_target_sample_rate(
            &probe->output,
            "output",
            start_error,
            sizeof(start_error)
        );
        if (rate_result != MAVO_UAC_OK) {
            return fail_start_and_cleanup(probe, rate_result, start_error);
        }
    } else {
        probe->output.original_sample_rate = probe->input.original_sample_rate;
        probe->output.sample_rate = probe->input.sample_rate;
    }
    probe->sample_rate = probe->input.sample_rate;
    int input_format_ready = wait_for_endpoint_bridge_format(
        &probe->input,
        kAudioObjectPropertyScopeInput
    );
    int output_format_ready = wait_for_endpoint_bridge_format(
        &probe->output,
        kAudioObjectPropertyScopeOutput
    );
    if (!input_format_ready) {
        snprintf(
            start_error,
            sizeof(start_error),
            "unsupported UAC input virtual ASBD rate=%.0f format=0x%08X flags=0x%08X bits=%u channels=%u bytesPerFrame=%u bytesPerPacket=%u framesPerPacket=%u; expected 8 kHz mono Float32 or signed Int16 linear PCM with one frame per packet",
            probe->input.virtual_format.mSampleRate,
            (unsigned int)probe->input.virtual_format.mFormatID,
            (unsigned int)probe->input.virtual_format.mFormatFlags,
            (unsigned int)probe->input.virtual_format.mBitsPerChannel,
            (unsigned int)probe->input.virtual_format.mChannelsPerFrame,
            (unsigned int)probe->input.virtual_format.mBytesPerFrame,
            (unsigned int)probe->input.virtual_format.mBytesPerPacket,
            (unsigned int)probe->input.virtual_format.mFramesPerPacket
        );
        return fail_start_and_cleanup(probe, MAVO_UAC_UNSUPPORTED, start_error);
    }
    if (!output_format_ready) {
        snprintf(
            start_error,
            sizeof(start_error),
            "unsupported UAC output virtual ASBD rate=%.0f format=0x%08X flags=0x%08X bits=%u channels=%u bytesPerFrame=%u bytesPerPacket=%u framesPerPacket=%u; expected 8 kHz mono Float32 or signed Int16 linear PCM with one frame per packet",
            probe->output.virtual_format.mSampleRate,
            (unsigned int)probe->output.virtual_format.mFormatID,
            (unsigned int)probe->output.virtual_format.mFormatFlags,
            (unsigned int)probe->output.virtual_format.mBitsPerChannel,
            (unsigned int)probe->output.virtual_format.mChannelsPerFrame,
            (unsigned int)probe->output.virtual_format.mBytesPerFrame,
            (unsigned int)probe->output.virtual_format.mBytesPerPacket,
            (unsigned int)probe->output.virtual_format.mFramesPerPacket
        );
        return fail_start_and_cleanup(probe, MAVO_UAC_UNSUPPORTED, start_error);
    }
    atomic_store_explicit(&probe->input_callbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->output_callbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->input_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->output_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->input_bytes, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->output_bytes, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->input_peak_pcm16, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->input_total_samples, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->input_signal_samples, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->callbacks_in_flight, 0, memory_order_relaxed);
    atomic_store_explicit(&probe->callback_sequence, 0, memory_order_relaxed);
    pcm_ring_reset(&probe->downlink_ring);
    pcm_ring_reset(&probe->uplink_ring);
    atomic_store_explicit(&probe->uplink_flush_requested, 0, memory_order_relaxed);

    OSStatus status = AudioDeviceCreateIOProcID(
        probe->input.device_id,
        audio_io_proc,
        probe,
        &probe->input.io_proc_id
    );
    if (status != noErr) {
        char status_text[64];
        osstatus_text(status, status_text, sizeof(status_text));
        snprintf(start_error, sizeof(start_error), "create input UAC IOProc failed: %s", status_text);
        probe->input.io_proc_id = NULL;
        return fail_start_and_cleanup(probe, (int)status, start_error);
    }
    if (!shared_device) {
        status = AudioDeviceCreateIOProcID(
            probe->output.device_id,
            audio_io_proc,
            probe,
            &probe->output.io_proc_id
        );
        if (status != noErr) {
            char status_text[64];
            osstatus_text(status, status_text, sizeof(status_text));
            snprintf(
                start_error,
                sizeof(start_error),
                "create output UAC IOProc failed: %s",
                status_text
            );
            probe->output.io_proc_id = NULL;
            return fail_start_and_cleanup(probe, (int)status, start_error);
        }
    }

    status = AudioDeviceStart(probe->input.device_id, probe->input.io_proc_id);
    if (status != noErr) {
        char status_text[64];
        osstatus_text(status, status_text, sizeof(status_text));
        snprintf(
            start_error,
            sizeof(start_error),
            "start input UAC IOProc failed: %s (Terminal may need Microphone permission)",
            status_text
        );
        return fail_start_and_cleanup(probe, (int)status, start_error);
    }
    probe->input.running = 1;

    if (!shared_device) {
        status = AudioDeviceStart(probe->output.device_id, probe->output.io_proc_id);
        if (status != noErr) {
            char status_text[64];
            osstatus_text(status, status_text, sizeof(status_text));
            snprintf(
                start_error,
                sizeof(start_error),
                "start output UAC IOProc failed: %s",
                status_text
            );
            return fail_start_and_cleanup(probe, (int)status, start_error);
        }
        probe->output.running = 1;
    }
    clear_error(probe);
    return MAVO_UAC_OK;
}

int mavo_uac_probe_start_silence(MaVoUACProbe *probe) {
    return mavo_uac_probe_start_pcm_bridge(probe);
}

size_t mavo_uac_probe_read_downlink_pcm16(
    MaVoUACProbe *probe,
    int16_t *frames,
    size_t maximum_frames
) {
    if (probe == NULL) {
        return 0;
    }
    return pcm_ring_read(&probe->downlink_ring, frames, maximum_frames);
}

size_t mavo_uac_probe_write_uplink_pcm16(
    MaVoUACProbe *probe,
    const int16_t *frames,
    size_t frame_count
) {
    if (probe == NULL) {
        return 0;
    }
    return pcm_ring_write(&probe->uplink_ring, frames, frame_count);
}

void mavo_uac_probe_flush_downlink_pcm(MaVoUACProbe *probe) {
    if (probe == NULL) {
        return;
    }
    pcm_ring_discard_from_consumer(&probe->downlink_ring);
}

void mavo_uac_probe_flush_uplink_pcm(MaVoUACProbe *probe) {
    if (probe == NULL) {
        return;
    }
    atomic_store_explicit(
        &probe->uplink_flush_requested,
        1,
        memory_order_release
    );
}

void mavo_uac_probe_flush_pcm(MaVoUACProbe *probe) {
    mavo_uac_probe_flush_downlink_pcm(probe);
    mavo_uac_probe_flush_uplink_pcm(probe);
}

int mavo_uac_probe_is_open(const MaVoUACProbe *probe) {
    return probe != NULL &&
        probe->input.device_id != kAudioObjectUnknown &&
        probe->output.device_id != kAudioObjectUnknown;
}

int mavo_uac_probe_is_running(const MaVoUACProbe *probe) {
    if (probe == NULL || probe->input.device_id == kAudioObjectUnknown ||
        probe->output.device_id == kAudioObjectUnknown) {
        return 0;
    }
    if (probe->input.device_id == probe->output.device_id) {
        return probe->input.running;
    }
    return probe->input.running && probe->output.running;
}

static int endpoint_original_device_is_alive(const UACEndpoint *endpoint) {
    if (endpoint == NULL || endpoint->device_id == kAudioObjectUnknown ||
        endpoint->uid[0] == '\0') {
        return 0;
    }
    uint32_t alive = 0;
    if (!uint32_property(
            endpoint->device_id,
            kAudioDevicePropertyDeviceIsAlive,
            kAudioObjectPropertyScopeGlobal,
            &alive
        ) || alive == 0) {
        return 0;
    }
    char current_uid[MAVO_UAC_TEXT_CAPACITY] = {0};
    if (!string_property(
        endpoint->device_id,
        kAudioDevicePropertyDeviceUID,
        current_uid,
        sizeof(current_uid)
    ) || strcmp(current_uid, endpoint->uid) != 0) {
        return 0;
    }
    USBIdentity identity = usb_identity_for_audio_uid(current_uid);
    uint32_t uid_location = 0;
    uint32_t uid_interface = 0;
    if (!identity.available &&
        apple_usb_audio_uid_endpoint(
            current_uid,
            &uid_location,
            &uid_interface
        ) && uid_location == endpoint->usb_location_id) {
        identity = verified_usb_audio_interface_identity(
            endpoint->usb_vendor_id,
            endpoint->usb_product_id,
            uid_location,
            uid_interface
        );
    }
    return identity.available &&
        identity.vendor_id == endpoint->usb_vendor_id &&
        identity.product_id == endpoint->usb_product_id &&
        identity.location_id == endpoint->usb_location_id &&
        identity.ancestor_entry_id == endpoint->usb_ancestor_entry_id;
}

int mavo_uac_probe_original_devices_alive(const MaVoUACProbe *probe) {
    if (probe == NULL) {
        return 0;
    }
    return endpoint_original_device_is_alive(&probe->input) ||
        endpoint_original_device_is_alive(&probe->output);
}

int mavo_uac_probe_original_usb_present(const MaVoUACProbe *probe) {
    if (probe == NULL) {
        return -1;
    }
    uint64_t ancestor = probe->input.usb_ancestor_entry_id != 0
        ? probe->input.usb_ancestor_entry_id
        : probe->output.usb_ancestor_entry_id;
    if (ancestor == 0) {
        return -1;
    }
    CFMutableDictionaryRef matching = IORegistryEntryIDMatching(ancestor);
    if (matching == NULL) {
        return -1;
    }
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        matching
    );
    if (service == IO_OBJECT_NULL) {
        return 0;
    }
    uint64_t observed = 0;
    int present = IORegistryEntryGetRegistryEntryID(service, &observed) ==
        kIOReturnSuccess && observed == ancestor;
    IOObjectRelease(service);
    return present ? 1 : -1;
}

uint32_t mavo_uac_probe_callbacks_in_flight(const MaVoUACProbe *probe) {
    return probe == NULL
        ? 0
        : atomic_load_explicit(&probe->callbacks_in_flight, memory_order_acquire);
}

uint64_t mavo_uac_probe_callback_sequence(const MaVoUACProbe *probe) {
    return probe == NULL
        ? 0
        : atomic_load_explicit(&probe->callback_sequence, memory_order_acquire);
}

uint32_t mavo_uac_probe_device_id(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->input.device_id;
}

const char *mavo_uac_probe_name(const MaVoUACProbe *probe) {
    return probe == NULL ? "" : probe->name;
}

const char *mavo_uac_probe_uid(const MaVoUACProbe *probe) {
    return probe == NULL ? "" : probe->uid;
}

double mavo_uac_probe_sample_rate(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->sample_rate;
}

uint32_t mavo_uac_probe_input_device_id(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->input.device_id;
}

uint32_t mavo_uac_probe_output_device_id(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->output.device_id;
}

const char *mavo_uac_probe_input_name(const MaVoUACProbe *probe) {
    return probe == NULL ? "" : probe->input.name;
}

const char *mavo_uac_probe_output_name(const MaVoUACProbe *probe) {
    return probe == NULL ? "" : probe->output.name;
}

const char *mavo_uac_probe_input_uid(const MaVoUACProbe *probe) {
    return probe == NULL ? "" : probe->input.uid;
}

const char *mavo_uac_probe_output_uid(const MaVoUACProbe *probe) {
    return probe == NULL ? "" : probe->output.uid;
}

double mavo_uac_probe_input_sample_rate(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->input.sample_rate;
}

double mavo_uac_probe_output_sample_rate(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->output.sample_rate;
}

uint32_t mavo_uac_probe_input_channels(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->input_channels;
}

uint32_t mavo_uac_probe_output_channels(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : probe->output_channels;
}

int mavo_uac_probe_usb_binding_verified(const MaVoUACProbe *probe) {
    return probe != NULL && probe->usb_binding_verified;
}

uint64_t mavo_uac_probe_input_callbacks(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : atomic_load_explicit(&probe->input_callbacks, memory_order_relaxed);
}

uint64_t mavo_uac_probe_output_callbacks(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : atomic_load_explicit(&probe->output_callbacks, memory_order_relaxed);
}

uint64_t mavo_uac_probe_input_frames(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : atomic_load_explicit(&probe->input_frames, memory_order_relaxed);
}

uint64_t mavo_uac_probe_output_frames(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : atomic_load_explicit(&probe->output_frames, memory_order_relaxed);
}

uint64_t mavo_uac_probe_input_bytes(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : atomic_load_explicit(&probe->input_bytes, memory_order_relaxed);
}

uint64_t mavo_uac_probe_output_bytes(const MaVoUACProbe *probe) {
    return probe == NULL ? 0 : atomic_load_explicit(&probe->output_bytes, memory_order_relaxed);
}

uint32_t mavo_uac_probe_input_peak_pcm16(const MaVoUACProbe *probe) {
    return probe == NULL
        ? 0
        : atomic_load_explicit(&probe->input_peak_pcm16, memory_order_relaxed);
}

uint64_t mavo_uac_probe_input_total_samples(const MaVoUACProbe *probe) {
    return probe == NULL
        ? 0
        : atomic_load_explicit(&probe->input_total_samples, memory_order_relaxed);
}

uint64_t mavo_uac_probe_input_signal_samples(const MaVoUACProbe *probe) {
    return probe == NULL
        ? 0
        : atomic_load_explicit(&probe->input_signal_samples, memory_order_relaxed);
}

uint32_t mavo_uac_probe_input_signal_threshold_pcm16(const MaVoUACProbe *probe) {
    (void)probe;
    return MAVO_UAC_SIGNAL_THRESHOLD_PCM16;
}

const char *mavo_uac_probe_last_error(const MaVoUACProbe *probe) {
    return probe == NULL ? "UAC probe is not allocated" : probe->last_error;
}
