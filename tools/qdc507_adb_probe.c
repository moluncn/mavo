#include "CModemBridge.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define TARGET_LOCATION UINT32_C(0x01100000)
#define ADB_CNXN UINT32_C(0x4E584E43)
#define ADB_OPEN UINT32_C(0x4E45504F)
#define ADB_OKAY UINT32_C(0x59414B4F)
#define ADB_CLSE UINT32_C(0x45534C43)
#define ADB_WRTE UINT32_C(0x45545257)
#define ADB_MAX_PAYLOAD 4096U
#define ADB_LOCAL_ID UINT32_C(1)
#define ADB_SHELL_PREFIX "shell:"
#define ADB_SHELL_IDLE_TIMEOUT_SLICES 600

typedef struct __attribute__((packed)) {
    uint32_t command;
    uint32_t arg0;
    uint32_t arg1;
    uint32_t data_length;
    uint32_t data_check;
    uint32_t magic;
} ADBHeader;

static uint32_t to_le32(uint32_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return value;
#else
    return __builtin_bswap32(value);
#endif
}

static uint32_t from_le32(uint32_t value) {
    return to_le32(value);
}

static uint32_t adb_checksum(const uint8_t *bytes, size_t length) {
    uint32_t sum = 0;
    for (size_t index = 0; index < length; index++) {
        sum += bytes[index];
    }
    return sum;
}

static void print_command(uint32_t command) {
    char text[5] = {
        (char)(command & 0xFF),
        (char)((command >> 8) & 0xFF),
        (char)((command >> 16) & 0xFF),
        (char)((command >> 24) & 0xFF),
        '\0'
    };
    for (int index = 0; index < 4; index++) {
        if (!isprint((unsigned char)text[index])) {
            text[index] = '?';
        }
    }
    printf("ADB command=%s (0x%08X)\n", text, command);
}

static void print_payload(const uint8_t *bytes, size_t length) {
    printf("ADB payload[%zu]=", length);
    size_t shown = length < 512 ? length : 512;
    for (size_t index = 0; index < shown; index++) {
        unsigned char value = bytes[index];
        if (value == '\0') {
            fputs("\\0", stdout);
        } else if (value == '\r') {
            fputs("\\r", stdout);
        } else if (value == '\n') {
            fputs("\\n", stdout);
        } else if (isprint(value)) {
            fputc(value, stdout);
        } else {
            printf("\\x%02X", value);
        }
    }
    if (shown < length) {
        fputs("...", stdout);
    }
    fputc('\n', stdout);
}

static int adb_send(
    MaVoVoice *transport,
    uint32_t command,
    uint32_t arg0,
    uint32_t arg1,
    const uint8_t *payload,
    size_t payload_length
) {
    if (payload_length > UINT32_MAX || (payload_length > 0 && payload == NULL)) {
        return 0;
    }
    ADBHeader header = {
        .command = to_le32(command),
        .arg0 = to_le32(arg0),
        .arg1 = to_le32(arg1),
        .data_length = to_le32((uint32_t)payload_length),
        .data_check = to_le32(adb_checksum(payload, payload_length)),
        .magic = to_le32(command ^ UINT32_MAX)
    };
    if (mavo_voice_write(
            transport,
            2000,
            (const uint8_t *)&header,
            sizeof(header)
        ) != MAVO_MODEM_OK) {
        return 0;
    }
    return payload_length == 0 ||
        mavo_voice_write(transport, 2000, payload, payload_length) == MAVO_MODEM_OK;
}

static int adb_read_exact(
    MaVoVoice *transport,
    uint8_t *output,
    size_t length,
    int timeout_slices
) {
    size_t used = 0;
    for (int attempt = 0; attempt < timeout_slices && used < length; attempt++) {
        int count = mavo_voice_read(transport, 100, output + used, length - used);
        if (!mavo_voice_is_open(transport)) {
            return 0;
        }
        if (count <= 0) {
            continue;
        }
        if ((size_t)count > length - used) {
            return 0;
        }
        used += (size_t)count;
    }
    return used == length;
}

