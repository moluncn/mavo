#include "CModemBridge.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define RESPONSE_CAPACITY 16384U

#ifndef MAVO_PROBE_INTERFACE
#define MAVO_PROBE_INTERFACE 3
#endif

static int terminal_response(const char *text) {
    return strstr(text, "\r\nOK\r\n") != NULL ||
        strstr(text, "\r\nERROR\r\n") != NULL ||
        strstr(text, "\r\n+CME ERROR:") != NULL;
}

static int response_ok(const char *text) {
    return strstr(text, "\r\nOK\r\n") != NULL &&
        strstr(text, "ERROR") == NULL;
}

static int response_has_voice_call(const char *text) {
    const char *cursor = text;
    while ((cursor = strstr(cursor, "+CLCC:")) != NULL) {
        int index = -1;
        int direction = -1;
        int status = -1;
        int mode = -1;
        if (sscanf(cursor, "+CLCC: %d,%d,%d,%d", &index, &direction, &status, &mode) == 4 &&
            mode == 0) {
            return 1;
        }
        cursor += 6;
    }
    return 0;
}

static void drain(MaVoVoice *port) {
    uint8_t bytes[4096];
    for (int attempt = 0; attempt < 32; attempt++) {
        int count = mavo_voice_read(port, 25, bytes, sizeof(bytes));
        if (count <= 0 || !mavo_voice_is_open(port)) {
            return;
        }
    }
}

static int command(
    MaVoVoice *port,
    const char *value,
    char *response,
    size_t response_capacity
) {
    response[0] = '\0';
    char wire[256];
    int wire_length = snprintf(wire, sizeof(wire), "%s\r", value);
    if (wire_length <= 0 || (size_t)wire_length >= sizeof(wire)) {
        return 0;
    }
    int write_result = mavo_voice_write(
        port,
        1000,
        (const uint8_t *)wire,
        (size_t)wire_length
    );
    if (write_result != MAVO_MODEM_OK) {
        fprintf(stderr, "write %s failed: %s\n", value, mavo_voice_last_error(port));
        return 0;
    }

    size_t used = 0;
    for (int attempt = 0; attempt < 40 && used + 1 < response_capacity; attempt++) {
        uint8_t bytes[4096];
        int count = mavo_voice_read(port, 100, bytes, sizeof(bytes));
        if (count > 0 && mavo_voice_is_open(port)) {
            size_t copy = (size_t)count;
            if (copy > response_capacity - used - 1) {
                copy = response_capacity - used - 1;
            }
            memcpy(response + used, bytes, copy);
            used += copy;
            response[used] = '\0';
            if (terminal_response(response)) {
                break;
            }
        } else if (!mavo_voice_is_open(port)) {
            fprintf(stderr, "read %s failed: %s\n", value, mavo_voice_last_error(port));
            return 0;
        }
    }
    printf("\n> %s\n%s\n", value, response[0] == '\0' ? "[no response]" : response);
    return terminal_response(response);
}

int main(int argc, char **argv) {
    int query_only = argc == 2 && strcmp(argv[1], "query-only") == 0;
    if (argc != 1 && !query_only) {
        fprintf(stderr, "usage: %s [query-only]\n", argv[0]);
        return 64;
    }
    MaVoVoice *port = mavo_voice_create();
    if (port == NULL ||
        mavo_voice_open_interface_for_location(
            port,
            UINT32_C(0x01100000),
            (uint8_t)MAVO_PROBE_INTERFACE
        ) != MAVO_MODEM_OK) {
        fprintf(stderr, "open interface 3 failed: %s\n", mavo_voice_last_error(port));
        mavo_voice_destroy(port);
        return 1;
    }
    printf(
        "Opened diagnostic USB interface %u; OUT=0x%02X IN=0x%02X\n",
        (unsigned)MAVO_PROBE_INTERFACE,
        mavo_voice_output_endpoint(port),
        mavo_voice_input_endpoint(port)
    );
    drain(port);

    char response[RESPONSE_CAPACITY];
    if (!command(port, "AT", response, sizeof(response)) || !response_ok(response)) {
        mavo_voice_destroy(port);
        return 2;
    }
    (void)command(port, "ATE0", response, sizeof(response));
    (void)command(port, "AT+CMEE=2", response, sizeof(response));
    (void)command(port, "AT+QPCMV?", response, sizeof(response));
    (void)command(port, "AT+QPCMV=?", response, sizeof(response));
    if (!command(port, "AT+CLCC", response, sizeof(response)) ||
        !response_ok(response) || response_has_voice_call(response)) {
        fprintf(stderr, "refusing QPCMV write because empty voice-call state was not confirmed\n");
        mavo_voice_destroy(port);
        return 3;
    }
    if (query_only) {
        mavo_voice_destroy(port);
        return 0;
    }

    int enabled = 0;
    (void)command(port, "AT+QPCMV=1,2", response, sizeof(response));
    enabled = response_ok(response);
    if (!enabled) {
        (void)command(port, "AT+QPCMV=1", response, sizeof(response));
        enabled = response_ok(response);
    }
    if (enabled) {
        (void)command(port, "AT+QPCMV?", response, sizeof(response));
        (void)command(port, "AT+QPCMV=0", response, sizeof(response));
        if (!response_ok(response)) {
            fprintf(stderr, "QPCMV cleanup was not confirmed on interface 3\n");
            mavo_voice_destroy(port);
            return 4;
        }
    }

    mavo_voice_destroy(port);
    return enabled ? 0 : 5;
}
