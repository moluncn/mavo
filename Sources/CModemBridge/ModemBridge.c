#include "CModemBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>
#include <IOKit/usb/USBSpec.h>
#include <limits.h>
#include <ctype.h>
#include <mach/mach_error.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef MAVO_AT_INTERFACE
#define MAVO_AT_INTERFACE 2
#endif
#define MAVO_ENDPOINT_IN 0x84
#define MAVO_ENDPOINT_OUT 0x03
#ifndef MAVO_VOICE_INTERFACE
#define MAVO_VOICE_INTERFACE 1
#endif
#define MAVO_IO_TIMEOUT_SLICE_MS 200
#define MAVO_RESYNC_READ_SLICE_MS 100
#define MAVO_RESYNC_QUIET_MS 1500
#define MAVO_RESYNC_DEADLINE_MS 5000
#define MAVO_PENDING_EVENT_CAPACITY (256U * 1024U)

static uint64_t monotonic_milliseconds(void);
static int read_modem_pipe(
    MaVoModem *modem,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

struct MaVoModem {
    pthread_mutex_t interface_lock;
    int interruptible_read_active;
    int interruptible_read_cancelled;
    IOUSBInterfaceInterface550 **interface;
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;
    uint64_t registry_id;
    uint8_t pipe_in;
    uint8_t pipe_out;
    uint8_t endpoint_in;
    uint8_t endpoint_out;
    MaVoModemStreamCallback stream_callback;
    void *stream_context;
    char pending_events[MAVO_PENDING_EVENT_CAPACITY];
    size_t pending_event_length;
    char last_error[256];
};

struct MaVoVoice {
    IOUSBInterfaceInterface550 **interface;
    uint8_t interface_number;
    uint8_t pipe_in;
    uint8_t pipe_out;
    uint8_t endpoint_in;
    uint8_t endpoint_out;
    char last_error[256];
};

static void set_error(MaVoModem *modem, const char *message) {
    if (modem == NULL) {
        return;
    }
    if (message == NULL) {
        modem->last_error[0] = '\0';
        return;
    }
    snprintf(modem->last_error, sizeof(modem->last_error), "%s", message);
}

static void set_io_error(MaVoModem *modem, const char *operation, IOReturn code) {
    if (modem == NULL) {
        return;
    }
    const char *description = mach_error_string(code);
    snprintf(
        modem->last_error,
        sizeof(modem->last_error),
        "%s: %s (0x%08x)",
        operation,
        description == NULL ? "I/O Kit error" : description,
        (unsigned int)code
    );
}

static void set_voice_error(MaVoVoice *voice, const char *message) {
    if (voice == NULL) {
        return;
    }
    if (message == NULL) {
        voice->last_error[0] = '\0';
        return;
    }
    snprintf(voice->last_error, sizeof(voice->last_error), "%s", message);
}

static void set_voice_io_error(MaVoVoice *voice, const char *operation, IOReturn code) {
    if (voice == NULL) {
        return;
    }
    const char *description = mach_error_string(code);
    snprintf(
        voice->last_error,
        sizeof(voice->last_error),
        "%s: %s (0x%08x)",
        operation,
        description == NULL ? "I/O Kit error" : description,
        (unsigned int)code
    );
}

static void append_pending_event_bytes(MaVoModem *modem, const char *bytes, size_t length) {
    if (modem == NULL || bytes == NULL || length == 0) {
        return;
    }
    if (length >= MAVO_PENDING_EVENT_CAPACITY) {
        bytes += length - MAVO_PENDING_EVENT_CAPACITY;
        length = MAVO_PENDING_EVENT_CAPACITY;
        modem->pending_event_length = 0;
    }
    size_t required = modem->pending_event_length + length;
    if (required > MAVO_PENDING_EVENT_CAPACITY) {
        size_t discard = required - MAVO_PENDING_EVENT_CAPACITY;
        memmove(
            modem->pending_events,
            modem->pending_events + discard,
            modem->pending_event_length - discard
        );
        modem->pending_event_length -= discard;
    }
    memcpy(modem->pending_events + modem->pending_event_length, bytes, length);
    modem->pending_event_length += length;
}

static int integer_property(io_service_t service, CFStringRef key, int *value) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(
        service,
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
    Boolean converted = CFNumberGetValue(
        (CFNumberRef)property,
        kCFNumberIntType,
        value
    );
    CFRelease(property);
    return converted ? 1 : 0;
}

static io_service_t find_known_interface(
    int target_interface,
    uint32_t required_location_id,
    uint16_t *vendor_id,
    uint16_t *product_id,
    uint32_t *location_id,
    uint64_t *registry_id
) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBInterfaceClassName);
    if (matching == NULL) {
        return IO_OBJECT_NULL;
    }
    IOReturn result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        matching,
        &iterator
    );
    if (result != kIOReturnSuccess) {
        return IO_OBJECT_NULL;
    }

    io_service_t selected = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        int vendor = 0;
        int product = 0;
        int interface_number = -1;
        int location = 0;
        integer_property(candidate, CFSTR("idVendor"), &vendor);
        integer_property(candidate, CFSTR("idProduct"), &product);
        integer_property(candidate, CFSTR("bInterfaceNumber"), &interface_number);
        integer_property(candidate, CFSTR("locationID"), &location);

        int is_known_identity =
            (vendor == 0x2C7C && product == 0x0125) ||
            (vendor == 0x2CA3 && product == 0x4006);
        if (is_known_identity &&
            interface_number == target_interface &&
            (required_location_id == 0 || (uint32_t)location == required_location_id)) {
            selected = candidate;
            *vendor_id = (uint16_t)vendor;
            *product_id = (uint16_t)product;
            if (location_id != NULL) {
                *location_id = (uint32_t)location;
            }
            if (registry_id != NULL) {
                uint64_t value = 0;
                if (IORegistryEntryGetRegistryEntryID(candidate, &value) == kIOReturnSuccess) {
                    *registry_id = value;
                }
            }
            break;
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);
    return selected;
}

