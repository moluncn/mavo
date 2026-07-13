/*
 * MaVo raw voice bridge for Quectel MDM9x07 modules.
 *
 * This recreates the user-space part of AT+QPCMV=1,0 found in standard
 * Quectel firmware.  It does not dial a call and it does not change the USB
 * gadget layout.  It may start shortly before a call and waits a bounded time
 * for the voice PCM path; the Mac side exchanges signed 16-bit, mono, 8 kHz
 * PCM through /dev/ttyGS0.
 */

#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define DEFAULT_AUDIO_LIBRARY "libql_lib_audio.so.1"
#define DEFAULT_TTY_DEVICE "/dev/ttyGS0"
#define PCM_DEVICE "hw:0,0"

#define PCM_RATE 8000U
#define PCM_CHANNELS 1U
#define PCM_FORMAT_S16_LE 2U
#define PCM_HOSTLESS 0U
#define PCM_PLAYBACK_FLAGS 0x01000000U
#define PCM_CAPTURE_FLAGS 0x11000000U

#define VOICE_PCM_DEVICE "hw:0,4"
#define VOICE_PLAYBACK_FLAGS 0x01000001U
#define VOICE_CAPTURE_FLAGS 0x11000001U
#define VOICE_HOSTLESS 1U
#define VOICE_LEGACY_DOWNLINK_MIXER "SEC_AUX_PCM_RX_Voice Mixer VoLTE"
#define VOICE_LEGACY_UPLINK_MIXER "VoLTE_Tx Mixer SEC_AUX_PCM_TX_VoLTE"
#define VOICE_DOWNLINK_MIXER "AFE_PCM_RX_Voice Mixer VoLTE"
#define VOICE_UPLINK_MIXER "VoLTE_Tx Mixer AFE_PCM_TX_VoLTE"
#define VOICE_AUDIO_ENABLE_PATH "/sys/class/android_usb/f_audio/audio_enable"

#define IDLE_RETRY_USEC 20000U
#define STARTUP_RETRY_USEC 200000U
#define STARTUP_RETRY_LIMIT 100U
#define PARTIAL_WRITE_RETRY_USEC 5000U
#define SHUTDOWN_GRACE_USEC 3000000U
#define CANCEL_GRACE_USEC 1000000U

#define MIXER_UPLINK "Incall_Music Audio Mixer MultiMedia1"
#define MIXER_DOWNLINK "MultiMedia1 Mixer VOC_REC_DL"

typedef void *(*quec_pcm_open_fn)(const char *, unsigned int, unsigned int,
                                  unsigned int, unsigned int, unsigned int);
typedef int (*quec_pcm_close_fn)(void *);
typedef int (*quec_pcm_io_fn)(void *, void *, unsigned int);
typedef unsigned int (*quec_pcm_buffer_len_fn)(void *);
typedef int (*quec_set_mixer_fn)(const char *, int, const char *);

struct vendor_audio {
    void *library;
    quec_pcm_open_fn pcm_open;
    quec_pcm_close_fn pcm_close;
    quec_pcm_io_fn pcm_read;
    quec_pcm_io_fn pcm_write;
    quec_pcm_buffer_len_fn pcm_buffer_len;
    quec_set_mixer_fn set_mixer;
};

struct bridge_context {
    struct vendor_audio api;
    int tty_fd;
    const char *playback_device;
    const char *capture_device;
    struct termios saved_tty_attributes;
    int tty_attributes_saved;
    int use_mixers;
    int verbose;
    volatile int worker_failed;
};

static volatile sig_atomic_t stop_requested;

#if !defined(__GCC_ATOMIC_INT_LOCK_FREE) || __GCC_ATOMIC_INT_LOCK_FREE != 2
#error "This bridge requires lock-free int atomics on the target ABI"
#endif

static int should_stop(void)
{
    return __atomic_load_n(&stop_requested, __ATOMIC_RELAXED) != 0;
}

static void request_worker_stop(void)
{
    __atomic_store_n(&stop_requested, 1, __ATOMIC_RELAXED);
}

static void mark_worker_failed(struct bridge_context *context)
{
    __atomic_store_n(&context->worker_failed, 1, __ATOMIC_RELAXED);
    request_worker_stop();
}

static int worker_failed(const struct bridge_context *context)
{
    return __atomic_load_n(&context->worker_failed, __ATOMIC_RELAXED) != 0;
}

