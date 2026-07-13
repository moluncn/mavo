#include "CModemBridge.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    MaVoModem *modem = mavo_modem_create();
    assert(modem != NULL);
    assert(mavo_modem_is_open(modem) == 0);
    assert(mavo_modem_interrupt_read(modem) == MAVO_MODEM_NOT_OPEN);
    mavo_modem_close(modem);
    mavo_modem_destroy(modem);
    puts("CModemBridge self-tests passed (lifecycle and idle read interruption).");
    return 0;
}