static int discover_bulk_pipes(MaVoModem *modem) {
    UInt8 endpoint_count = 0;
    IOReturn result = (*modem->interface)->GetNumEndpoints(
        modem->interface,
        &endpoint_count
    );
    if (result != kIOReturnSuccess) {
        set_io_error(modem, "enumerate AT endpoints", result);
        return (int)result;
    }

    for (UInt8 pipe = 1; pipe <= endpoint_count; pipe++) {
        UInt8 direction = 0;
        UInt8 number = 0;
        UInt8 transfer_type = 0;
        UInt8 interval = 0;
        UInt16 max_packet_size = 0;
        result = (*modem->interface)->GetPipeProperties(
            modem->interface,
            pipe,
            &direction,
            &number,
            &transfer_type,
            &max_packet_size,
            &interval
        );
        if (result != kIOReturnSuccess || transfer_type != kUSBBulk) {
            continue;
        }
        uint8_t address = (uint8_t)(
            number | (direction == kUSBIn ? 0x80U : 0U)
        );
        if (direction == kUSBIn && address == MAVO_ENDPOINT_IN) {
            modem->pipe_in = pipe;
            modem->endpoint_in = address;
        } else if (direction == kUSBOut && address == MAVO_ENDPOINT_OUT) {
            modem->pipe_out = pipe;
            modem->endpoint_out = address;
        }
    }

    if (modem->pipe_in == 0 || modem->pipe_out == 0) {
        set_error(modem, "AT interface 2 does not expose bulk IN 0x84 / OUT 0x03");
        return MAVO_MODEM_NOT_FOUND;
    }
    return MAVO_MODEM_OK;
}

static int discover_voice_bulk_pipes(MaVoVoice *voice) {
    UInt8 endpoint_count = 0;
    IOReturn result = (*voice->interface)->GetNumEndpoints(
        voice->interface,
        &endpoint_count
    );
    if (result != kIOReturnSuccess) {
        set_voice_io_error(voice, "enumerate voice endpoints", result);
        return (int)result;
    }

    for (UInt8 pipe = 1; pipe <= endpoint_count; pipe++) {
        UInt8 direction = 0;
        UInt8 number = 0;
        UInt8 transfer_type = 0;
        UInt8 interval = 0;
        UInt16 max_packet_size = 0;
        result = (*voice->interface)->GetPipeProperties(
            voice->interface,
            pipe,
            &direction,
            &number,
            &transfer_type,
            &max_packet_size,
            &interval
        );
        if (result != kIOReturnSuccess || transfer_type != kUSBBulk) {
            continue;
        }
        uint8_t address = (uint8_t)(
            number | (direction == kUSBIn ? 0x80U : 0U)
        );
        if (direction == kUSBIn && voice->pipe_in == 0) {
            voice->pipe_in = pipe;
            voice->endpoint_in = address;
        } else if (direction == kUSBOut && voice->pipe_out == 0) {
            voice->pipe_out = pipe;
            voice->endpoint_out = address;
        }
    }

    if (voice->pipe_in == 0 || voice->pipe_out == 0) {
        snprintf(
            voice->last_error,
            sizeof(voice->last_error),
            "USB interface %u does not expose one bulk IN and one bulk OUT pipe",
            voice->interface_number
        );
        return MAVO_MODEM_NOT_FOUND;
    }
    return MAVO_MODEM_OK;
}

MaVoModem *mavo_modem_create(void) {
    MaVoModem *modem = calloc(1, sizeof(MaVoModem));
    if (modem == NULL) {
        return NULL;
    }
    if (pthread_mutex_init(&modem->interface_lock, NULL) != 0) {
        free(modem);
        return NULL;
    }
    return modem;
}

void mavo_modem_close(MaVoModem *modem) {
    if (modem == NULL) {
        return;
    }
    IOUSBInterfaceInterface550 **interface = NULL;
    pthread_mutex_lock(&modem->interface_lock);
    interface = modem->interface;
    modem->interface = NULL;
    modem->vendor_id = 0;
    modem->product_id = 0;
    modem->location_id = 0;
    modem->registry_id = 0;
    modem->pipe_in = 0;
    modem->pipe_out = 0;
    modem->endpoint_in = 0;
    modem->endpoint_out = 0;
    pthread_mutex_unlock(&modem->interface_lock);

    if (interface != NULL) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
    }
}

void mavo_modem_destroy(MaVoModem *modem) {
    if (modem == NULL) {
        return;
    }
    mavo_modem_close(modem);
    pthread_mutex_destroy(&modem->interface_lock);
    free(modem);
}