static void log_message(const char *level, const char *format, ...)
{
    char buffer[1024];
    va_list arguments;
    size_t used;
    size_t available;
    int count;
    ssize_t ignored;

    count = snprintf(buffer, sizeof(buffer), "mavo-pcm-bridge[%s]: ",
                     level);
    if (count < 0) {
        return;
    }
    used = (size_t)count;
    if (used >= sizeof(buffer) - 1U) {
        used = sizeof(buffer) - 2U;
    }
    available = sizeof(buffer) - used;
    va_start(arguments, format);
    count = vsnprintf(buffer + used, available, format, arguments);
    va_end(arguments);
    if (count < 0) {
        return;
    }
    if ((size_t)count >= available) {
        used = sizeof(buffer) - 2U;
    } else {
        used += (size_t)count;
    }
    buffer[used++] = '\n';

    do {
        ignored = write(STDERR_FILENO, buffer, used);
    } while (ignored < 0 && errno == EINTR);
}

static void request_stop(int signal_number)
{
    (void)signal_number;
    request_worker_stop();
}

static int install_signal_handlers(void)
{
    struct sigaction action;

    memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop;
    sigemptyset(&action.sa_mask);

    if (sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0) {
        log_message("error", "sigaction failed: %s", strerror(errno));
        return -1;
    }

    /* Do not install a SIGHUP handler.  An ignored disposition inherited from
     * nohup survives exec and must remain ignored when the ADB shell exits. */

    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_IGN;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, NULL) != 0) {
        log_message("error", "could not ignore SIGPIPE: %s", strerror(errno));
        return -1;
    }
    return 0;
}

static int load_symbol(void *library, const char *name, void *destination,
                       size_t destination_size)
{
    void *symbol;
    const char *error;

    dlerror();
    symbol = dlsym(library, name);
    error = dlerror();
    if (error != NULL || symbol == NULL) {
        log_message("error", "missing %s: %s", name,
                    error != NULL ? error : "symbol is null");
        return -1;
    }

    if (destination_size != sizeof(symbol)) {
        log_message("error", "unexpected function pointer size for %s", name);
        return -1;
    }
    memcpy(destination, &symbol, sizeof(symbol));
    return 0;
}

#define LOAD_API(api, member, symbol_name)                                      \
    load_symbol((api)->library, (symbol_name), &(api)->member,                  \
                sizeof((api)->member))

static int load_vendor_audio(struct vendor_audio *api, const char *library_path)
{
    memset(api, 0, sizeof(*api));

    api->library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (api->library == NULL) {
        log_message("error", "dlopen(%s) failed: %s", library_path, dlerror());
        return -1;
    }

    if (LOAD_API(api, pcm_open, "quec_pcm_open") != 0 ||
        LOAD_API(api, pcm_close, "quec_pcm_close") != 0 ||
        LOAD_API(api, pcm_read, "quec_read_pcm") != 0 ||
        LOAD_API(api, pcm_write, "quec_write_pcm") != 0 ||
        LOAD_API(api, pcm_buffer_len, "quec_get_pem_buffer_len") != 0 ||
        LOAD_API(api, set_mixer, "quectel_clt_set_mixer_value") != 0) {
        dlclose(api->library);
        memset(api, 0, sizeof(*api));
        return -1;
    }

    return 0;
}

static void unload_vendor_audio(struct vendor_audio *api)
{
    if (api->library != NULL) {
        dlclose(api->library);
    }
    memset(api, 0, sizeof(*api));
}

static int set_tty_attributes(int fd, const struct termios *attributes)
{
    int result;

    do {
        result = tcsetattr(fd, TCSANOW, attributes);
    } while (result != 0 && errno == EINTR);
    return result;
}

static int flush_tty(int fd)
{
    int result;

    do {
        result = tcflush(fd, TCIOFLUSH);
    } while (result != 0 && errno == EINTR);
    return result;
}

