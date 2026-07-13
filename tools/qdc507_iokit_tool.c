#include "CModemBridge.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CGACT_MAX_CID 32
#define CGACT_WRITE_TIMEOUT_MS 160000

typedef struct {
    uint16_t vendor_id;
    uint16_t product_id;
    uint32_t location_id;
    uint64_t registry_id;
} ModemIdentity;

typedef struct {
    int state[CGACT_MAX_CID + 1];
    int count;
} CGACTSnapshot;

static volatile sig_atomic_t cleanup_signal = 0;

static void request_cleanup(int signal_number) {
    cleanup_signal = signal_number;
}

static int install_cleanup_signal_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = request_cleanup;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0) {
        return 0;
    }
    return 1;
}

static int response_has_exact_line(const char *output, const char *wanted) {
    const size_t wanted_length = strlen(wanted);
    const char *cursor = output;
    while (*cursor != '\0') {
        while (*cursor == '\r' || *cursor == '\n') {
            cursor++;
        }
        const char *line = cursor;
        while (*cursor != '\0' && *cursor != '\r' && *cursor != '\n') {
            cursor++;
        }
        const char *end = cursor;
        while (line < end && (*line == ' ' || *line == '\t')) {
            line++;
        }
        while (end > line && (end[-1] == ' ' || end[-1] == '\t')) {
            end--;
        }
        if ((size_t)(end - line) == wanted_length &&
            memcmp(line, wanted, wanted_length) == 0) {
            return 1;
        }
    }
    return 0;
}

static int run_command(MaVoModem *modem, const char *command, int timeout_ms, char *output, size_t capacity) {
    int result = mavo_modem_command(modem, command, timeout_ms, output, capacity);
    printf("\n> %s\n%s\n", command, output[0] == '\0' ? "[no response]" : output);
    if (result != MAVO_MODEM_OK) {
        fprintf(stderr, "%s\n", mavo_modem_last_error(modem));
    }
    return result;
}

static int run_call_result_command(
    MaVoModem *modem,
    const char *command,
    int timeout_ms,
    char *output,
    size_t capacity
) {
    int result = mavo_modem_call_command(modem, command, timeout_ms, output, capacity);
    printf("\n> %s\n%s\n", command, output[0] == '\0' ? "[no response]" : output);
    if (result != MAVO_MODEM_OK) {
        fprintf(stderr, "%s\n", mavo_modem_last_error(modem));
    }
    return result;
}

static int response_succeeded(const char *output) {
    return response_has_exact_line(output, "OK") &&
        strstr(output, "+CME ERROR:") == NULL &&
        strstr(output, "+CMS ERROR:") == NULL &&
        !response_has_exact_line(output, "ERROR");
}

static int response_has_voice_call(const char *output) {
    const char *cursor = output;
    while ((cursor = strstr(cursor, "+CLCC:")) != NULL) {
        int index = -1;
        int direction = -1;
        int status = -1;
        int mode = -1;
        if (sscanf(cursor, "+CLCC: %d,%d,%d,%d", &index, &direction, &status, &mode) == 4 && mode == 0) {
            return 1;
        }
        cursor += 6;
    }
    return 0;
}

static int response_has_usb_config(const char *output, int adb_enabled, int uac_enabled) {
    char suffix[32] = {0};
    (void)snprintf(
        suffix,
        sizeof(suffix),
        ",1,1,1,1,1,%d,%d",
        adb_enabled ? 1 : 0,
        uac_enabled ? 1 : 0
    );
    return strstr(output, "+QCFG: \"usbcfg\",0x2C7C,0x125") != NULL &&
        strstr(output, suffix) != NULL;
}

static int response_has_uac_config(const char *output, int enabled) {
    return response_has_usb_config(output, 0, enabled);
}

static ModemIdentity capture_modem_identity(const MaVoModem *modem) {
    ModemIdentity identity = {
        .vendor_id = mavo_modem_vendor_id(modem),
        .product_id = mavo_modem_product_id(modem),
        .location_id = mavo_modem_location_id(modem),
        .registry_id = mavo_modem_registry_id(modem)
    };
    return identity;
}

static int modem_identity_matches(const MaVoModem *modem, const ModemIdentity *identity) {
    if (mavo_modem_vendor_id(modem) != identity->vendor_id ||
        mavo_modem_product_id(modem) != identity->product_id ||
        mavo_modem_location_id(modem) != identity->location_id) {
        return 0;
    }
    uint64_t registry_id = mavo_modem_registry_id(modem);
    return identity->registry_id == 0 || registry_id == 0 || registry_id == identity->registry_id;
}

static void drain_reconnect_events(MaVoModem *modem) {
    char pending[4096] = {0};
    for (int attempt = 0; attempt < 64; attempt++) {
        int count = mavo_modem_read(modem, 25, pending, sizeof(pending));
        if (count > 0) {
            printf("\n[reconnect pending]\n%s\n", pending);
            continue;
        }
        return;
    }
    fprintf(stderr, "Reconnect drain reached its safety limit.\n");
}