static int drain_input_until_quiet(MaVoModem *modem) {
    char discarded[4096] = {0};
    uint64_t started = monotonic_milliseconds();
    uint64_t quiet_since = started;

    while (monotonic_milliseconds() - started < MAVO_RESYNC_DEADLINE_MS) {
        int result = read_modem_pipe(
            modem,
            MAVO_RESYNC_READ_SLICE_MS,
            discarded,
            sizeof(discarded)
        );
        uint64_t now = monotonic_milliseconds();
        if (!mavo_modem_is_open(modem)) {
            return result;
        }
        if (result == MAVO_MODEM_OK) {
            if (now - quiet_since >= MAVO_RESYNC_QUIET_MS) {
                return MAVO_MODEM_OK;
            }
            continue;
        }
        if (result > 0) {
            append_pending_event_bytes(modem, discarded, (size_t)result);
            quiet_since = now;
            continue;
        }
        return result;
    }

    set_error(modem, "AT input did not become quiet during stream resynchronization");
    return (int)kIOUSBTransactionTimeout;
}

static int synchronize_at_stream(MaVoModem *modem) {
    int result = drain_input_until_quiet(modem);
    if (result != MAVO_MODEM_OK) {
        return result;
    }

    char response[65536] = {0};
    result = mavo_modem_command(modem, "AT", 2000, response, sizeof(response));
    append_pending_event_bytes(modem, response, strnlen(response, sizeof(response)));
    if (result != MAVO_MODEM_OK) {
        return result;
    }

    /*
     * If a delayed terminal line completed the synchronization command early,
     * this second quiet drain consumes the real AT response. The next caller
     * therefore starts at a protocol boundary rather than inheriting stale OK.
     */
    return drain_input_until_quiet(modem);
}

int mavo_modem_open(MaVoModem *modem) {
    return mavo_modem_open_for_location(modem, 0);
}

int mavo_modem_open_for_location(MaVoModem *modem, uint32_t required_location_id) {
    if (modem == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (modem->interface != NULL) {
        return MAVO_MODEM_OK;
    }

    set_error(modem, NULL);
    uint16_t vendor_id = 0;
    uint16_t product_id = 0;
    uint32_t discovered_location_id = 0;
    uint64_t registry_id = 0;
    io_service_t service = find_known_interface(
        MAVO_AT_INTERFACE,
        required_location_id,
        &vendor_id,
        &product_id,
        &discovered_location_id,
        &registry_id
    );
    if (service == IO_OBJECT_NULL) {
        set_error(modem, "QDC507/Quectel USB module is not connected");
        return MAVO_MODEM_NOT_FOUND;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || plugin == NULL) {
        set_io_error(modem, "create AT interface user client", result);
        return result == kIOReturnSuccess
            ? (int)kIOReturnUnsupported
            : (int)result;
    }

    IOUSBInterfaceInterface550 **interface = NULL;
    HRESULT query_result = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID550),
        (LPVOID *)&interface
    );
    IODestroyPlugInInterface(plugin);
    if (query_result != S_OK || interface == NULL) {
        set_error(modem, "query AT interface plug-in failed");
        return MAVO_MODEM_NOT_OPEN;
    }

    result = (*interface)->USBInterfaceOpen(interface);
    if (result != kIOReturnSuccess) {
        set_io_error(modem, "open AT interface 2", result);
        (*interface)->Release(interface);
        return (int)result;
    }

    pthread_mutex_lock(&modem->interface_lock);
    modem->interface = interface;
    modem->vendor_id = vendor_id;
    modem->product_id = product_id;
    modem->location_id = discovered_location_id;
    modem->registry_id = registry_id;
    pthread_mutex_unlock(&modem->interface_lock);
    int pipe_result = discover_bulk_pipes(modem);
    if (pipe_result != MAVO_MODEM_OK) {
        mavo_modem_close(modem);
        return pipe_result;
    }
    int sync_result = synchronize_at_stream(modem);
    if (sync_result != MAVO_MODEM_OK) {
        mavo_modem_close(modem);
        return sync_result;
    }
    set_error(modem, NULL);
    return MAVO_MODEM_OK;
}

int mavo_modem_is_open(const MaVoModem *modem) {
    if (modem == NULL) {
        return 0;
    }
    pthread_mutex_t *lock = (pthread_mutex_t *)&modem->interface_lock;
    pthread_mutex_lock(lock);
    int is_open = modem->interface != NULL;
    pthread_mutex_unlock(lock);
    return is_open;
}

int mavo_modem_interrupt_read(MaVoModem *modem) {
    if (modem == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }

    pthread_mutex_lock(&modem->interface_lock);
    if (modem->interface == NULL) {
        pthread_mutex_unlock(&modem->interface_lock);
        return MAVO_MODEM_NOT_OPEN;
    }
    modem->interruptible_read_cancelled = 1;
    IOReturn result = kIOReturnSuccess;
    if (modem->interruptible_read_active && modem->pipe_in != 0) {
        result = (*modem->interface)->AbortPipe(
            modem->interface,
            modem->pipe_in
        );
    }
    pthread_mutex_unlock(&modem->interface_lock);
    return result == kIOReturnSuccess ? MAVO_MODEM_OK : (int)result;
}

