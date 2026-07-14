#include "CModemBridge.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    int32_t owner_pid = -1;
    char owner_name[32] = "unexpected";
    assert(mavo_usb_interface_owner_process(
        0,
        6,
        &owner_pid,
        owner_name,
        sizeof(owner_name)
    ) == 0);
    assert(owner_pid == 0);
    assert(owner_name[0] == '\0');

    MaVoModem *modem = mavo_modem_create();
    assert(modem != NULL);
    assert(mavo_modem_is_open(modem) == 0);
    assert(mavo_modem_interrupt_read(modem) == MAVO_MODEM_NOT_OPEN);
    mavo_modem_close(modem);
    mavo_modem_destroy(modem);
    puts("CModemBridge self-tests passed (lifecycle and idle read interruption).");
    return 0;
}
