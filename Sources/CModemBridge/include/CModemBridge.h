#ifndef C_MODEM_BRIDGE_H
#define C_MODEM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MaVoModem MaVoModem;
typedef struct MaVoVoice MaVoVoice;
typedef void (*MaVoModemStreamCallback)(
    void *context,
    const uint8_t *bytes,
    size_t length
);

enum {
    MAVO_MODEM_OK = 0,
    MAVO_MODEM_NOT_FOUND = 1,
    MAVO_MODEM_NOT_OPEN = 2,
    MAVO_MODEM_BUFFER_TOO_SMALL = 3
};

MaVoModem *mavo_modem_create(void);
void mavo_modem_destroy(MaVoModem *modem);

/*
 * Opens only IOUSBHostInterface 2, never the parent device or ECM interface,
 * and establishes a quiet AT protocol boundary before returning.
 */
int mavo_modem_open(MaVoModem *modem);
int mavo_modem_open_for_location(MaVoModem *modem, uint32_t location_id);
void mavo_modem_close(MaVoModem *modem);
int mavo_modem_is_open(const MaVoModem *modem);

/*
 * Aborts only a pending unsolicited-event/resynchronization read, without
 * resetting or closing the USB interface. Command and SMS response reads are
 * never interrupted. Calling this with no interruptible read is a safe no-op.
 */
int mavo_modem_interrupt_read(MaVoModem *modem);

uint16_t mavo_modem_vendor_id(const MaVoModem *modem);
uint16_t mavo_modem_product_id(const MaVoModem *modem);
uint32_t mavo_modem_location_id(const MaVoModem *modem);
uint64_t mavo_modem_registry_id(const MaVoModem *modem);
uint8_t mavo_modem_input_endpoint(const MaVoModem *modem);
uint8_t mavo_modem_output_endpoint(const MaVoModem *modem);
void mavo_modem_set_stream_callback(
    MaVoModem *modem,
    MaVoModemStreamCallback callback,
    void *context
);

/*
 * Sends one ASCII AT command and waits for OK/ERROR. The response is always
 * NUL-terminated when output_capacity is greater than zero. A timeout,
 * transport error, or malformed/oversized response closes the AT interface;
 * callers must reopen it before issuing another command.
 */
int mavo_modem_command(
    MaVoModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

/* Dial/answer commands may finish with a call result instead of OK/ERROR. */
int mavo_modem_call_command(
    MaVoModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

/*
 * Submits one SMS-SUBMIT PDU using the two-stage AT+CMGS prompt protocol.
 * pdu must contain ASCII hexadecimal digits including the SMSC length octet;
 * tpdu_length excludes that SMSC field, as required by AT+CMGS.
 *
 * The payload is never written unless a '>' prompt is observed. After the
 * payload and Ctrl-Z are written, a timeout is intentionally ambiguous and
 * closes the interface so callers cannot accidentally retry the same SMS.
 */
int mavo_modem_send_sms_pdu(
    MaVoModem *modem,
    const char *pdu,
    size_t tpdu_length,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

/*
 * Reads already pending unsolicited bytes. Timeout is intentionally short.
 * Bytes observed while establishing a quiet protocol boundary are returned
 * here before new USB reads, so resynchronization cannot swallow URCs. A
 * non-timeout transport/protocol error closes the AT interface.
 */
int mavo_modem_read(
    MaVoModem *modem,
    int timeout_ms,
    char *output,
    size_t output_capacity
);

const char *mavo_modem_last_error(const MaVoModem *modem);

/*
 * Raw voice-over-USB transport for QPCMV option 0. This opens only USB
 * interface 1 (the NMEA/PCM port); it never opens or resets the parent USB
 * device and therefore can run alongside the AT and CDC-ECM interfaces.
 */
MaVoVoice *mavo_voice_create(void);
void mavo_voice_destroy(MaVoVoice *voice);
int mavo_voice_open(MaVoVoice *voice);
int mavo_voice_open_for_location(MaVoVoice *voice, uint32_t location_id);
int mavo_voice_open_interface(MaVoVoice *voice, uint8_t interface_number);
int mavo_voice_open_interface_for_location(
    MaVoVoice *voice,
    uint32_t location_id,
    uint8_t interface_number
);
/*
 * Opens a specific control interface and, if another user-space client owns
 * it, asks IOKit to transfer exclusive access. Intended for the module's ADB
 * interface only; AT, ECM and audio callers should keep using normal opens.
 */
int mavo_voice_open_control_interface_for_location(
    MaVoVoice *voice,
    uint32_t location_id,
    uint8_t interface_number
);

/*
 * Reads the process owner recorded by IOUSBHostInterface as
 * "pid <number>, <name>". Returns 1 when a process owner is present, otherwise
 * zero. This does not open, close, seize, or otherwise mutate the interface.
 */
int mavo_usb_interface_owner_process(
    uint32_t location_id,
    uint8_t interface_number,
    int32_t *process_id,
    char *process_name,
    size_t process_name_capacity
);
void mavo_voice_close(MaVoVoice *voice);
int mavo_voice_is_open(const MaVoVoice *voice);

uint8_t mavo_voice_input_endpoint(const MaVoVoice *voice);
uint8_t mavo_voice_output_endpoint(const MaVoVoice *voice);

/* Clears a recoverable USB endpoint halt without resetting the device. */
int mavo_voice_clear_stalls(MaVoVoice *voice);

/*
 * A successful read returns the number of PCM bytes received; a timeout
 * returns zero. Writes return MAVO_MODEM_OK on success. Any other return value
 * is an IOKit/bridge error and closes the voice interface.
 */
int mavo_voice_read(
    MaVoVoice *voice,
    int timeout_ms,
    uint8_t *output,
    size_t output_capacity
);
int mavo_voice_write(
    MaVoVoice *voice,
    int timeout_ms,
    const uint8_t *bytes,
    size_t length
);

const char *mavo_voice_last_error(const MaVoVoice *voice);

#ifdef __cplusplus
}
#endif

#endif