static int configure_raw_tty(struct bridge_context *context)
{
    struct termios attributes;
    int result;

    do {
        result = tcgetattr(context->tty_fd, &context->saved_tty_attributes);
    } while (result != 0 && errno == EINTR);
    if (result != 0) {
        log_message("error", "tcgetattr failed: %s", strerror(errno));
        return -1;
    }
    context->tty_attributes_saved = 1;
    attributes = context->saved_tty_attributes;

    cfmakeraw(&attributes);
    attributes.c_cflag &= (tcflag_t)~(tcflag_t)(CSIZE | PARENB | CSTOPB);
#ifdef CRTSCTS
    attributes.c_cflag &= (tcflag_t)~(tcflag_t)CRTSCTS;
#endif
    attributes.c_cflag |= CS8 | CLOCAL | CREAD;
    attributes.c_cc[VMIN] = 0;
    attributes.c_cc[VTIME] = 0;

    if (set_tty_attributes(context->tty_fd, &attributes) != 0) {
        log_message("error", "tcsetattr failed: %s", strerror(errno));
        return -1;
    }
    if (flush_tty(context->tty_fd) != 0) {
        log_message("warn", "initial tcflush failed: %s", strerror(errno));
    }
    return 0;
}

static int restore_tty(struct bridge_context *context)
{
    int result = 0;

    if (context->tty_fd < 0 || !context->tty_attributes_saved) {
        return 0;
    }
    if (flush_tty(context->tty_fd) != 0 && errno != EIO) {
        log_message("warn", "final tcflush failed: %s", strerror(errno));
        result = -1;
    }
    if (set_tty_attributes(context->tty_fd,
                           &context->saved_tty_attributes) != 0) {
        log_message("error", "could not restore tty attributes: %s",
                    strerror(errno));
        result = -1;
    }
    context->tty_attributes_saved = 0;
    return result;
}

static int valid_buffer_length(unsigned int length)
{
    /* Protect against an ABI mismatch before allocating or issuing I/O. */
    return length >= 160U && length <= 65536U && (length & 1U) == 0U;
}

static int enable_mixer_with_retry(struct bridge_context *context,
                                   const char *mixer_name)
{
    unsigned int attempt;

    for (attempt = 1U; attempt <= STARTUP_RETRY_LIMIT && !should_stop();
         ++attempt) {
        if (context->api.set_mixer(mixer_name, 1, "1") != 0) {
            return 1;
        }
        if (context->verbose && attempt == 1U) {
            log_message("info", "waiting for mixer %s", mixer_name);
        }
        usleep(STARTUP_RETRY_USEC);
    }
    return 0;
}

static void *open_pcm_with_retry(struct bridge_context *context,
                                 const char *device, unsigned int flags,
                                 const char *direction)
{
    unsigned int attempt;

    for (attempt = 1U; attempt <= STARTUP_RETRY_LIMIT && !should_stop();
         ++attempt) {
        void *pcm = context->api.pcm_open(
            device, flags, PCM_RATE, PCM_CHANNELS, PCM_FORMAT_S16_LE,
            PCM_HOSTLESS);

        if (pcm != NULL) {
            return pcm;
        }
        if (context->verbose && attempt == 1U) {
            log_message("info", "waiting for %s PCM %s", direction,
                        device);
        }
        usleep(STARTUP_RETRY_USEC);
    }
    return NULL;
}

static int set_voice_mixer(struct vendor_audio *api, const char *name,
                           const char *value)
{
    if (api->set_mixer(name, 1, value) == 0) {
        log_message("error", "could not set mixer %s=%s", name, value);
        return -1;
    }
    return 0;
}