uint16_t mavo_modem_vendor_id(const MaVoModem *modem) {
    return modem == NULL ? 0 : modem->vendor_id;
}

uint16_t mavo_modem_product_id(const MaVoModem *modem) {
    return modem == NULL ? 0 : modem->product_id;
}

uint32_t mavo_modem_location_id(const MaVoModem *modem) {
    return modem == NULL ? 0 : modem->location_id;
}

uint64_t mavo_modem_registry_id(const MaVoModem *modem) {
    return modem == NULL ? 0 : modem->registry_id;
}

uint8_t mavo_modem_input_endpoint(const MaVoModem *modem) {
    return modem == NULL ? 0 : modem->endpoint_in;
}

uint8_t mavo_modem_output_endpoint(const MaVoModem *modem) {
    return modem == NULL ? 0 : modem->endpoint_out;
}

void mavo_modem_set_stream_callback(
    MaVoModem *modem,
    MaVoModemStreamCallback callback,
    void *context
) {
    if (modem == NULL) {
        return;
    }
    modem->stream_callback = callback;
    modem->stream_context = context;
}

static int response_line_is_terminal(
    const char *line,
    size_t length,
    int include_call_results
) {
    static const char cme_error[] = "+CME ERROR:";
    static const char cms_error[] = "+CMS ERROR:";

    if ((length == 2 && memcmp(line, "OK", 2) == 0) ||
        (length == 5 && memcmp(line, "ERROR", 5) == 0)) {
        return 1;
    }

    /* A bare prefix is not a complete extended error result. */
    if (
        include_call_results &&
        ((length == 4 && memcmp(line, "BUSY", 4) == 0) ||
         (length == 7 && memcmp(line, "CONNECT", 7) == 0) ||
         (length == 12 && memcmp(line, "MO CONNECTED", 12) == 0) ||
         (length == 10 && memcmp(line, "NO CARRIER", 10) == 0) ||
         (length == 9 && memcmp(line, "NO ANSWER", 9) == 0) ||
         (length == 11 && memcmp(line, "NO DIALTONE", 11) == 0) ||
         (length == 12 && memcmp(line, "NO DIAL TONE", 12) == 0))
    ) {
        return 1;
    }

    return
        (length > sizeof(cme_error) - 1 &&
         memcmp(line, cme_error, sizeof(cme_error) - 1) == 0) ||
        (length > sizeof(cms_error) - 1 &&
         memcmp(line, cms_error, sizeof(cms_error) - 1) == 0);
}

static int response_is_complete(const char *buffer, int include_call_results) {
    const char *line = buffer;
    for (const char *cursor = buffer; *cursor != '\0'; cursor++) {
        if (*cursor != '\r' && *cursor != '\n') {
            continue;
        }

        /*
         * A trailing CR may be the first half of CRLF split across two USB
         * reads. Wait for the next byte so the remaining LF cannot leak into
         * the next command. LF is complete by itself; CR is complete once a
         * following byte is already in this response buffer.
         */
        if (*cursor == '\r' && cursor[1] == '\0') {
            continue;
        }
        if (response_line_is_terminal(
                line,
                (size_t)(cursor - line),
                include_call_results
            )) {
            return 1;
        }
        line = cursor + 1;
    }
    return 0;
}

static int is_timeout(IOReturn result) {
    return result == kIOUSBTransactionTimeout || result == kIOReturnTimeout;
}

static uint64_t monotonic_milliseconds(void) {
    struct timespec value = {0, 0};
    (void)clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * UINT64_C(1000) +
           (uint64_t)value.tv_nsec / UINT64_C(1000000);
}