static int adb_receive(
    MaVoVoice *transport,
    ADBHeader *header,
    uint8_t *payload,
    size_t payload_capacity,
    int timeout_slices
) {
    ADBHeader wire;
    if (!adb_read_exact(transport, (uint8_t *)&wire, sizeof(wire), timeout_slices)) {
        return 0;
    }
    header->command = from_le32(wire.command);
    header->arg0 = from_le32(wire.arg0);
    header->arg1 = from_le32(wire.arg1);
    header->data_length = from_le32(wire.data_length);
    header->data_check = from_le32(wire.data_check);
    header->magic = from_le32(wire.magic);
    if (header->magic != (header->command ^ UINT32_MAX) ||
        header->data_length > payload_capacity) {
        return 0;
    }
    if (header->data_length > 0 &&
        !adb_read_exact(transport, payload, header->data_length, timeout_slices)) {
        return 0;
    }
    return header->data_check == adb_checksum(payload, header->data_length);
}

int main(int argc, char **argv) {
    int run_shell = argc == 3 && strcmp(argv[1], "shell") == 0;
    int write_shell_to_file = argc == 4 && strcmp(argv[1], "shell-to-file") == 0;
    if (argc != 1 && !run_shell && !write_shell_to_file) {
        fprintf(
            stderr,
            "usage: %s [shell COMMAND | shell-to-file COMMAND OUTPUT]\n",
            argv[0]
        );
        return 64;
    }
    int run_shell_service = run_shell || write_shell_to_file;
    size_t command_length = run_shell_service ? strlen(argv[2]) : 0;
    const size_t max_command_length = ADB_MAX_PAYLOAD - sizeof(ADB_SHELL_PREFIX);
    if (run_shell_service &&
        (command_length == 0 || command_length > max_command_length)) {
        fprintf(stderr, "ADB shell command must be 1..%zu bytes\n", max_command_length);
        return 64;
    }

    FILE *shell_output = stdout;
    if (write_shell_to_file) {
        shell_output = fopen(argv[3], "wbx");
        if (shell_output == NULL) {
            perror("create shell output file");
            return 73;
        }
    }

    MaVoVoice *transport = mavo_voice_create();
    if (transport == NULL ||
        mavo_voice_open_interface_for_location(
            transport,
            TARGET_LOCATION,
            6
        ) != MAVO_MODEM_OK) {
        fprintf(stderr, "open ADB interface 6 failed: %s\n", mavo_voice_last_error(transport));
        mavo_voice_destroy(transport);
        return 2;
    }
    uint8_t endpoint_out = mavo_voice_output_endpoint(transport);
    uint8_t endpoint_in = mavo_voice_input_endpoint(transport);
    printf("Opened ADB interface 6 OUT=0x%02X IN=0x%02X\n", endpoint_out, endpoint_in);
    if (mavo_voice_clear_stalls(transport) != MAVO_MODEM_OK) {
        fprintf(stderr, "clear ADB endpoint stalls failed: %s\n", mavo_voice_last_error(transport));
        mavo_voice_destroy(transport);
        return 2;
    }

    static const uint8_t banner[] = "host::MaVo";
    if (!adb_send(
            transport,
            ADB_CNXN,
            UINT32_C(0x01000001),
            ADB_MAX_PAYLOAD,
            banner,
            sizeof(banner)
        )) {
        fprintf(stderr, "send ADB CNXN failed: %s\n", mavo_voice_last_error(transport));
        mavo_voice_destroy(transport);
        return 4;
    }

    ADBHeader received;
    uint8_t response[ADB_MAX_PAYLOAD] = {0};
    if (!adb_receive(transport, &received, response, sizeof(response), 50)) {
        fprintf(stderr, "read/validate ADB CNXN response failed: %s\n", mavo_voice_last_error(transport));
        mavo_voice_destroy(transport);
        return 5;
    }
    if (received.command != ADB_CNXN) {
        fprintf(stderr, "ADB device did not accept an unauthenticated CNXN; command follows.\n");
        print_command(received.command);
        mavo_voice_destroy(transport);
        return 6;
    }
    print_command(received.command);
    printf(
        "ADB arg0=0x%08X arg1=%u checksum=0x%08X\n",
        received.arg0,
        received.arg1,
        received.data_check
    );
    print_payload(response, received.data_length);
    if (!run_shell_service) {
        mavo_voice_destroy(transport);
        return 0;
    }

    size_t service_payload_length = command_length + sizeof(ADB_SHELL_PREFIX);
    uint32_t remote_max_payload = received.arg1;
    if (remote_max_payload == 0 || service_payload_length > remote_max_payload) {
        fprintf(
            stderr,
            "ADB device max payload %u cannot carry %zu-byte shell service request\n",
            remote_max_payload,
            service_payload_length
        );
        mavo_voice_destroy(transport);
        return 7;
    }

    uint8_t service[ADB_MAX_PAYLOAD] = {0};
    int service_length = snprintf(
        (char *)service,
        sizeof(service),
        ADB_SHELL_PREFIX "%s",
        argv[2]
    );
    if (service_length <= 0 || (size_t)service_length + 1 > sizeof(service) ||
        !adb_send(
            transport,
            ADB_OPEN,
            ADB_LOCAL_ID,
            0,
            service,
            (size_t)service_length + 1
        )) {
        fprintf(stderr, "send ADB OPEN failed: %s\n", mavo_voice_last_error(transport));
        mavo_voice_destroy(transport);
        return 7;
    }

    uint32_t remote_id = 0;
    int saw_okay = 0;
    if (!write_shell_to_file) {
        fputs("--- ADB shell output ---\n", stdout);
    }
    size_t output_bytes = 0;
    for (int message_index = 0; message_index < 32768; message_index++) {
        memset(response, 0, sizeof(response));
        if (!adb_receive(
                transport,
                &received,
                response,
                sizeof(response),
                ADB_SHELL_IDLE_TIMEOUT_SLICES
            )) {
            fprintf(stderr, "receive ADB shell message failed: %s\n", mavo_voice_last_error(transport));
            mavo_voice_destroy(transport);
            return 8;
        }
        if (received.command == ADB_OKAY) {
            if (received.data_length != 0 ||
                received.arg1 != ADB_LOCAL_ID || received.arg0 == 0 ||
                (remote_id != 0 && received.arg0 != remote_id)) {
                fprintf(stderr, "invalid ADB OKAY stream identifiers\n");
                mavo_voice_destroy(transport);
                return 8;
            }
            remote_id = received.arg0;
            saw_okay = 1;
            continue;
        }
        if (received.command == ADB_WRTE) {
            if (!saw_okay || received.arg1 != ADB_LOCAL_ID ||
                received.arg0 == 0 || received.arg0 != remote_id) {
                fprintf(stderr, "invalid ADB WRTE stream identifiers\n");
                mavo_voice_destroy(transport);
                return 8;
            }
            remote_id = received.arg0;
            if (received.data_length > 0) {
                size_t written = fwrite(
                    response,
                    1,
                    received.data_length,
                    shell_output
                );
                if (written != received.data_length) {
                    fprintf(stderr, "write ADB shell output failed\n");
                    mavo_voice_destroy(transport);
                    if (write_shell_to_file) {
                        (void)fclose(shell_output);
                        (void)unlink(argv[3]);
                    }
                    return 73;
                }
                output_bytes += written;
                (void)fflush(shell_output);
            }
            if (!adb_send(
                    transport,
                    ADB_OKAY,
                    ADB_LOCAL_ID,
                    remote_id,
                    NULL,
                    0
                )) {
                fprintf(stderr, "send ADB stream OKAY failed\n");
                mavo_voice_destroy(transport);
                return 8;
            }
            continue;
        }
        if (received.command == ADB_CLSE) {
            if (received.data_length != 0 ||
                received.arg1 != ADB_LOCAL_ID ||
                (received.arg0 != 0 && remote_id != 0 &&
                 received.arg0 != remote_id)) {
                fprintf(stderr, "invalid ADB CLSE stream identifiers\n");
                mavo_voice_destroy(transport);
                return 8;
            }
            if (received.arg0 == 0) {
                fputs("\n--- ADB shell service rejected OPEN ---\n", stderr);
                mavo_voice_destroy(transport);
                return 9;
            }
            remote_id = received.arg0;
            if (!saw_okay ||
                !adb_send(
                    transport,
                    ADB_CLSE,
                    ADB_LOCAL_ID,
                    remote_id,
                    NULL,
                    0
                )) {
                fprintf(stderr, "send ADB stream CLSE failed\n");
                mavo_voice_destroy(transport);
                return 8;
            }
            if (write_shell_to_file) {
                if (fclose(shell_output) != 0) {
                    perror("close shell output file");
                    (void)unlink(argv[3]);
                    mavo_voice_destroy(transport);
                    return 73;
                }
                fprintf(
                    stdout,
                    "ADB shell wrote %zu bytes to %s\n",
                    output_bytes,
                    argv[3]
                );
            } else {
                fputs("\n--- ADB shell closed ---\n", stdout);
            }
            mavo_voice_destroy(transport);
            return 0;
        }
        fprintf(stderr, "unexpected ADB shell message\n");
        print_command(received.command);
        mavo_voice_destroy(transport);
        return 8;
    }
    fprintf(stderr, "ADB shell exceeded message safety limit\n");
    mavo_voice_destroy(transport);
    return 10;
}