static int set_voice_audio_enabled(int enabled)
{
    const char *value = enabled != 0 ? "1\n" : "0\n";
    int fd;
    int saved_errno;
    ssize_t written;

    do {
        fd = open(VOICE_AUDIO_ENABLE_PATH, O_WRONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        log_message("error", "open(%s) failed: %s", VOICE_AUDIO_ENABLE_PATH,
                    strerror(errno));
        return -1;
    }

    do {
        written = write(fd, value, 2U);
    } while (written < 0 && errno == EINTR);
    saved_errno = errno;
    if (close(fd) != 0 && written == (ssize_t)2) {
        saved_errno = errno;
        written = -1;
    }
    if (written != (ssize_t)2) {
        if (written >= 0) {
            log_message("error", "short write to %s", VOICE_AUDIO_ENABLE_PATH);
        } else {
            log_message("error", "write(%s) failed: %s",
                        VOICE_AUDIO_ENABLE_PATH, strerror(saved_errno));
        }
        return -1;
    }
    return 0;
}

static int run_voice_route_session(struct vendor_audio *api, int verbose)
{
    void *playback = NULL;
    void *capture = NULL;
    int legacy_downlink_disabled = 0;
    int legacy_uplink_disabled = 0;
    int downlink_enabled = 0;
    int uplink_enabled = 0;
    int usb_audio_enabled = 0;
    int result = EXIT_FAILURE;

    if (install_signal_handlers() != 0) {
        return EXIT_FAILURE;
    }
    if (set_voice_mixer(api, VOICE_LEGACY_DOWNLINK_MIXER, "0") != 0) {
        goto cleanup;
    }
    legacy_downlink_disabled = 1;
    if (should_stop()) {
        goto cleanup;
    }
    if (set_voice_mixer(api, VOICE_LEGACY_UPLINK_MIXER, "0") != 0) {
        goto cleanup;
    }
    legacy_uplink_disabled = 1;
    if (should_stop()) {
        goto cleanup;
    }
    if (set_voice_mixer(api, VOICE_DOWNLINK_MIXER, "1") != 0) {
        goto cleanup;
    }
    downlink_enabled = 1;
    if (should_stop()) {
        goto cleanup;
    }
    if (set_voice_mixer(api, VOICE_UPLINK_MIXER, "1") != 0) {
        goto cleanup;
    }
    uplink_enabled = 1;
    if (should_stop()) {
        goto cleanup;
    }
    if (set_voice_audio_enabled(1) != 0) {
        goto cleanup;
    }
    usb_audio_enabled = 1;
    if (should_stop()) {
        goto cleanup;
    }

    capture = api->pcm_open(
        VOICE_PCM_DEVICE, VOICE_CAPTURE_FLAGS, PCM_RATE, PCM_CHANNELS,
        PCM_FORMAT_S16_LE, VOICE_HOSTLESS);
    if (capture == NULL) {
        log_message("error", "could not open VoLTE capture PCM %s",
                    VOICE_PCM_DEVICE);
        goto cleanup;
    }
    if (should_stop()) {
        goto cleanup;
    }
    playback = api->pcm_open(
        VOICE_PCM_DEVICE, VOICE_PLAYBACK_FLAGS, PCM_RATE, PCM_CHANNELS,
        PCM_FORMAT_S16_LE, VOICE_HOSTLESS);
    if (playback == NULL) {
        log_message("error", "could not open VoLTE playback PCM %s",
                    VOICE_PCM_DEVICE);
        goto cleanup;
    }

    log_message("info", "VoLTE route session active on %s; send SIGTERM to stop",
                VOICE_PCM_DEVICE);
    while (!should_stop()) {
        usleep(100000U);
    }
    result = EXIT_SUCCESS;

cleanup:
    if (playback != NULL && api->pcm_close(playback) != 0) {
        log_message("warn", "could not close VoLTE playback PCM cleanly");
        result = EXIT_FAILURE;
    }
    if (capture != NULL && api->pcm_close(capture) != 0) {
        log_message("warn", "could not close VoLTE capture PCM cleanly");
        result = EXIT_FAILURE;
    }
    if (usb_audio_enabled && set_voice_audio_enabled(0) != 0) {
        result = EXIT_FAILURE;
    }
    if (uplink_enabled &&
        set_voice_mixer(api, VOICE_UPLINK_MIXER, "0") != 0) {
        result = EXIT_FAILURE;
    }
    if (downlink_enabled &&
        set_voice_mixer(api, VOICE_DOWNLINK_MIXER, "0") != 0) {
        result = EXIT_FAILURE;
    }
    if (legacy_uplink_disabled &&
        set_voice_mixer(api, VOICE_LEGACY_UPLINK_MIXER, "1") != 0) {
        result = EXIT_FAILURE;
    }
    if (legacy_downlink_disabled &&
        set_voice_mixer(api, VOICE_LEGACY_DOWNLINK_MIXER, "1") != 0) {
        result = EXIT_FAILURE;
    }
    if (verbose) {
        log_message("info", "VoLTE route session cleanup complete");
    }
    return result;
}

struct worker_resources {
    struct bridge_context *context;
    void *pcm;
    unsigned char *buffer;
    const char *mixer_name;
    int mixer_enabled;
    size_t carried_bytes;
    unsigned long dropped_frames;
};

static void release_worker_resources(void *opaque)
{
    struct worker_resources *resources = opaque;

    free(resources->buffer);
    resources->buffer = NULL;
    if (resources->pcm != NULL) {
        if (resources->context->api.pcm_close(resources->pcm) != 0) {
            log_message("error", "could not close PCM for %s",
                        resources->mixer_name);
            mark_worker_failed(resources->context);
        }
        resources->pcm = NULL;
    }
    if (resources->mixer_enabled) {
        if (resources->context->api.set_mixer(resources->mixer_name, 1, "0") ==
            0) {
            log_message("error", "could not disable mixer %s",
                        resources->mixer_name);
            mark_worker_failed(resources->context);
        }
        resources->mixer_enabled = 0;
    }
}

static void *uplink_thread(void *opaque)
{
    struct bridge_context *context = opaque;
    struct worker_resources resources;
    unsigned int buffer_length = 0;
    int cancel_error;

    memset(&resources, 0, sizeof(resources));
    resources.context = context;
    resources.mixer_name = MIXER_UPLINK;

    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not protect uplink setup: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        return NULL;
    }

    pthread_cleanup_push(release_worker_resources, &resources);

    if (should_stop()) {
        goto done;
    }

    if (context->use_mixers &&
        !enable_mixer_with_retry(context, MIXER_UPLINK)) {
        if (!should_stop()) {
            log_message("error", "uplink mixer unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }
    resources.mixer_enabled = context->use_mixers;

    resources.pcm =
        open_pcm_with_retry(context, context->playback_device,
                            PCM_PLAYBACK_FLAGS, "uplink");
    if (resources.pcm == NULL) {
        if (!should_stop()) {
            log_message("error", "uplink PCM unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }

    buffer_length = context->api.pcm_buffer_len(resources.pcm);
    if (!valid_buffer_length(buffer_length)) {
        log_message("error", "invalid uplink buffer length %u", buffer_length);
        mark_worker_failed(context);
        goto done;
    }
    resources.buffer = calloc(1U, buffer_length);
    if (resources.buffer == NULL) {
        log_message("error", "could not allocate %u-byte uplink buffer",
                    buffer_length);
        mark_worker_failed(context);
        goto done;
    }

    if (context->verbose) {
        log_message("info", "uplink active, PCM buffer %u bytes", buffer_length);
    }
    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not enable uplink cancellation: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        goto done;
    }
    usleep(IDLE_RETRY_USEC);

    while (!should_stop()) {
        ssize_t received =
            read(context->tty_fd, resources.buffer + resources.carried_bytes,
                 (size_t)buffer_length - resources.carried_bytes);

        if (received > 0) {
            size_t total_bytes = resources.carried_bytes + (size_t)received;
            size_t pcm_bytes = total_bytes & ~(size_t)1U;
            unsigned char trailing_byte = 0U;

            if (pcm_bytes != total_bytes) {
                trailing_byte = resources.buffer[pcm_bytes];
            }
            if (pcm_bytes > 0U &&
                context->api.pcm_write(resources.pcm, resources.buffer,
                                       (unsigned int)pcm_bytes) != 0) {
                log_message("error", "uplink PCM write failed (%lu bytes)",
                            (unsigned long)pcm_bytes);
                mark_worker_failed(context);
                break;
            }
            resources.carried_bytes = total_bytes - pcm_bytes;
            if (resources.carried_bytes != 0U) {
                resources.buffer[0] = trailing_byte;
            }
            continue;
        }
        if (received == 0 ||
            (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            usleep(IDLE_RETRY_USEC);
            continue;
        }
        if (received < 0 && errno == EINTR) {
            continue;
        }

        log_message("error", "tty uplink read failed: %s", strerror(errno));
        mark_worker_failed(context);
        break;
    }

done:
    (void)pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    request_worker_stop();
    pthread_cleanup_pop(1);
    return NULL;
}

/*
 * Return 0 after a complete frame, 1 when an untouched frame was dropped due
 * to backpressure, and -1 on an I/O error.  Once any prefix has reached the
 * byte stream, finish that frame or fail the bridge so PCM16 sample alignment
 * cannot silently shift after an odd-length short write.
 */
static int write_downlink_frame(struct bridge_context *context,
                                const unsigned char *buffer,
                                unsigned int buffer_length)
{
    size_t offset = 0U;

    while (offset < (size_t)buffer_length && !should_stop()) {
        ssize_t written = write(context->tty_fd, buffer + offset,
                                (size_t)buffer_length - offset);

        if (written > 0) {
            offset += (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written == 0 ||
            (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
            if (offset == 0U) {
                usleep(IDLE_RETRY_USEC);
                return 1;
            }
            /*
             * A frame prefix has already entered ttyGS0, so dropping the
             * suffix would shift every later PCM16 sample.  During startup
             * the module can fill g_serial before macOS opens interface 1;
             * wait for the host to drain it instead of killing the bridge
             * after an arbitrary 40 ms.  SIGTERM still breaks the loop via
             * should_stop(), so cleanup remains bounded by the supervisor.
             */
            usleep(PARTIAL_WRITE_RETRY_USEC);
            continue;
        }

        log_message("error", "tty downlink write failed: %s", strerror(errno));
        return -1;
    }

    return 0;
}

static void *downlink_thread(void *opaque)
{
    struct bridge_context *context = opaque;
    struct worker_resources resources;
    unsigned int buffer_length = 0;
    int cancel_error;

    memset(&resources, 0, sizeof(resources));
    resources.context = context;
    resources.mixer_name = MIXER_DOWNLINK;

    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not protect downlink setup: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        return NULL;
    }

    pthread_cleanup_push(release_worker_resources, &resources);

    if (should_stop()) {
        goto done;
    }

    if (context->use_mixers &&
        !enable_mixer_with_retry(context, MIXER_DOWNLINK)) {
        if (!should_stop()) {
            log_message("error", "downlink mixer unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }
    resources.mixer_enabled = context->use_mixers;

    resources.pcm =
        open_pcm_with_retry(context, context->capture_device,
                            PCM_CAPTURE_FLAGS, "downlink");
    if (resources.pcm == NULL) {
        if (!should_stop()) {
            log_message("error", "downlink PCM unavailable after %u retries",
                        STARTUP_RETRY_LIMIT);
            mark_worker_failed(context);
        }
        goto done;
    }

    buffer_length = context->api.pcm_buffer_len(resources.pcm);
    if (!valid_buffer_length(buffer_length)) {
        log_message("error", "invalid downlink buffer length %u", buffer_length);
        mark_worker_failed(context);
        goto done;
    }
    resources.buffer = calloc(1U, buffer_length);
    if (resources.buffer == NULL) {
        log_message("error", "could not allocate %u-byte downlink buffer",
                    buffer_length);
        mark_worker_failed(context);
        goto done;
    }

    if (context->verbose) {
        log_message("info", "downlink active, PCM buffer %u bytes", buffer_length);
    }
    cancel_error = pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
    if (cancel_error != 0) {
        log_message("error", "could not enable downlink cancellation: %s",
                    strerror(cancel_error));
        mark_worker_failed(context);
        goto done;
    }
    usleep(IDLE_RETRY_USEC);

    while (!should_stop()) {
        int write_result;

        if (context->api.pcm_read(resources.pcm, resources.buffer,
                                  buffer_length) != 0) {
            if (!should_stop()) {
                log_message("error", "downlink PCM read failed");
                mark_worker_failed(context);
            }
            break;
        }

        write_result =
            write_downlink_frame(context, resources.buffer, buffer_length);
        if (write_result > 0) {
            ++resources.dropped_frames;
            if (context->verbose &&
                (resources.dropped_frames == 1UL ||
                 resources.dropped_frames % 50UL == 0UL)) {
                log_message("warn", "dropped %lu downlink PCM frames",
                            resources.dropped_frames);
            }
            continue;
        }
        if (write_result < 0) {
            mark_worker_failed(context);
            break;
        }
    }

done:
    (void)pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    request_worker_stop();
    pthread_cleanup_pop(1);
    return NULL;
}

static void reap_worker(pthread_t thread, int *started, const char *name,
                        struct bridge_context *context)
{
    int error;

    if (!*started) {
        return;
    }
    error = pthread_tryjoin_np(thread, NULL);
    if (error == 0) {
        *started = 0;
        return;
    }
    if (error == EBUSY) {
        return;
    }

    log_message("error", "could not join %s thread: %s", name,
                strerror(error));
    *started = 0;
    mark_worker_failed(context);
}

static void wait_for_workers(pthread_t uplink, int *uplink_started,
                             pthread_t downlink, int *downlink_started,
                             unsigned int timeout_usec,
                             struct bridge_context *context)
{
    unsigned int elapsed = 0U;

    while ((*uplink_started || *downlink_started) && elapsed < timeout_usec) {
        reap_worker(uplink, uplink_started, "uplink", context);
        reap_worker(downlink, downlink_started, "downlink", context);
        if (!*uplink_started && !*downlink_started) {
            break;
        }
        usleep(IDLE_RETRY_USEC);
        if (timeout_usec - elapsed < IDLE_RETRY_USEC) {
            elapsed = timeout_usec;
        } else {
            elapsed += IDLE_RETRY_USEC;
        }
    }
}

static int stop_and_join_workers(pthread_t uplink, int *uplink_started,
                                 pthread_t downlink, int *downlink_started,
                                 struct bridge_context *context)
{
    int error;

    request_worker_stop();
    wait_for_workers(uplink, uplink_started, downlink, downlink_started,
                     SHUTDOWN_GRACE_USEC, context);
    if (!*uplink_started && !*downlink_started) {
        return 0;
    }

    log_message("warn", "worker shutdown timed out; requesting cancellation");
    mark_worker_failed(context);
    if (*uplink_started) {
        error = pthread_cancel(uplink);
        if (error != 0 && error != ESRCH) {
            log_message("error", "could not cancel uplink thread: %s",
                        strerror(error));
        }
    }
    if (*downlink_started) {
        error = pthread_cancel(downlink);
        if (error != 0 && error != ESRCH) {
            log_message("error", "could not cancel downlink thread: %s",
                        strerror(error));
        }
    }

    wait_for_workers(uplink, uplink_started, downlink, downlink_started,
                     CANCEL_GRACE_USEC, context);
    if (*uplink_started || *downlink_started) {
        log_message("error", "one or more PCM workers did not terminate");
        return -1;
    }
    return 0;
}

static int run_workers_until_stop(pthread_t uplink, int *uplink_started,
                                  pthread_t downlink, int *downlink_started,
                                  struct bridge_context *context)
{
    while (!should_stop() && (*uplink_started || *downlink_started)) {
        reap_worker(uplink, uplink_started, "uplink", context);
        reap_worker(downlink, downlink_started, "downlink", context);
        if (*uplink_started || *downlink_started) {
            usleep(IDLE_RETRY_USEC);
        }
    }
    return stop_and_join_workers(uplink, uplink_started, downlink,
                                 downlink_started, context);
}

static void force_failure_exit(int signal_number)
{
    (void)signal_number;
    _Exit(EXIT_FAILURE);
}

static void emergency_rollback(struct bridge_context *context)
{
    struct sigaction action;

    /* Restore the tty before touching a vendor function that may share the
     * same lock as the stuck worker. */
    (void)restore_tty(context);

    memset(&action, 0, sizeof(action));
    action.sa_handler = force_failure_exit;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL) != 0) {
        log_message("error", "could not arm emergency rollback watchdog");
        fflush(stderr);
        return;
    }
    (void)alarm(1U);

    /* These mixer writes are idempotent and are the only safe cross-thread
     * rollback available if a vendor PCM call never returns. */
    if (context->use_mixers && context->api.set_mixer != NULL) {
        if (context->api.set_mixer(MIXER_UPLINK, 1, "0") == 0) {
            log_message("error", "emergency uplink mixer rollback failed");
        }
        if (context->api.set_mixer(MIXER_DOWNLINK, 1, "0") == 0) {
            log_message("error", "emergency downlink mixer rollback failed");
        }
    }
    (void)alarm(0U);
    fflush(stderr);
}

static void print_usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s [--check] [--verbose] [--tty PATH] [--library PATH] "
            "[--playback-device NAME] [--capture-device NAME] [--no-mixers] "
            "[--voice-route-session]\n",
            program);
}

int main(int argc, char **argv)
{
    const char *tty_path = DEFAULT_TTY_DEVICE;
    const char *library_path = DEFAULT_AUDIO_LIBRARY;
    struct bridge_context context;
    pthread_t uplink;
    pthread_t downlink;
    int uplink_started = 0;
    int downlink_started = 0;
    int check_only = 0;
    int voice_route_session = 0;
    int index;
    int thread_error;
    int result = EXIT_FAILURE;

    memset(&context, 0, sizeof(context));
    memset(&uplink, 0, sizeof(uplink));
    memset(&downlink, 0, sizeof(downlink));
    context.tty_fd = -1;
    context.playback_device = PCM_DEVICE;
    context.capture_device = PCM_DEVICE;
    context.use_mixers = 1;

    for (index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--check") == 0) {
            check_only = 1;
        } else if (strcmp(argv[index], "--voice-route-session") == 0) {
            voice_route_session = 1;
        } else if (strcmp(argv[index], "--verbose") == 0) {
            context.verbose = 1;
        } else if (strcmp(argv[index], "--tty") == 0 && index + 1 < argc) {
            tty_path = argv[++index];
        } else if (strcmp(argv[index], "--library") == 0 && index + 1 < argc) {
            library_path = argv[++index];
        } else if (strcmp(argv[index], "--playback-device") == 0 &&
                   index + 1 < argc) {
            context.playback_device = argv[++index];
        } else if (strcmp(argv[index], "--capture-device") == 0 &&
                   index + 1 < argc) {
            context.capture_device = argv[++index];
        } else if (strcmp(argv[index], "--no-mixers") == 0) {
            context.use_mixers = 0;
        } else {
            print_usage(argv[0]);
            return EXIT_FAILURE;
        }
    }

    if (context.playback_device[0] == '\0' ||
        context.capture_device[0] == '\0') {
        log_message("error", "PCM device names must not be empty");
        return EXIT_FAILURE;
    }
    if (check_only && voice_route_session) {
        log_message("error",
                    "--check and --voice-route-session are mutually exclusive");
        return EXIT_FAILURE;
    }

    if (load_vendor_audio(&context.api, library_path) != 0) {
        return EXIT_FAILURE;
    }
    if (check_only) {
        log_message("info", "all required symbols are available in %s",
                    library_path);
        unload_vendor_audio(&context.api);
        return EXIT_SUCCESS;
    }
    if (voice_route_session) {
        result = run_voice_route_session(&context.api, context.verbose);
        unload_vendor_audio(&context.api);
        return result;
    }

    context.tty_fd =
        open(tty_path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (context.tty_fd < 0) {
        log_message("error", "open(%s) failed: %s", tty_path, strerror(errno));
        goto cleanup;
    }
    if (configure_raw_tty(&context) != 0 || install_signal_handlers() != 0) {
        goto cleanup;
    }

    thread_error = pthread_create(&uplink, NULL, uplink_thread, &context);
    if (thread_error != 0) {
        log_message("error", "could not start uplink thread: %s",
                    strerror(thread_error));
        mark_worker_failed(&context);
        goto cleanup;
    }
    uplink_started = 1;
    thread_error = pthread_create(&downlink, NULL, downlink_thread, &context);
    if (thread_error != 0) {
        log_message("error", "could not start downlink thread: %s",
                    strerror(thread_error));
        mark_worker_failed(&context);
        goto cleanup;
    }
    downlink_started = 1;

    log_message("info",
                "bridge active on %s (playback=%s capture=%s mixers=%s); "
                "send SIGTERM to stop",
                tty_path, context.playback_device, context.capture_device,
                context.use_mixers ? "on" : "off");
    if (run_workers_until_stop(uplink, &uplink_started, downlink,
                               &downlink_started, &context) != 0) {
        emergency_rollback(&context);
        _Exit(EXIT_FAILURE);
    }
    result = worker_failed(&context) ? EXIT_FAILURE : EXIT_SUCCESS;

cleanup:
    if (uplink_started || downlink_started) {
        if (stop_and_join_workers(uplink, &uplink_started, downlink,
                                  &downlink_started, &context) != 0) {
            emergency_rollback(&context);
            _Exit(EXIT_FAILURE);
        }
    }
    if (context.tty_fd >= 0) {
        if (restore_tty(&context) != 0) {
            result = EXIT_FAILURE;
        }
        if (close(context.tty_fd) != 0) {
            log_message("warn", "close(%s) failed: %s", tty_path,
                        strerror(errno));
            result = EXIT_FAILURE;
        }
        context.tty_fd = -1;
    }
    unload_vendor_audio(&context.api);
    return result;
}