static int ensure_original_modem_open(MaVoModem *modem, const ModemIdentity *identity) {
    if (mavo_modem_is_open(modem)) {
        if (modem_identity_matches(modem, identity)) {
            return 1;
        }
        fprintf(stderr, "Open AT interface no longer matches the captured USB identity.\n");
        mavo_modem_close(modem);
        return 0;
    }
    if (identity->location_id == 0 ||
        mavo_modem_open_for_location(modem, identity->location_id) != MAVO_MODEM_OK) {
        fprintf(stderr, "Could not reopen original modem location 0x%08X: %s\n",
            identity->location_id,
            mavo_modem_last_error(modem));
        return 0;
    }
    if (!modem_identity_matches(modem, identity)) {
        fprintf(stderr, "Reopened USB interface does not match the captured modem identity.\n");
        mavo_modem_close(modem);
        return 0;
    }
    drain_reconnect_events(modem);
    printf("\nRECONNECT original modem identity confirmed at location 0x%08X.\n",
        identity->location_id);
    return 1;
}

static void initialize_cgact_snapshot(CGACTSnapshot *snapshot) {
    snapshot->count = 0;
    for (int cid = 0; cid <= CGACT_MAX_CID; cid++) {
        snapshot->state[cid] = -1;
    }
}

static int parse_cgact_snapshot(const char *output, CGACTSnapshot *snapshot) {
    initialize_cgact_snapshot(snapshot);
    const char *cursor = output;
    while ((cursor = strstr(cursor, "+CGACT:")) != NULL) {
        int cid = -1;
        int state = -1;
        int consumed = 0;
        if (sscanf(cursor, "+CGACT: %d,%d%n", &cid, &state, &consumed) != 2 ||
            cid < 1 || cid > CGACT_MAX_CID || (state != 0 && state != 1)) {
            return 0;
        }
        const char *line_end = cursor + consumed;
        while (*line_end == ' ' || *line_end == '\t') {
            line_end++;
        }
        if (*line_end != '\0' && *line_end != '\r' && *line_end != '\n') {
            return 0;
        }
        if (snapshot->state[cid] != -1) {
            return 0;
        }
        snapshot->state[cid] = state;
        snapshot->count++;
        cursor = line_end;
    }
    return snapshot->count > 0;
}

static int cgact_snapshot_equals(const CGACTSnapshot *left, const CGACTSnapshot *right) {
    if (left->count != right->count) {
        return 0;
    }
    for (int cid = 1; cid <= CGACT_MAX_CID; cid++) {
        if (left->state[cid] != right->state[cid]) {
            return 0;
        }
    }
    return 1;
}

static void print_cgact_snapshot(const char *label, const CGACTSnapshot *snapshot) {
    printf("\n%s", label);
    for (int cid = 1; cid <= CGACT_MAX_CID; cid++) {
        if (snapshot->state[cid] != -1) {
            printf(" CID%d=%d", cid, snapshot->state[cid]);
        }
    }
    printf("\n");
}

static int query_cgact_snapshot_once(
    MaVoModem *modem,
    CGACTSnapshot *snapshot,
    char *response,
    size_t response_capacity
) {
    if (run_command(modem, "AT+CGACT?", 5000, response, response_capacity) != MAVO_MODEM_OK ||
        !response_succeeded(response) ||
        !parse_cgact_snapshot(response, snapshot)) {
        return 0;
    }
    return 1;
}

static int query_cgact_snapshot_recovering(
    MaVoModem *modem,
    const ModemIdentity *identity,
    CGACTSnapshot *snapshot,
    char *response,
    size_t response_capacity
) {
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!ensure_original_modem_open(modem, identity)) {
            continue;
        }
        if (query_cgact_snapshot_once(modem, snapshot, response, response_capacity)) {
            return 1;
        }
        if (mavo_modem_is_open(modem)) {
            break;
        }
    }
    return 0;
}

static int wait_for_stable_cgact_snapshot(
    MaVoModem *modem,
    const ModemIdentity *identity,
    const CGACTSnapshot *wanted,
    int attempts,
    int required_consecutive,
    int honor_cleanup_signal,
    char *response,
    size_t response_capacity
) {
    int consecutive = 0;
    for (int attempt = 1; attempt <= attempts; attempt++) {
        if (honor_cleanup_signal && cleanup_signal != 0) {
            return 0;
        }
        CGACTSnapshot current;
        if (query_cgact_snapshot_recovering(
                modem,
                identity,
                &current,
                response,
                response_capacity
            ) && cgact_snapshot_equals(&current, wanted)) {
            consecutive++;
            if (consecutive >= required_consecutive) {
                return 1;
            }
        } else {
            consecutive = 0;
        }
        if (honor_cleanup_signal && cleanup_signal != 0) {
            return 0;
        }
        if (attempt < attempts) {
            sleep(1);
        }
    }
    return 0;
}

static int run_cgact_write(
    MaVoModem *modem,
    const ModemIdentity *identity,
    const char *command,
    char *response,
    size_t response_capacity
) {
    if (!ensure_original_modem_open(modem, identity)) {
        return MAVO_MODEM_NOT_OPEN;
    }
    return run_call_result_command(
        modem,
        command,
        CGACT_WRITE_TIMEOUT_MS,
        response,
        response_capacity
    );
}

static int query_clcc_fail_closed(
    MaVoModem *modem,
    int *voice_calls,
    int *data_calls,
    char *response,
    size_t response_capacity
) {
    if (run_command(modem, "AT+CLCC", 3000, response, response_capacity) != MAVO_MODEM_OK ||
        !response_succeeded(response)) {
        return 0;
    }
    int voices = 0;
    int data = 0;
    const char *cursor = response;
    while ((cursor = strstr(cursor, "+CLCC:")) != NULL) {
        int index = -1;
        int direction = -1;
        int status = -1;
        int mode = -1;
        if (sscanf(cursor, "+CLCC: %d,%d,%d,%d", &index, &direction, &status, &mode) != 4) {
            return 0;
        }
        if (mode == 0) {
            voices++;
        } else if (mode == 1) {
            data++;
        }
        cursor += 6;
    }
    *voice_calls = voices;
    *data_calls = data;
    return 1;
}

