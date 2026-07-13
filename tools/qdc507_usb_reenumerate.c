#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USB.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define TARGET_VENDOR UINT16_C(0x2C7C)
#define TARGET_PRODUCT UINT16_C(0x0125)
#define TARGET_LOCATION UINT32_C(0x01100000)

static int read_u32_property(io_registry_entry_t entry, CFStringRef key, uint32_t *value) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(
        entry,
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
    int64_t parsed = 0;
    int ok = CFNumberGetValue((CFNumberRef)property, kCFNumberSInt64Type, &parsed) &&
        parsed >= 0 && parsed <= UINT32_MAX;
    CFRelease(property);
    if (!ok) {
        return 0;
    }
    *value = (uint32_t)parsed;
    return 1;
}

static io_service_t find_exact_device(void) {
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == IO_OBJECT_NULL) {
        return IO_OBJECT_NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t result = IORegistryEntryCreateIterator(
        root,
        kIOUSBPlane,
        kIORegistryIterateRecursively,
        &iterator
    );
    IOObjectRelease(root);
    if (result != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_service_t selected = IO_OBJECT_NULL;
    unsigned matches = 0;
    io_registry_entry_t entry = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint32_t vendor = 0;
        uint32_t product = 0;
        uint32_t location = 0;
        int match = IOObjectConformsTo(entry, "IOUSBHostDevice") &&
            read_u32_property(entry, CFSTR("idVendor"), &vendor) &&
            read_u32_property(entry, CFSTR("idProduct"), &product) &&
            read_u32_property(entry, CFSTR("locationID"), &location) &&
            vendor == TARGET_VENDOR && product == TARGET_PRODUCT &&
            location == TARGET_LOCATION;
        if (!match) {
            IOObjectRelease(entry);
            continue;
        }
        matches++;
        if (selected == IO_OBJECT_NULL) {
            selected = entry;
        } else {
            IOObjectRelease(entry);
        }
    }
    IOObjectRelease(iterator);
    if (matches != 1) {
        if (selected != IO_OBJECT_NULL) {
            IOObjectRelease(selected);
        }
        fprintf(stderr, "refusing USB re-enumeration: exact device matches=%u\n", matches);
        return IO_OBJECT_NULL;
    }
    return selected;
}

static void print_configuration_descriptors(IOUSBDeviceInterface650 **device) {
    UInt8 count = 0;
    IOReturn result = (*device)->GetNumberOfConfigurations(device, &count);
    printf("GetNumberOfConfigurations result=0x%08X count=%u\n", result, count);
    UInt8 current = 0;
    result = (*device)->GetConfiguration(device, &current);
    printf("GetConfiguration result=0x%08X current=%u\n", result, current);
    for (UInt8 index = 0; index < count; index++) {
        IOUSBConfigurationDescriptorPtr config = NULL;
        result = (*device)->GetConfigurationDescriptorPtr(device, index, &config);
        if (result != kIOReturnSuccess || config == NULL) {
            printf("configuration[%u] unavailable result=0x%08X\n", index, result);
            continue;
        }
        UInt16 total = USBToHostWord(config->wTotalLength);
        printf(
            "configuration[%u] value=%u interfaces=%u total=%u attributes=0x%02X maxPower=%u\n",
            index,
            config->bConfigurationValue,
            config->bNumInterfaces,
            total,
            config->bmAttributes,
            config->MaxPower
        );
        const UInt8 *bytes = (const UInt8 *)config;
        UInt16 offset = 0;
        while (offset + 2 <= total) {
            UInt8 length = bytes[offset];
            UInt8 type = bytes[offset + 1];
            if (length < 2 || offset + length > total) {
                printf(" descriptor INVALID offset=%u length=%u type=0x%02X\n", offset, length, type);
                break;
            }
            if (type == kUSBInterfaceDesc && length >= sizeof(IOUSBInterfaceDescriptor)) {
                const IOUSBInterfaceDescriptor *interface =
                    (const IOUSBInterfaceDescriptor *)(bytes + offset);
                printf(
                    " interface offset=%u number=%u alt=%u endpoints=%u class=%02X/%02X/%02X\n",
                    offset,
                    interface->bInterfaceNumber,
                    interface->bAlternateSetting,
                    interface->bNumEndpoints,
                    interface->bInterfaceClass,
                    interface->bInterfaceSubClass,
                    interface->bInterfaceProtocol
                );
            } else if (type == kUSBEndpointDesc && length >= sizeof(IOUSBEndpointDescriptor)) {
                const IOUSBEndpointDescriptor *endpoint =
                    (const IOUSBEndpointDescriptor *)(bytes + offset);
                printf(
                    "  endpoint offset=%u address=0x%02X attributes=0x%02X maxPacket=%u interval=%u\n",
                    offset,
                    endpoint->bEndpointAddress,
                    endpoint->bmAttributes,
                    USBToHostWord(endpoint->wMaxPacketSize),
                    endpoint->bInterval
                );
            }
            offset = (UInt16)(offset + length);
        }
    }
}

