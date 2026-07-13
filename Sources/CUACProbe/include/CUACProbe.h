#ifndef C_UAC_PROBE_H
#define C_UAC_PROBE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MaVoUACProbe MaVoUACProbe;

enum {
    MAVO_UAC_OK = 0,
    MAVO_UAC_NOT_FOUND = 1,
    MAVO_UAC_AMBIGUOUS = 2,
    MAVO_UAC_UNSUPPORTED = 3,
    MAVO_UAC_NOT_OPEN = 4
};

MaVoUACProbe *mavo_uac_probe_create(void);
void mavo_uac_probe_destroy(MaVoUACProbe *probe);
/* Returns MAVO_UAC_OK only after every IOProc is stopped/destroyed, any changed
 * rate is restored, and the probe has been freed. On failure the caller still
 * owns the live probe and must retain it for a later retry. */
int mavo_uac_probe_try_destroy(MaVoUACProbe *probe);

/*
 * Selects, but does not start, a CoreAudio USB input/output pair. The pair may
 * be one full-duplex AudioDeviceID or separate input-only and output-only
 * AudioDeviceIDs. Each endpoint must either map through IOAudioEngine, or have
 * a canonical AppleUSBAudioEngine UID whose location/interface fields match a
 * unique IOUSBHostInterface, with the exact VID/PID/location supplied by the
 * AT bridge. Split endpoints must be mutually listed by CoreAudio's
 * RelatedDevices property and resolve to the same physical IOUSBHostDevice
 * registry entry. Device names are never used for binding. preferred_uid may
 * identify either pair member or the combined string from mavo_uac_probe_uid().
 */
int mavo_uac_probe_open_for_usb(
    MaVoUACProbe *probe,
    uint16_t vendor_id,
    uint16_t product_id,
    uint32_t location_id,
    const char *preferred_uid
);
void mavo_uac_probe_close(MaVoUACProbe *probe);
int mavo_uac_probe_is_open(const MaVoUACProbe *probe);
/* True only when every selected endpoint is running. A failed partial start
 * remains discoverable through last_error and is retried by stop/close. */
int mavo_uac_probe_is_running(const MaVoUACProbe *probe);
/* Cleanup diagnostics for long-lived hot-plug owners. original_devices_alive
 * returns true only while at least one selected AudioDeviceID is alive and
 * still has the UID captured at open. */
int mavo_uac_probe_original_devices_alive(const MaVoUACProbe *probe);
/* 1: the original physical IORegistry ancestor still exists; 0: it is
 * definitively absent; -1: identity/query unavailable. */
int mavo_uac_probe_original_usb_present(const MaVoUACProbe *probe);
uint32_t mavo_uac_probe_callbacks_in_flight(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_callback_sequence(const MaVoUACProbe *probe);

uint32_t mavo_uac_probe_device_id(const MaVoUACProbe *probe);
/* For a split pair, device_id is the input member while name and UID describe
 * both members. */
const char *mavo_uac_probe_name(const MaVoUACProbe *probe);
const char *mavo_uac_probe_uid(const MaVoUACProbe *probe);
double mavo_uac_probe_sample_rate(const MaVoUACProbe *probe);
uint32_t mavo_uac_probe_input_device_id(const MaVoUACProbe *probe);
uint32_t mavo_uac_probe_output_device_id(const MaVoUACProbe *probe);
const char *mavo_uac_probe_input_name(const MaVoUACProbe *probe);
const char *mavo_uac_probe_output_name(const MaVoUACProbe *probe);
const char *mavo_uac_probe_input_uid(const MaVoUACProbe *probe);
const char *mavo_uac_probe_output_uid(const MaVoUACProbe *probe);
double mavo_uac_probe_input_sample_rate(const MaVoUACProbe *probe);
double mavo_uac_probe_output_sample_rate(const MaVoUACProbe *probe);
uint32_t mavo_uac_probe_input_channels(const MaVoUACProbe *probe);
uint32_t mavo_uac_probe_output_channels(const MaVoUACProbe *probe);
int mavo_uac_probe_usb_binding_verified(const MaVoUACProbe *probe);

/*
 * Sets each selected device to 8 kHz and creates one IOProc per distinct
 * AudioDeviceID. The input callback converts downlink into the PCM16 ring; the
 * output callback consumes the uplink ring and zero-fills any underrun. Both
 * formats support mono virtual-ASBD Float32 and signed Int16 linear PCM.
 * close/destroy stop and destroy each IOProc before restoring sample rates.
 */
int mavo_uac_probe_start_silence(MaVoUACProbe *probe);
/* Starts the same realtime-safe IOProc with PCM16 rings enabled. With no
 * uplink frames queued, the output callback writes silence, so the legacy
 * start_silence entry point remains a compatible diagnostic wrapper. */
int mavo_uac_probe_start_pcm_bridge(MaVoUACProbe *probe);
int mavo_uac_probe_stop(MaVoUACProbe *probe);

/* Mono 8 kHz PCM16 frame APIs. These functions never call a CoreAudio
 * callback and may be used from a non-realtime worker. Returns frames copied
 * or accepted; a full uplink ring drops new frames to keep the callback
 * lock-free. */
size_t mavo_uac_probe_read_downlink_pcm16(
    MaVoUACProbe *probe,
    int16_t *frames,
    size_t maximum_frames
);
size_t mavo_uac_probe_write_uplink_pcm16(
    MaVoUACProbe *probe,
    const int16_t *frames,
    size_t frame_count
);
void mavo_uac_probe_flush_pcm(MaVoUACProbe *probe);
void mavo_uac_probe_flush_downlink_pcm(MaVoUACProbe *probe);
void mavo_uac_probe_flush_uplink_pcm(MaVoUACProbe *probe);

uint64_t mavo_uac_probe_input_callbacks(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_output_callbacks(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_input_frames(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_output_frames(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_input_bytes(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_output_bytes(const MaVoUACProbe *probe);
/* Input samples are normalized to absolute PCM16 magnitude (0...32768).
 * signal_samples counts magnitudes strictly above the reported threshold. */
uint32_t mavo_uac_probe_input_peak_pcm16(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_input_total_samples(const MaVoUACProbe *probe);
uint64_t mavo_uac_probe_input_signal_samples(const MaVoUACProbe *probe);
uint32_t mavo_uac_probe_input_signal_threshold_pcm16(const MaVoUACProbe *probe);

const char *mavo_uac_probe_last_error(const MaVoUACProbe *probe);

#ifdef __cplusplus
}
#endif

#endif