static int parse_ims_state(const char *output, int *configuration, int *volte_capability) {
    const char *line = strstr(output, "+QCFG: \"ims\",");
    if (line == NULL ||
        sscanf(line, "+QCFG: \"ims\",%d,%d", configuration, volte_capability) != 2) {
        return 0;
    }
    return (*configuration >= 0 && *configuration <= 2) &&
        (*volte_capability == 0 || *volte_capability == 1);
}

static int query_ims_state(
    MaVoModem *modem,
    int *configuration,
    int *volte_capability,
    char *response,
    size_t response_capacity
) {
    return run_command(modem, "AT+QCFG=\"ims\"", 3000, response, response_capacity) == MAVO_MODEM_OK &&
        response_succeeded(response) &&
        parse_ims_state(response, configuration, volte_capability);
}

static int response_reports_registered(const char *output) {
    const char *cursor = strstr(output, "+CEREG:");
    if (cursor == NULL) {
        return 0;
    }
    int first = -1;
    int second = -1;
    int count = sscanf(cursor, "+CEREG: %d,%d", &first, &second);
    int state = count == 2 ? second : first;
    return (count == 1 || count == 2) && (state == 1 || state == 5);
}

static int response_has_nonzero_cid1_address(const char *output) {
    const char *cursor = strstr(output, "+CGPADDR: 1,");
    if (cursor == NULL) {
        return 0;
    }
    cursor += strlen("+CGPADDR: 1,");
    while (*cursor != '\0' && *cursor != '\r' && *cursor != '\n') {
        if ((*cursor >= '1' && *cursor <= '9') ||
            (*cursor >= 'a' && *cursor <= 'f') ||
            (*cursor >= 'A' && *cursor <= 'F')) {
            return 1;
        }
        cursor++;
    }
    return 0;
}

static int response_has_ready_network_device(const char *output) {
    const char *cursor = output;
    while ((cursor = strstr(cursor, "+QNETDEVSTATUS:")) != NULL) {
        int enabled = -1;
        int state = -1;
        int ip_type = -1;
        int instance = -1;
        if (sscanf(
                cursor,
                "+QNETDEVSTATUS: %d,%d,%d,%d",
                &enabled,
                &state,
                &ip_type,
                &instance
            ) == 4 && state == 2 && (ip_type == 4 || ip_type == 6)) {
            return 1;
        }
        cursor += strlen("+QNETDEVSTATUS:");
    }
    return 0;
}

static int verify_restored_service_state(
    MaVoModem *modem,
    const ModemIdentity *identity,
    int baseline_ims_configuration,
    int baseline_volte_capability,
    char *response,
    size_t response_capacity
) {
    if (!ensure_original_modem_open(modem, identity)) {
        return 0;
    }
    if (run_command(modem, "AT+CGATT?", 3000, response, response_capacity) != MAVO_MODEM_OK ||
        !response_succeeded(response) || strstr(response, "+CGATT: 1") == NULL) {
        return 0;
    }
    int ims_configuration = -1;
    int volte_capability = -1;
    if (!query_ims_state(
            modem,
            &ims_configuration,
            &volte_capability,
            response,
            response_capacity
        ) || ims_configuration != baseline_ims_configuration ||
        volte_capability != baseline_volte_capability) {
        return 0;
    }
    if (run_command(modem, "AT+CEREG?", 3000, response, response_capacity) != MAVO_MODEM_OK ||
        !response_succeeded(response) || !response_reports_registered(response)) {
        return 0;
    }
    if (run_command(modem, "AT+CGPADDR=1", 5000, response, response_capacity) != MAVO_MODEM_OK ||
        !response_succeeded(response) || !response_has_nonzero_cid1_address(response)) {
        return 0;
    }
    if (run_command(modem, "AT+QNETDEVSTATUS?", 5000, response, response_capacity) != MAVO_MODEM_OK ||
        !response_succeeded(response) || !response_has_ready_network_device(response)) {
        return 0;
    }
    int voice_calls = -1;
    int data_calls = -1;
    return query_clcc_fail_closed(
        modem,
        &voice_calls,
        &data_calls,
        response,
        response_capacity
    ) && voice_calls == 0;
}