static int modem_command_internal(
    MaVoModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity,
    int include_call_results
) {
    if (output != NULL && output_capacity > 0) {
        output[0] = '\0';
    }
    if (!mavo_modem_is_open(modem) || command == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (output == NULL || output_capacity < 2) {
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    if (timeout_ms <= 0) {
        set_error(modem, "AT command timeout must be positive");
        return (int)kIOReturnBadArgument;
    }

    size_t command_length = strlen(command);
    if (command_length >= UINT32_MAX) {
        set_error(modem, "AT command is too large");
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    char *wire_command = malloc(command_length + 1);
    if (wire_command == NULL) {
        set_error(modem, "unable to allocate AT command buffer");
        return (int)kIOReturnNoMemory;
    }
    memcpy(wire_command, command, command_length);
    wire_command[command_length] = '\r';
    IOReturn result = (*modem->interface)->WritePipeTO(
        modem->interface,
        modem->pipe_out,
        wire_command,
        (UInt32)(command_length + 1),
        1000,
        1000
    );
    free(wire_command);
    if (result != kIOReturnSuccess) {
        set_io_error(modem, "send AT command", result);
        /* The device may have accepted a partial command. Reconnect before
         * another command can consume a delayed result from this stream. */
        mavo_modem_close(modem);
        return (int)result;
    }

    size_t used = 0;
    uint64_t deadline = monotonic_milliseconds() + (uint64_t)timeout_ms;
    while (used + 1 < output_capacity) {
        uint64_t now = monotonic_milliseconds();
        if (now >= deadline) {
            break;
        }
        uint64_t remaining = deadline - now;
        UInt32 slice_ms = remaining < MAVO_IO_TIMEOUT_SLICE_MS
            ? (UInt32)remaining
            : (UInt32)MAVO_IO_TIMEOUT_SLICE_MS;
        if (slice_ms == 0) {
            break;
        }
        size_t available = output_capacity - used - 1;
        UInt32 received = available > UINT32_MAX ? UINT32_MAX : (UInt32)available;
        result = (*modem->interface)->ReadPipeTO(
            modem->interface,
            modem->pipe_in,
            output + used,
            &received,
            slice_ms,
            slice_ms
        );
        if (result == kIOReturnSuccess) {
            if ((size_t)received > available) {
                output[used] = '\0';
                set_error(modem, "AT interface reported an invalid response length");
                mavo_modem_close(modem);
                return (int)kIOReturnOverrun;
            }
            if (received > 0 && modem->stream_callback != NULL) {
                modem->stream_callback(
                    modem->stream_context,
                    (const uint8_t *)(output + used),
                    (size_t)received
                );
            }
            used += received;
            output[used] = '\0';
            if (response_is_complete(output, include_call_results)) {
                set_error(modem, NULL);
                return MAVO_MODEM_OK;
            }
            continue;
        }
        if (is_timeout(result)) {
            continue;
        }
        set_io_error(modem, "read AT response", result);
        /* A failed command transaction leaves stream framing unknowable. */
        mavo_modem_close(modem);
        return (int)result;
    }

    output[used] = '\0';
    if (used + 1 >= output_capacity) {
        set_error(modem, "AT response exceeded the receive buffer");
        mavo_modem_close(modem);
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    set_error(modem, "AT command timed out before a terminal response");
    mavo_modem_close(modem);
    return (int)kIOUSBTransactionTimeout;
}

int mavo_modem_command(
    MaVoModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity
) {
    return modem_command_internal(
        modem,
        command,
        timeout_ms,
        output,
        output_capacity,
        0
    );
}

int mavo_modem_call_command(
    MaVoModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity
) {
    return modem_command_internal(
        modem,
        command,
        timeout_ms,
        output,
        output_capacity,
        1
    );
}

static int buffer_contains_prompt(const char *buffer) {
    if (buffer == NULL) {
        return 0;
    }
    for (const char *cursor = buffer; *cursor != '\0'; cursor++) {
        if (*cursor == '>') {
            return 1;
        }
    }
    return 0;
}

static int read_until_prompt_or_terminal(
    MaVoModem *modem,
    int timeout_ms,
    char *output,
    size_t output_capacity,
    size_t *used
) {
    uint64_t deadline = monotonic_milliseconds() + (uint64_t)timeout_ms;
    while (*used + 1 < output_capacity) {
        uint64_t now = monotonic_milliseconds();
        if (now >= deadline) {
            break;
        }
        uint64_t remaining = deadline - now;
        UInt32 slice_ms = remaining < MAVO_IO_TIMEOUT_SLICE_MS
            ? (UInt32)remaining
            : (UInt32)MAVO_IO_TIMEOUT_SLICE_MS;
        size_t available = output_capacity - *used - 1;
        UInt32 received = available > UINT32_MAX ? UINT32_MAX : (UInt32)available;
        IOReturn result = (*modem->interface)->ReadPipeTO(
            modem->interface,
            modem->pipe_in,
            output + *used,
            &received,
            slice_ms,
            slice_ms
        );
        if (result == kIOReturnSuccess) {
            if ((size_t)received > available) {
                output[*used] = '\0';
                set_error(modem, "AT interface reported an invalid response length");
                mavo_modem_close(modem);
                return (int)kIOReturnOverrun;
            }
            if (received > 0 && modem->stream_callback != NULL) {
                modem->stream_callback(
                    modem->stream_context,
                    (const uint8_t *)(output + *used),
                    (size_t)received
                );
            }
            *used += received;
            output[*used] = '\0';
            if (buffer_contains_prompt(output) || response_is_complete(output, 0)) {
                return MAVO_MODEM_OK;
            }
            continue;
        }
        if (is_timeout(result)) {
            continue;
        }
        set_io_error(modem, "read AT+CMGS prompt", result);
        mavo_modem_close(modem);
        return (int)result;
    }
    output[*used] = '\0';
    if (*used + 1 >= output_capacity) {
        set_error(modem, "AT+CMGS prompt exceeded the receive buffer");
        mavo_modem_close(modem);
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    set_error(modem, "AT+CMGS timed out before the payload prompt");
    mavo_modem_close(modem);
    return (int)kIOUSBTransactionTimeout;
}

int mavo_modem_send_sms_pdu(
    MaVoModem *modem,
    const char *pdu,
    size_t tpdu_length,
    int timeout_ms,
    char *output,
    size_t output_capacity
) {
    if (output != NULL && output_capacity > 0) {
        output[0] = '\0';
    }
    if (!mavo_modem_is_open(modem) || pdu == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (output == NULL || output_capacity < 2) {
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    if (timeout_ms <= 0 || tpdu_length == 0 || tpdu_length > 255) {
        set_error(modem, "invalid SMS PDU length or timeout");
        return (int)kIOReturnBadArgument;
    }

    size_t pdu_length = strlen(pdu);
    if (pdu_length < 2 || (pdu_length & 1U) != 0 || pdu_length >= UINT32_MAX) {
        set_error(modem, "SMS PDU must be nonempty, even-length hexadecimal ASCII");
        return (int)kIOReturnBadArgument;
    }
    for (size_t index = 0; index < pdu_length; index++) {
        if (!isxdigit((unsigned char)pdu[index])) {
            set_error(modem, "SMS PDU contains a non-hexadecimal byte");
            return (int)kIOReturnBadArgument;
        }
    }
    /* This bridge accepts only the application's SMSC-length-zero PDUs. */
    if (pdu[0] != '0' || pdu[1] != '0' || pdu_length / 2 != tpdu_length + 1) {
        set_error(modem, "SMS PDU length does not match AT+CMGS TPDU length");
        return (int)kIOReturnBadArgument;
    }

    char command[32];
    int command_length = snprintf(command, sizeof(command), "AT+CMGS=%zu\r", tpdu_length);
    if (command_length <= 0 || (size_t)command_length >= sizeof(command)) {
        set_error(modem, "unable to format AT+CMGS command");
        return (int)kIOReturnBadArgument;
    }
    IOReturn result = (*modem->interface)->WritePipeTO(
        modem->interface,
        modem->pipe_out,
        command,
        (UInt32)command_length,
        1000,
        1000
    );
    if (result != kIOReturnSuccess) {
        set_io_error(modem, "send AT+CMGS command", result);
        mavo_modem_close(modem);
        return (int)result;
    }

    size_t used = 0;
    int prompt_result = read_until_prompt_or_terminal(
        modem,
        timeout_ms < 10000 ? timeout_ms : 10000,
        output,
        output_capacity,
        &used
    );
    if (prompt_result != MAVO_MODEM_OK) {
        return prompt_result;
    }
    if (!buffer_contains_prompt(output)) {
        /* ERROR/+CMS ERROR is a completed command, and no payload was sent. */
        set_error(modem, NULL);
        return MAVO_MODEM_OK;
    }

    char *wire_pdu = malloc(pdu_length + 1);
    if (wire_pdu == NULL) {
        set_error(modem, "unable to allocate SMS PDU buffer");
        mavo_modem_close(modem);
        return (int)kIOReturnNoMemory;
    }
    memcpy(wire_pdu, pdu, pdu_length);
    wire_pdu[pdu_length] = 0x1A;
    result = (*modem->interface)->WritePipeTO(
        modem->interface,
        modem->pipe_out,
        wire_pdu,
        (UInt32)(pdu_length + 1),
        5000,
        5000
    );
    free(wire_pdu);
    if (result != kIOReturnSuccess) {
        set_io_error(modem, "send SMS PDU payload (delivery state is unknown)", result);
        mavo_modem_close(modem);
        return (int)result;
    }

    uint64_t deadline = monotonic_milliseconds() + (uint64_t)timeout_ms;
    while (used + 1 < output_capacity) {
        uint64_t now = monotonic_milliseconds();
        if (now >= deadline) {
            break;
        }
        uint64_t remaining = deadline - now;
        UInt32 slice_ms = remaining < MAVO_IO_TIMEOUT_SLICE_MS
            ? (UInt32)remaining
            : (UInt32)MAVO_IO_TIMEOUT_SLICE_MS;
        size_t available = output_capacity - used - 1;
        UInt32 received = available > UINT32_MAX ? UINT32_MAX : (UInt32)available;
        result = (*modem->interface)->ReadPipeTO(
            modem->interface,
            modem->pipe_in,
            output + used,
            &received,
            slice_ms,
            slice_ms
        );
        if (result == kIOReturnSuccess) {
            if ((size_t)received > available) {
                output[used] = '\0';
                set_error(modem, "SMS submission response length is invalid; delivery state is unknown");
                mavo_modem_close(modem);
                return (int)kIOReturnOverrun;
            }
            if (received > 0 && modem->stream_callback != NULL) {
                modem->stream_callback(
                    modem->stream_context,
                    (const uint8_t *)(output + used),
                    (size_t)received
                );
            }
            used += received;
            output[used] = '\0';
            if (response_is_complete(output, 0)) {
                set_error(modem, NULL);
                return MAVO_MODEM_OK;
            }
            continue;
        }
        if (is_timeout(result)) {
            continue;
        }
        set_io_error(modem, "read SMS submission response (delivery state is unknown)", result);
        mavo_modem_close(modem);
        return (int)result;
    }

    output[used] = '\0';
    if (used + 1 >= output_capacity) {
        set_error(modem, "SMS submission response exceeded the buffer; delivery state is unknown");
        mavo_modem_close(modem);
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    set_error(modem, "SMS submission was not confirmed; delivery state is unknown, do not retry automatically");
    mavo_modem_close(modem);
    return (int)kIOUSBTransactionTimeout;
}

static int read_modem_pipe(
    MaVoModem *modem,
    int timeout_ms,
    char *output,
    size_t output_capacity
) {
    if (output != NULL && output_capacity > 0) {
        output[0] = '\0';
    }
    if (!mavo_modem_is_open(modem)) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (output == NULL || output_capacity < 2) {
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    if (timeout_ms <= 0) {
        return (int)kIOReturnBadArgument;
    }

    pthread_mutex_lock(&modem->interface_lock);
    if (modem->interface == NULL || modem->pipe_in == 0) {
        pthread_mutex_unlock(&modem->interface_lock);
        return MAVO_MODEM_NOT_OPEN;
    }
    if (modem->interruptible_read_cancelled) {
        modem->interruptible_read_cancelled = 0;
        pthread_mutex_unlock(&modem->interface_lock);
        return MAVO_MODEM_OK;
    }
    IOUSBInterfaceInterface550 **interface = modem->interface;
    UInt8 pipe_in = modem->pipe_in;
    modem->interruptible_read_active = 1;
    pthread_mutex_unlock(&modem->interface_lock);

    size_t available = output_capacity - 1;
    UInt32 received = available > UINT32_MAX ? UINT32_MAX : (UInt32)available;
    IOReturn result = (*interface)->ReadPipeTO(
        interface,
        pipe_in,
        output,
        &received,
        (UInt32)timeout_ms,
        (UInt32)timeout_ms
    );
    pthread_mutex_lock(&modem->interface_lock);
    modem->interruptible_read_active = 0;
    int was_cancelled = modem->interruptible_read_cancelled;
    modem->interruptible_read_cancelled = 0;
    pthread_mutex_unlock(&modem->interface_lock);
    if (was_cancelled) {
        return MAVO_MODEM_OK;
    }
    if (is_timeout(result)) {
        return MAVO_MODEM_OK;
    }
    if (result != kIOReturnSuccess) {
        set_io_error(modem, "read modem event", result);
        mavo_modem_close(modem);
        return (int)result;
    }
    if ((size_t)received > available) {
        set_error(modem, "AT interface reported an invalid event length");
        mavo_modem_close(modem);
        return (int)kIOReturnOverrun;
    }
    output[received] = '\0';
    return received > INT_MAX ? INT_MAX : (int)received;
}

int mavo_modem_read(
    MaVoModem *modem,
    int timeout_ms,
    char *output,
    size_t output_capacity
) {
    if (output != NULL && output_capacity > 0) {
        output[0] = '\0';
    }
    if (!mavo_modem_is_open(modem)) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (output == NULL || output_capacity < 2) {
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    if (timeout_ms <= 0) {
        return (int)kIOReturnBadArgument;
    }

    if (modem->pending_event_length > 0) {
        size_t copied = modem->pending_event_length;
        if (copied > output_capacity - 1) {
            copied = output_capacity - 1;
        }
        memcpy(output, modem->pending_events, copied);
        memmove(
            modem->pending_events,
            modem->pending_events + copied,
            modem->pending_event_length - copied
        );
        modem->pending_event_length -= copied;
        output[copied] = '\0';
        return copied > INT_MAX ? INT_MAX : (int)copied;
    }

    return read_modem_pipe(modem, timeout_ms, output, output_capacity);
}

const char *mavo_modem_last_error(const MaVoModem *modem) {
    if (modem == NULL) {
        return "modem bridge is not initialized";
    }
    return modem->last_error;
}

MaVoVoice *mavo_voice_create(void) {
    return calloc(1, sizeof(MaVoVoice));
}

void mavo_voice_close(MaVoVoice *voice) {
    if (voice == NULL) {
        return;
    }
    if (voice->interface != NULL) {
        (*voice->interface)->USBInterfaceClose(voice->interface);
        (*voice->interface)->Release(voice->interface);
    }
    voice->interface = NULL;
    voice->interface_number = 0;
    voice->pipe_in = 0;
    voice->pipe_out = 0;
    voice->endpoint_in = 0;
    voice->endpoint_out = 0;
}

void mavo_voice_destroy(MaVoVoice *voice) {
    if (voice == NULL) {
        return;
    }
    mavo_voice_close(voice);
    free(voice);
}

static int open_voice_at_location(
    MaVoVoice *voice,
    uint32_t location_id,
    uint8_t interface_number
) {
    if (voice == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (voice->interface != NULL) {
        return MAVO_MODEM_OK;
    }

    set_voice_error(voice, NULL);
    uint16_t vendor_id = 0;
    uint16_t product_id = 0;
    io_service_t service = find_known_interface(
        interface_number,
        location_id,
        &vendor_id,
        &product_id,
        NULL,
        NULL
    );
    if (service == IO_OBJECT_NULL) {
        snprintf(
            voice->last_error,
            sizeof(voice->last_error),
            "QDC507 USB interface %u is not connected",
            interface_number
        );
        return MAVO_MODEM_NOT_FOUND;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || plugin == NULL) {
        set_voice_io_error(voice, "create voice interface user client", result);
        return result == kIOReturnSuccess
            ? (int)kIOReturnUnsupported
            : (int)result;
    }

    IOUSBInterfaceInterface550 **interface = NULL;
    HRESULT query_result = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID550),
        (LPVOID *)&interface
    );
    IODestroyPlugInInterface(plugin);
    if (query_result != S_OK || interface == NULL) {
        set_voice_error(voice, "query voice interface plug-in failed");
        return MAVO_MODEM_NOT_OPEN;
    }

    result = (*interface)->USBInterfaceOpen(interface);
    if (result != kIOReturnSuccess) {
        char operation[64];
        snprintf(operation, sizeof(operation), "open USB interface %u", interface_number);
        set_voice_io_error(voice, operation, result);
        (*interface)->Release(interface);
        return (int)result;
    }

    voice->interface = interface;
    voice->interface_number = interface_number;
    int pipe_result = discover_voice_bulk_pipes(voice);
    if (pipe_result != MAVO_MODEM_OK) {
        mavo_voice_close(voice);
        return pipe_result;
    }
    set_voice_error(voice, NULL);
    return MAVO_MODEM_OK;
}

int mavo_voice_open(MaVoVoice *voice) {
    return open_voice_at_location(voice, 0, MAVO_VOICE_INTERFACE);
}

int mavo_voice_open_for_location(MaVoVoice *voice, uint32_t location_id) {
    if (voice == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (location_id == 0) {
        set_voice_error(voice, "voice locationID must be non-zero");
        return (int)kIOReturnBadArgument;
    }
    return open_voice_at_location(voice, location_id, MAVO_VOICE_INTERFACE);
}

int mavo_voice_open_interface(MaVoVoice *voice, uint8_t interface_number) {
    return open_voice_at_location(voice, 0, interface_number);
}

int mavo_voice_open_interface_for_location(
    MaVoVoice *voice,
    uint32_t location_id,
    uint8_t interface_number
) {
    if (voice == NULL) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (location_id == 0) {
        set_voice_error(voice, "USB interface locationID must be non-zero");
        return (int)kIOReturnBadArgument;
    }
    return open_voice_at_location(voice, location_id, interface_number);
}

int mavo_voice_is_open(const MaVoVoice *voice) {
    return voice != NULL && voice->interface != NULL;
}

uint8_t mavo_voice_input_endpoint(const MaVoVoice *voice) {
    return voice == NULL ? 0 : voice->endpoint_in;
}

uint8_t mavo_voice_output_endpoint(const MaVoVoice *voice) {
    return voice == NULL ? 0 : voice->endpoint_out;
}

int mavo_voice_clear_stalls(MaVoVoice *voice) {
    if (!mavo_voice_is_open(voice)) {
        return MAVO_MODEM_NOT_OPEN;
    }

    IOReturn result = (*voice->interface)->ClearPipeStallBothEnds(
        voice->interface,
        voice->pipe_out
    );
    if (result != kIOReturnSuccess) {
        set_voice_io_error(voice, "clear USB output endpoint stall", result);
        return (int)result;
    }
    result = (*voice->interface)->ClearPipeStallBothEnds(
        voice->interface,
        voice->pipe_in
    );
    if (result != kIOReturnSuccess) {
        set_voice_io_error(voice, "clear USB input endpoint stall", result);
        return (int)result;
    }
    set_voice_error(voice, NULL);
    return MAVO_MODEM_OK;
}

int mavo_voice_read(
    MaVoVoice *voice,
    int timeout_ms,
    uint8_t *output,
    size_t output_capacity
) {
    if (!mavo_voice_is_open(voice)) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (output == NULL || output_capacity == 0) {
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    if (timeout_ms <= 0) {
        set_voice_error(voice, "voice read timeout must be positive");
        return (int)kIOReturnBadArgument;
    }

    UInt32 received = output_capacity > UINT32_MAX
        ? UINT32_MAX
        : (UInt32)output_capacity;
    IOReturn result = (*voice->interface)->ReadPipeTO(
        voice->interface,
        voice->pipe_in,
        output,
        &received,
        (UInt32)timeout_ms,
        (UInt32)timeout_ms
    );
    if (is_timeout(result)) {
        return MAVO_MODEM_OK;
    }
    if (result != kIOReturnSuccess) {
        set_voice_io_error(voice, "read voice PCM", result);
        mavo_voice_close(voice);
        return (int)result;
    }
    set_voice_error(voice, NULL);
    return received > INT_MAX ? INT_MAX : (int)received;
}

int mavo_voice_write(
    MaVoVoice *voice,
    int timeout_ms,
    const uint8_t *bytes,
    size_t length
) {
    if (!mavo_voice_is_open(voice)) {
        return MAVO_MODEM_NOT_OPEN;
    }
    if (bytes == NULL || length == 0 || length > UINT32_MAX) {
        return MAVO_MODEM_BUFFER_TOO_SMALL;
    }
    if (timeout_ms <= 0) {
        set_voice_error(voice, "voice write timeout must be positive");
        return (int)kIOReturnBadArgument;
    }

    IOReturn result = (*voice->interface)->WritePipeTO(
        voice->interface,
        voice->pipe_out,
        (void *)bytes,
        (UInt32)length,
        (UInt32)timeout_ms,
        (UInt32)timeout_ms
    );
    if (result != kIOReturnSuccess) {
        set_voice_io_error(voice, "write voice PCM", result);
        mavo_voice_close(voice);
        return (int)result;
    }
    set_voice_error(voice, NULL);
    return MAVO_MODEM_OK;
}

const char *mavo_voice_last_error(const MaVoVoice *voice) {
    if (voice == NULL) {
        return "voice bridge is not initialized";
    }
    return voice->last_error;
}