int main(int argc, char **argv) {
    int describe_only = argc == 2 && strcmp(argv[1], "describe") == 0;
    int set_configuration = argc == 2 && strcmp(argv[1], "set-config") == 0;
    int reset_configuration = argc == 2 && strcmp(argv[1], "reset-config") == 0;
    int bus_reset = argc == 2 && strcmp(argv[1], "bus-reset") == 0;
    int suspend_resume = argc == 2 && strcmp(argv[1], "suspend-resume") == 0;
    if (argc > 2 ||
        (argc == 2 && !describe_only && !set_configuration &&
         !reset_configuration && !bus_reset && !suspend_resume)) {
        fprintf(
            stderr,
            "usage: %s [describe|set-config|reset-config|bus-reset|suspend-resume]\n",
            argv[0]
        );
        return 64;
    }
    io_service_t service = find_exact_device();
    if (service == IO_OBJECT_NULL) {
        return 2;
    }

    uint64_t registry_id = 0;
    (void)IORegistryEntryGetRegistryEntryID(service, &registry_id);
    printf(
        "Matched USB %04X:%04X location=0x%08X registry=%llu\n",
        TARGET_VENDOR,
        TARGET_PRODUCT,
        TARGET_LOCATION,
        registry_id
    );

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    IOObjectRelease(service);
    if (result != kIOReturnSuccess || plugin == NULL) {
        fprintf(stderr, "create USB device user client failed: 0x%08X\n", result);
        return 3;
    }

    IOUSBDeviceInterface650 **device = NULL;
    HRESULT query = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650),
        (LPVOID *)&device
    );
    IODestroyPlugInInterface(plugin);
    if (query != S_OK || device == NULL) {
        fprintf(stderr, "query IOUSBDeviceInterface650 failed: 0x%08X\n", (unsigned)query);
        return 4;
    }

    if (describe_only) {
        print_configuration_descriptors(device);
        (*device)->Release(device);
        return 0;
    }

    result = (*device)->USBDeviceOpen(device);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "USBDeviceOpen failed: 0x%08X\n", result);
        (*device)->Release(device);
        return 5;
    }

    if (bus_reset) {
        printf("Requesting one standard USB bus reset.\n");
        result = (*device)->ResetDevice(device);
        if (result != kIOReturnSuccess) {
            fprintf(stderr, "ResetDevice failed: 0x%08X\n", result);
            (void)(*device)->USBDeviceClose(device);
            (*device)->Release(device);
            return 8;
        }
        (void)(*device)->USBDeviceClose(device);
        (*device)->Release(device);
        printf("USB bus reset accepted.\n");
        return 0;
    }

    if (suspend_resume) {
        printf("Requesting one standard USB suspend/resume cycle.\n");
        result = (*device)->USBDeviceSuspend(device, true);
        if (result == kIOReturnSuccess) {
            const struct timespec settle = {
                .tv_sec = 1,
                .tv_nsec = 0
            };
            (void)nanosleep(&settle, NULL);
            result = (*device)->USBDeviceSuspend(device, false);
        }
        if (result != kIOReturnSuccess) {
            fprintf(stderr, "USBDeviceSuspend cycle failed: 0x%08X\n", result);
            (void)(*device)->USBDeviceClose(device);
            (*device)->Release(device);
            return 8;
        }
        (void)(*device)->USBDeviceClose(device);
        (*device)->Release(device);
        printf("USB suspend/resume cycle accepted.\n");
        return 0;
    }

    if (set_configuration || reset_configuration) {
        UInt8 count = 0;
        IOUSBConfigurationDescriptorPtr config = NULL;
        result = (*device)->GetNumberOfConfigurations(device, &count);
        if (result != kIOReturnSuccess || count != 1) {
            fprintf(stderr, "set-config refused: configuration count result=0x%08X count=%u\n", result, count);
            (void)(*device)->USBDeviceClose(device);
            (*device)->Release(device);
            return 7;
        }
        result = (*device)->GetConfigurationDescriptorPtr(device, 0, &config);
        if (result != kIOReturnSuccess || config == NULL || config->bConfigurationValue != 1) {
            fprintf(stderr, "set-config refused: exact configuration value 1 is unavailable.\n");
            (void)(*device)->USBDeviceClose(device);
            (*device)->Release(device);
            return 7;
        }
        if (reset_configuration) {
            printf("Requesting standard SetConfiguration(0) to clear stale endpoints.\n");
            result = (*device)->SetConfiguration(device, 0);
            if (result != kIOReturnSuccess) {
                fprintf(stderr, "SetConfiguration(0) failed: 0x%08X\n", result);
                (void)(*device)->USBDeviceClose(device);
                (*device)->Release(device);
                return 8;
            }
            const struct timespec settle = {
                .tv_sec = 0,
                .tv_nsec = 500 * 1000 * 1000
            };
            (void)nanosleep(&settle, NULL);
        }
        printf("Requesting standard SetConfiguration(1).\n");
        result = (*device)->SetConfiguration(device, 1);
        if (result != kIOReturnSuccess) {
            fprintf(stderr, "SetConfiguration(1) failed: 0x%08X\n", result);
            (void)(*device)->USBDeviceClose(device);
            (*device)->Release(device);
            return 8;
        }
        (void)(*device)->USBDeviceClose(device);
        (*device)->Release(device);
        printf("SetConfiguration(1) accepted.\n");
        return 0;
    }

    printf("Requesting one standard USBDeviceReEnumerate with extra reset time.\n");
    result = (*device)->USBDeviceReEnumerate(device, kUSBAddExtraResetTimeMask);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "USBDeviceReEnumerate failed: 0x%08X\n", result);
        (void)(*device)->USBDeviceClose(device);
        (*device)->Release(device);
        return 6;
    }
    (*device)->Release(device);
    printf("USBDeviceReEnumerate accepted.\n");
    return 0;
}