int main(int argc, char **argv) {
    const char *action = argc > 1 ? argv[1] : "query";
    if (strcmp(action, "query") != 0 &&
        strcmp(action, "cleanup-call") != 0 &&
        strcmp(action, "query-dtmf") != 0 &&
        strcmp(action, "query-call-end") != 0 &&
        strcmp(action, "enable-ecm") != 0 &&
        strcmp(action, "probe-qpcmv") != 0 &&
        strcmp(action, "probe-qpcmv-with-cid1-idle") != 0 &&
        strcmp(action, "enable-uac-config") != 0 &&
        strcmp(action, "restore-uac-config") != 0 &&
        strcmp(action, "enable-adb-config") != 0 &&
        strcmp(action, "restore-adb-config") != 0 &&
        strcmp(action, "query-adb-key") != 0 &&
        strcmp(action, "unlock-adb-key") != 0 &&
        strcmp(action, "restart-uac") != 0 &&
        strcmp(action, "restart-uac-adb") != 0 &&
        strcmp(action, "restart-original") != 0) {
        fprintf(
            stderr,
            "usage: %s [query|cleanup-call|query-dtmf|query-call-end|probe-qpcmv|probe-qpcmv-with-cid1-idle|enable-uac-config|restore-uac-config|enable-adb-config|restore-adb-config|query-adb-key|unlock-adb-key KEY|restart-uac|restart-uac-adb|restart-original|enable-ecm]\n",
            argv[0]
        );
        return 2;
    }

    MaVoModem *modem = mavo_modem_create();
    if (modem == NULL || mavo_modem_open(modem) != MAVO_MODEM_OK) {
        fprintf(stderr, "open failed: %s\n", mavo_modem_last_error(modem));
        mavo_modem_destroy(modem);
        return 1;
    }
    printf(
        "USB %04X:%04X; AT interface 2; OUT=0x%02X IN=0x%02X\n",
        mavo_modem_vendor_id(modem),
        mavo_modem_product_id(modem),
        mavo_modem_output_endpoint(modem),
        mavo_modem_input_endpoint(modem)
    );

    char response[65536] = {0};
    if (run_command(modem, "AT", 2000, response, sizeof(response)) != MAVO_MODEM_OK) {
        mavo_modem_destroy(modem);
        return 1;
    }
    (void)run_command(modem, "ATE0", 2000, response, sizeof(response));

    if (strcmp(action, "cleanup-call") == 0) {
        const ModemIdentity identity = capture_modem_identity(modem);
        for (int attempt = 0; attempt < 4; attempt++) {
            if (!ensure_original_modem_open(modem, &identity)) {
                usleep(200000);
                continue;
            }
            (void)run_call_result_command(modem, "ATH", 3000, response, sizeof(response));
            if (!ensure_original_modem_open(modem, &identity)) {
                usleep(200000);
                continue;
            }
            int voice_calls = -1;
            int data_calls = -1;
            if (query_clcc_fail_closed(
                    modem,
                    &voice_calls,
                    &data_calls,
                    response,
                    sizeof(response)
                ) && voice_calls == 0) {
                printf("\nCALL CLEANUP CONFIRMED: voice CLCC is empty.\n");
                mavo_modem_destroy(modem);
                return 0;
            }
            usleep(200000);
        }
        fprintf(stderr, "Call cleanup was not confirmed by an empty voice CLCC.\n");
        mavo_modem_destroy(modem);
        return 5;
    }

    if (strcmp(action, "query-dtmf") == 0) {
        const char *queries[] = {"AT+VTS=?", "AT+VTD?", "AT+VTD=?"};
        int succeeded = 0;
        for (size_t index = 0; index < sizeof(queries) / sizeof(queries[0]); index++) {
            int result = run_command(modem, queries[index], 3000, response, sizeof(response));
            if (index == 0 && result == MAVO_MODEM_OK && response_succeeded(response)) {
                succeeded = 1;
            }
        }
        mavo_modem_destroy(modem);
        return succeeded ? 0 : 6;
    }

    if (strcmp(action, "query-call-end") == 0) {
        int result = run_command(modem, "AT+CEER", 3000, response, sizeof(response));
        (void)run_command(modem, "AT+CLCC", 3000, response, sizeof(response));
        mavo_modem_destroy(modem);
        return result == MAVO_MODEM_OK ? 0 : 7;
    }

    if (strcmp(action, "query-adb-key") == 0) {
        int result = run_command(modem, "AT+QADBKEY?", 3000, response, sizeof(response));
        int ok = result == MAVO_MODEM_OK && response_succeeded(response) &&
            strstr(response, "+QADBKEY:") != NULL;
        mavo_modem_destroy(modem);
        return ok ? 0 : 3;
    }

    if (strcmp(action, "unlock-adb-key") == 0) {
        if (argc != 3 || strlen(argv[2]) != 15 ||
            strspn(argv[2], "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") != 15) {
            fprintf(stderr, "unlock-adb-key requires one 15-character MD5-crypt key.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (run_command(modem, "AT+QADBKEY?", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) || strstr(response, "+QADBKEY:") == NULL) {
            fprintf(stderr, "ADB unlock refused: QADBKEY challenge is unavailable.\n");
            mavo_modem_destroy(modem);
            return 3;
        }
        char command[64] = {0};
        int command_length = snprintf(command, sizeof(command), "AT+QADBKEY=\"%s\"", argv[2]);
        if (command_length <= 0 || (size_t)command_length >= sizeof(command)) {
            mavo_modem_destroy(modem);
            return 2;
        }
        int result = mavo_modem_command(modem, command, 3000, response, sizeof(response));
        printf("\n> AT+QADBKEY=\"[redacted]\"\n%s\n", response[0] == '\0' ? "[no response]" : response);
        memset(command, 0, sizeof(command));
        int ok = result == MAVO_MODEM_OK && response_succeeded(response);
        if (!ok) {
            fprintf(stderr, "ADB unlock key was not accepted: %s\n", mavo_modem_last_error(modem));
        }
        mavo_modem_destroy(modem);
        return ok ? 0 : 4;
    }

    if (strcmp(action, "query") == 0) {
        const char *queries[] = {
            "ATI",
            "AT+QGMR",
            "AT+QCFG=\"usbnet\"",
            "AT+QCFG=\"USBCFG\"",
            "AT+CPIN?",
            "AT+CPMS?",
            "AT+COPS?",
            "AT+QCSQ",
            "AT+CGATT?",
            "AT+CGDCONT?",
            "AT+CGACT?",
            "AT+CGPADDR=1",
            "AT+QNWINFO",
            "AT+QPCMV?",
            "AT+QPCMV=?",
            "AT+CLCC",
            "AT+QIACT?",
            "AT+QCFG=\"nat\"",
            "AT+QMAP?",
            "AT+QNETDEVSTATUS?",
            "AT+QNETDEVCTL=?",
            "AT+QNETDEVCTL?"
        };
        for (size_t index = 0; index < sizeof(queries) / sizeof(queries[0]); index++) {
            (void)run_command(modem, queries[index], 4000, response, sizeof(response));
        }
        mavo_modem_destroy(modem);
        return 0;
    }

    if (strcmp(action, "probe-qpcmv") == 0) {
        int exit_code = 3;
        int restore_usbnmea = 0;
        int enabled = 0;

        (void)run_command(modem, "AT+CMEE=2", 2000, response, sizeof(response));
        if (run_command(modem, "AT+QGPS?", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            strstr(response, "+QGPS: 0") == NULL) {
            fprintf(stderr, "QPCMV probe refused: GNSS state is not confirmed idle.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (run_command(modem, "AT+QGPSCFG=\"outport\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK) {
            mavo_modem_destroy(modem);
            return 2;
        }
        if (strstr(response, "usbnmea") != NULL) {
            restore_usbnmea = 1;
            if (run_command(
                    modem,
                    "AT+QGPSCFG=\"outport\",\"none\"",
                    3000,
                    response,
                    sizeof(response)
                ) != MAVO_MODEM_OK || !response_succeeded(response)) {
                fprintf(stderr, "Could not temporarily release USB NMEA from GNSS.\n");
                mavo_modem_destroy(modem);
                return 2;
            }
            if (run_command(modem, "AT+QGPSCFG=\"outport\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
                strstr(response, "none") == NULL) {
                fprintf(stderr, "Temporary GPS outport read-back failed.\n");
                exit_code = 2;
                goto cleanup_qpcmv_probe;
            }
        } else if (strstr(response, "none") == NULL) {
            fprintf(stderr, "QPCMV probe refused: unsupported GPS outport value.\n");
            mavo_modem_destroy(modem);
            return 2;
        }

        (void)run_command(modem, "AT+QPCMV=1", 3000, response, sizeof(response));
        if (response_succeeded(response)) {
            enabled = 1;
            exit_code = 0;
        } else {
            (void)run_command(modem, "AT+QPCMV=1,2", 3000, response, sizeof(response));
            if (response_succeeded(response)) {
                enabled = 1;
                exit_code = 0;
            }
        }

cleanup_qpcmv_probe:
        if (enabled) {
            (void)run_command(modem, "AT+QPCMV=0", 3000, response, sizeof(response));
            if (!response_succeeded(response)) {
                fprintf(stderr, "QPCMV cleanup was not confirmed.\n");
                exit_code = 4;
            }
        }
        if (restore_usbnmea) {
            (void)run_command(
                modem,
                "AT+QGPSCFG=\"outport\",\"usbnmea\"",
                3000,
                response,
                sizeof(response)
            );
            if (!response_succeeded(response) ||
                run_command(modem, "AT+QGPSCFG=\"outport\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
                strstr(response, "usbnmea") == NULL) {
                fprintf(stderr, "GPS outport restore was not confirmed.\n");
                exit_code = 5;
            }
        }
        mavo_modem_destroy(modem);
        return exit_code;
    }

    if (strcmp(action, "probe-qpcmv-with-cid1-idle") == 0) {
        ModemIdentity identity = capture_modem_identity(modem);
        CGACTSnapshot baseline_cgact;
        CGACTSnapshot idle_cgact;
        int baseline_voice_calls = -1;
        int baseline_data_calls = -1;
        int idle_voice_calls = -1;
        int idle_data_calls = -1;
        int baseline_ims_configuration = -1;
        int baseline_volte_capability = -1;
        int cid1_may_have_changed = 0;
        int idle_gate_confirmed = 0;
        int qpcmv_enable_succeeded = 0;
        int qpcmv_enable_ambiguous = 0;
        int qpcmv_reset_required = 0;
        int qpcmv_cleanup_confirmed = 1;
        int restore_confirmed = 0;
        int service_restore_confirmed = 0;
        int restore_write_sent = 0;

        if (identity.location_id == 0 || identity.vendor_id == 0 || identity.product_id == 0) {
            fprintf(stderr, "CID1 experiment refused: stable USB identity is unavailable.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (!install_cleanup_signal_handlers()) {
            fprintf(stderr, "CID1 experiment refused: could not install SIGINT/SIGTERM cleanup handlers.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        (void)run_command(modem, "AT+CMEE=2", 2000, response, sizeof(response));
        if (run_command(modem, "AT+QCFG=\"USBCFG\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) || !response_has_uac_config(response, 1)) {
            fprintf(stderr, "CID1 experiment refused: exact UAC-enabled USBCFG is not confirmed.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (run_command(modem, "AT+QPCMV=?", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) || strstr(response, "(0-2)") == NULL) {
            fprintf(stderr, "CID1 experiment refused: QPCMV option 2 is not advertised.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (run_command(modem, "AT+CGATT?", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) || strstr(response, "+CGATT: 1") == NULL) {
            fprintf(stderr, "CID1 experiment refused: packet attachment is not confirmed active.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (!query_cgact_snapshot_once(modem, &baseline_cgact, response, sizeof(response))) {
            fprintf(stderr, "CID1 experiment refused: complete CGACT baseline is unavailable.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (baseline_cgact.state[1] != 1 || baseline_cgact.state[5] != 1) {
            fprintf(
                stderr,
                "CID1 experiment refused: expected CID1=1,CID5=1 but found CID1=%d,CID5=%d.\n",
                baseline_cgact.state[1],
                baseline_cgact.state[5]
            );
            mavo_modem_destroy(modem);
            return 2;
        }
        if (!query_ims_state(
                modem,
                &baseline_ims_configuration,
                &baseline_volte_capability,
                response,
                sizeof(response)
            ) || baseline_volte_capability != 1) {
            fprintf(stderr, "CID1 experiment refused: baseline IMS/VoLTE availability is not confirmed.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (!query_clcc_fail_closed(
                modem,
                &baseline_voice_calls,
                &baseline_data_calls,
                response,
                sizeof(response)
            ) || baseline_voice_calls != 0) {
            fprintf(stderr, "CID1 experiment refused: empty voice-call state is not confirmed.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (!verify_restored_service_state(
                modem,
                &identity,
                baseline_ims_configuration,
                baseline_volte_capability,
                response,
                sizeof(response)
            )) {
            fprintf(stderr, "CID1 experiment refused: baseline packet/IMS/network service is incomplete.\n");
            mavo_modem_destroy(modem);
            return 2;
        }
        if (cleanup_signal != 0) {
            fprintf(stderr, "CID1 experiment interrupted before any state-changing command.\n");
            mavo_modem_destroy(modem);
            return 128 + cleanup_signal;
        }

        print_cgact_snapshot("CID1 EXPERIMENT baseline:", &baseline_cgact);
        printf(
            "CID1 EXPERIMENT baseline confirmed: attached, IMS available, "
            "voice_calls=%d data_calls=%d.\n",
            baseline_voice_calls,
            baseline_data_calls
        );
        idle_cgact = baseline_cgact;
        idle_cgact.state[1] = 0;
        /* A lost USB response can hide an accepted state change. */
        cid1_may_have_changed = 1;
        int deactivate_result = run_cgact_write(
            modem,
            &identity,
            "AT+CGACT=0,1",
            response,
            sizeof(response)
        );
        if (deactivate_result != MAVO_MODEM_OK) {
            fprintf(stderr, "CID1 deactivation response is ambiguous; reconciling by exact read-back.\n");
        } else if (!response_succeeded(response)) {
            fprintf(stderr, "CID1 deactivation returned a non-OK terminal result; reconciling by exact read-back.\n");
        }
        if (cleanup_signal != 0 ||
            !wait_for_stable_cgact_snapshot(
                modem,
                &identity,
                &idle_cgact,
                15,
                2,
                1,
                response,
                sizeof(response)
            )) {
            fprintf(stderr, "CID1 idle state was not stably confirmed; proceeding directly to restoration.\n");
            goto restore_cid1;
        }
        idle_gate_confirmed = 1;
        print_cgact_snapshot("CID1 EXPERIMENT stable gate:", &idle_cgact);
        if (!ensure_original_modem_open(modem, &identity) ||
            !query_clcc_fail_closed(
                modem,
                &idle_voice_calls,
                &idle_data_calls,
                response,
                sizeof(response)
            ) || idle_voice_calls != 0) {
            fprintf(stderr, "CLCC became unavailable or a voice call appeared; skipping QPCMV.\n");
            goto restore_cid1;
        }
        printf(
            "CID1 EXPERIMENT CLCC delta: baseline_data=%d cid1_idle_data=%d voice=%d.\n",
            baseline_data_calls,
            idle_data_calls,
            idle_voice_calls
        );

        /* Recheck the complete vector immediately before the state-changing QPCMV command. */
        {
            CGACTSnapshot immediate;
            if (!query_cgact_snapshot_recovering(
                    modem,
                    &identity,
                    &immediate,
                    response,
                    sizeof(response)
                ) || !cgact_snapshot_equals(&immediate, &idle_cgact)) {
                fprintf(stderr, "CID1 idle gate changed before QPCMV; skipping QPCMV.\n");
                goto restore_cid1;
            }
        }
        if (cleanup_signal != 0) {
            fprintf(stderr, "CID1 experiment interrupted before QPCMV; restoring CID1.\n");
            goto restore_cid1;
        }

        printf("\nCID1 EXPERIMENT testing QPCMV with CID1 idle and IMS CID5 preserved.\n");
        qpcmv_reset_required = 1;
        int enable_result = run_command(
            modem,
            "AT+QPCMV=1,2",
            5000,
            response,
            sizeof(response)
        );
        if (enable_result == MAVO_MODEM_OK && response_succeeded(response)) {
            qpcmv_enable_succeeded = 1;
        } else if (enable_result != MAVO_MODEM_OK) {
            qpcmv_enable_ambiguous = 1;
        } else {
            /* An explicit terminal ERROR guarantees the enable write was rejected. */
            qpcmv_reset_required = 0;
            printf("\nCID1 EXPERIMENT QPCMV enable was explicitly rejected.\n");
        }
        {
            CGACTSnapshot after_qpcmv;
            if (!query_cgact_snapshot_recovering(
                    modem,
                    &identity,
                    &after_qpcmv,
                    response,
                    sizeof(response)
                ) || !cgact_snapshot_equals(&after_qpcmv, &idle_cgact)) {
                idle_gate_confirmed = 0;
                fprintf(stderr, "CID1 idle gate did not remain exact across QPCMV; result is inconclusive.\n");
            }
        }
        if (qpcmv_enable_succeeded && ensure_original_modem_open(modem, &identity)) {
            (void)run_command(modem, "AT+QPCMV?", 3000, response, sizeof(response));
        }

restore_cid1:
        if (qpcmv_reset_required) {
            qpcmv_cleanup_confirmed = 0;
            for (int attempt = 1; attempt <= 2; attempt++) {
                if (!ensure_original_modem_open(modem, &identity)) {
                    continue;
                }
                int reset_result = run_command(
                    modem,
                    "AT+QPCMV=0",
                    5000,
                    response,
                    sizeof(response)
                );
                if (reset_result == MAVO_MODEM_OK && response_succeeded(response)) {
                    qpcmv_cleanup_confirmed = 1;
                    break;
                }
                if (reset_result == MAVO_MODEM_OK) {
                    /* Explicit rejection is deterministic; do not hammer the modem. */
                    break;
                }
            }
            if (!qpcmv_cleanup_confirmed) {
                fprintf(stderr, "QPCMV cleanup was not confirmed; restart/unplug may be required.\n");
            }
        }

        if (cid1_may_have_changed) {
            CGACTSnapshot current;
            if (query_cgact_snapshot_recovering(
                    modem,
                    &identity,
                    &current,
                    response,
                    sizeof(response)
                ) && cgact_snapshot_equals(&current, &baseline_cgact)) {
                restore_confirmed = 1;
            } else {
                restore_write_sent = 1;
                int restore_result = run_cgact_write(
                    modem,
                    &identity,
                    "AT+CGACT=1,1",
                    response,
                    sizeof(response)
                );
                if (restore_result != MAVO_MODEM_OK) {
                    fprintf(stderr, "CID1 restore response is ambiguous; reconciling by exact read-back.\n");
                }
                restore_confirmed = wait_for_stable_cgact_snapshot(
                    modem,
                    &identity,
                    &baseline_cgact,
                    60,
                    2,
                    0,
                    response,
                    sizeof(response)
                );
            }
        }

        if (restore_confirmed) {
            for (int attempt = 1; attempt <= 60; attempt++) {
                if (verify_restored_service_state(
                        modem,
                        &identity,
                        baseline_ims_configuration,
                        baseline_volte_capability,
                        response,
                        sizeof(response)
                    )) {
                    service_restore_confirmed = 1;
                    break;
                }
                if (attempt < 60) {
                    sleep(1);
                }
            }
        }

        if (!restore_confirmed || !service_restore_confirmed) {
            fprintf(
                stderr,
                "CID1 experiment RESTORE FAILURE: full_cgact=%s service=%s restore_write_sent=%d.\n",
                restore_confirmed ? "ok" : "bad",
                service_restore_confirmed ? "ok" : "bad",
                restore_write_sent
            );
            mavo_modem_destroy(modem);
            return 7;
        }
        print_cgact_snapshot("CID1 EXPERIMENT restored baseline:", &baseline_cgact);
        printf("\nCID1 EXPERIMENT restoration confirmed: full CGACT, attachment, address, "
            "IMS, registration, network device, and empty voice-call state.\n");
        if (!qpcmv_cleanup_confirmed) {
            mavo_modem_destroy(modem);
            return 8;
        }
        if (cleanup_signal != 0) {
            int signal_number = cleanup_signal;
            mavo_modem_destroy(modem);
            return 128 + signal_number;
        }
        if (!idle_gate_confirmed) {
            mavo_modem_destroy(modem);
            return 5;
        }
        if (qpcmv_enable_ambiguous) {
            mavo_modem_destroy(modem);
            return 9;
        }
        mavo_modem_destroy(modem);
        return qpcmv_enable_succeeded ? 0 : 6;
    }

    if (strcmp(action, "enable-adb-config") == 0 || strcmp(action, "restore-adb-config") == 0) {
        const int enable_adb = strcmp(action, "enable-adb-config") == 0;
        const char *write_command = enable_adb
            ? "AT+QCFG=\"USBCFG\",0x2C7C,0x0125,1,1,1,1,1,1,1"
            : "AT+QCFG=\"USBCFG\",0x2C7C,0x0125,1,1,1,1,1,0,1";

        if (run_command(modem, "AT+CLCC", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) || response_has_voice_call(response)) {
            fprintf(stderr, "ADB USBCFG write refused: empty voice-call state is not confirmed.\n");
            mavo_modem_destroy(modem);
            return 3;
        }
        if (run_command(modem, "AT+QCFG=\"USBCFG\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response)) {
            fprintf(stderr, "ADB USBCFG write refused: current tuple cannot be read.\n");
            mavo_modem_destroy(modem);
            return 3;
        }
        if (response_has_usb_config(response, enable_adb, 1)) {
            printf("\nUSBCFG already has the requested exact ADB/UAC value.\n");
            mavo_modem_destroy(modem);
            return 0;
        }
        if (!response_has_usb_config(response, !enable_adb, 1)) {
            fprintf(
                stderr,
                "ADB USBCFG write refused: expected the exact UAC-enabled tuple with only ADB inverted.\n"
            );
            mavo_modem_destroy(modem);
            return 3;
        }

        int write_result = run_command(modem, write_command, 5000, response, sizeof(response));
        if (write_result != MAVO_MODEM_OK) {
            fprintf(
                stderr,
                "ADB USBCFG response is ambiguous; do not repeat. Re-enumerate and read back.\n"
            );
            mavo_modem_destroy(modem);
            return 10;
        }
        if (!response_succeeded(response)) {
            fprintf(stderr, "ADB USBCFG write was explicitly rejected.\n");
            mavo_modem_destroy(modem);
            return 4;
        }
        if (run_command(modem, "AT+QCFG=\"USBCFG\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK) {
            fprintf(stderr, "ADB USBCFG was accepted and USB detached before read-back.\n");
            mavo_modem_destroy(modem);
            return 10;
        }
        if (!response_succeeded(response) ||
            !response_has_usb_config(response, enable_adb, 1)) {
            fprintf(stderr, "ADB USBCFG post-write read-back did not match the exact target.\n");
            mavo_modem_destroy(modem);
            return 5;
        }
        printf("\nADB/UAC USBCFG exact write and read-back verified; controlled restart is required.\n");
        mavo_modem_destroy(modem);
        return 0;
    }

    if (strcmp(action, "enable-uac-config") == 0 || strcmp(action, "restore-uac-config") == 0) {
        const int enable = strcmp(action, "enable-uac-config") == 0;
        const char *write_command = enable
            ? "AT+QCFG=\"USBCFG\",0x2C7C,0x0125,1,1,1,1,1,0,1"
            : "AT+QCFG=\"USBCFG\",0x2C7C,0x0125,1,1,1,1,1,0,0";

        if (run_command(modem, "AT+CLCC", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) || response_has_voice_call(response)) {
            fprintf(stderr, "USBCFG write refused: voice-call state is not confirmed empty.\n");
            mavo_modem_destroy(modem);
            return 3;
        }
        if (enable) {
            if (run_command(modem, "AT+QPCMV=?", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
                !response_succeeded(response) || strstr(response, "0-2") == NULL) {
                fprintf(stderr, "UAC enable refused: QPCMV option 2 was not advertised.\n");
                mavo_modem_destroy(modem);
                return 3;
            }
        }
        if (run_command(modem, "AT+QCFG=\"USBCFG\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response)) {
            mavo_modem_destroy(modem);
            return 3;
        }
        if (response_has_uac_config(response, enable)) {
            printf("\nUSBCFG already has the requested exact value.\n");
            mavo_modem_destroy(modem);
            return 0;
        }
        if (!response_has_uac_config(response, !enable)) {
            fprintf(stderr, "USBCFG write refused: current tuple is neither the recorded original nor the exact UAC target.\n");
            mavo_modem_destroy(modem);
            return 3;
        }

        int write_result = run_command(modem, write_command, 5000, response, sizeof(response));
        if (write_result != MAVO_MODEM_OK) {
            fprintf(stderr, "USBCFG write response is ambiguous; do not repeat it. Re-enumerate and read back actual state.\n");
            mavo_modem_destroy(modem);
            return 10;
        }
        if (!response_succeeded(response)) {
            fprintf(stderr, "USBCFG write was explicitly rejected.\n");
            mavo_modem_destroy(modem);
            return 4;
        }
        if (run_command(modem, "AT+QCFG=\"USBCFG\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK) {
            fprintf(stderr, "USBCFG write was accepted and the device detached before read-back.\n");
            mavo_modem_destroy(modem);
            return 10;
        }
        if (!response_has_uac_config(response, enable)) {
            fprintf(stderr, "USBCFG post-write read-back did not match the requested exact tuple.\n");
            mavo_modem_destroy(modem);
            return 5;
        }
        printf("\nUSBCFG exact write and read-back verified; restart may still be required.\n");
        mavo_modem_destroy(modem);
        return 0;
    }

    if (strcmp(action, "restart-uac") == 0 ||
        strcmp(action, "restart-uac-adb") == 0 ||
        strcmp(action, "restart-original") == 0) {
        const int expect_uac = strcmp(action, "restart-original") != 0;
        const int expect_adb = strcmp(action, "restart-uac-adb") == 0;
        if (run_command(modem, "AT+QCFG=\"USBCFG\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            !response_succeeded(response) ||
            !response_has_usb_config(response, expect_adb, expect_uac)) {
            fprintf(stderr, "Module restart refused: USBCFG does not match the expected exact tuple.\n");
            mavo_modem_destroy(modem);
            return 3;
        }
        printf("\nUSBCFG exact tuple verified. Requesting one controlled module restart...\n");
        (void)run_command(modem, "AT+CFUN=1,1", 1000, response, sizeof(response));
        mavo_modem_destroy(modem);
        return 0;
    }

    if (run_command(modem, "AT+QCFG=\"usbnet\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK) {
        mavo_modem_destroy(modem);
        return 1;
    }
    if (strstr(response, "\"usbnet\",1") == NULL) {
        if (run_command(modem, "AT+QCFG=\"usbnet\",1", 5000, response, sizeof(response)) != MAVO_MODEM_OK) {
            mavo_modem_destroy(modem);
            return 1;
        }
        if (run_command(modem, "AT+QCFG=\"usbnet\"", 3000, response, sizeof(response)) != MAVO_MODEM_OK ||
            strstr(response, "\"usbnet\",1") == NULL) {
            fprintf(stderr, "ECM read-back verification failed; module was not restarted.\n");
            mavo_modem_destroy(modem);
            return 1;
        }
    }

    printf("\nECM mode verified. Restarting the module...\n");
    (void)run_command(modem, "AT+CFUN=1,1", 1000, response, sizeof(response));
    mavo_modem_destroy(modem);
    return 0;
}
