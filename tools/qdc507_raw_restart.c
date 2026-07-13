#include "CModemBridge.h"

#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

#define TARGET_LOCATION UINT32_C(0x01100000)

#ifndef MAVO_RESTART_INTERFACE
#define MAVO_RESTART_INTERFACE 2
#endif

static int write_command(MaVoVoice *port, const char *command, size_t length) {
    int result = mavo_voice_write(
        port,
        2000,
        (const uint8_t *)command,
        length
    );
    if (result != MAVO_MODEM_OK) {
        fprintf(stderr, "write failed: %s\n", mavo_voice_last_error(port));
        return 0;
    }
    return 1;
}

int main(void) {
    MaVoVoice *port = mavo_voice_create();
    if (port == NULL ||
        mavo_voice_open_interface_for_location(
            port,
            TARGET_LOCATION,
            (uint8_t)MAVO_RESTART_INTERFACE
        ) != MAVO_MODEM_OK) {
        fprintf(
            stderr,
            "open AT interface %u failed: %s\n",
            (unsigned)MAVO_RESTART_INTERFACE,
            mavo_voice_last_error(port)
        );
        mavo_voice_destroy(port);
        return 2;
    }
    printf(
        "Opened AT interface %u OUT=0x%02X IN=0x%02X\n",
        (unsigned)MAVO_RESTART_INTERFACE,
        mavo_voice_output_endpoint(port),
        mavo_voice_input_endpoint(port)
    );
    if (mavo_voice_clear_stalls(port) != MAVO_MODEM_OK) {
        fprintf(stderr, "clear endpoint stalls failed: %s\n", mavo_voice_last_error(port));
        mavo_voice_destroy(port);
        return 3;
    }

    static const char hangup[] = "ATH\r";
    static const char restart[] = "AT+CFUN=1,1\r";
    if (!write_command(port, hangup, sizeof(hangup) - 1)) {
        mavo_voice_destroy(port);
        return 4;
    }
    usleep(200000);
    if (!write_command(port, restart, sizeof(restart) - 1)) {
        mavo_voice_destroy(port);
        return 5;
    }
    puts("CFUN restart command accepted by the USB bulk endpoint.");
    mavo_voice_destroy(port);
    return 0;
}
