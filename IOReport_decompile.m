/*
 * libIOReport.dylib decompiled by hand by dehydratedpotato, 2023
 * Fixed by: correct subbedChannels output, VLA→heap, proper state name/residency
 *           reading, IOReportCreateSamplesDelta, IOReportMergeChannels,
 *           CF retain/release callbacks throughout.
 */

#include <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <ctype.h>

#include "IOReport_decompile.h"
#include "IOReportTypes.h"
#include "IOKernelReportStructs.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

/* Macros for hub userclient methods */
#define kIOReportUserClientOpen                 0
#define kIOReportUserClientConfigureInterests   2
#define kIOReportUserClientUpdateKernelBuffer   3

/* Internal dictionary keys for raw sample data */
#define kDriverIdKey    CFSTR("DriverID")
#define kDrivernameKey  CFSTR("DriverName")
#define kRawElementskey CFSTR("RawElements")

/* Each IOReportElement in shared memory is 64 bytes:
 *   [0] provider_id  (uint64)
 *   [1] channel_id   (uint64)
 *   [2] channel_type (uint64, packed IOReportChannelType)
 *   [3] timestamp    (uint64)
 *   [4] values[0]    <- simple_value  /  state_id
 *   [5] values[1]    <- reserved      /  intransitions
 *   [6] values[2]    <- reserved      /  upticks (residency)
 *   [7] values[3]    <- reserved      /  last_intransition
 */
#define kIOReportElemSize       64
#define kIOReportValuesOffset    4   /* uint64 index of values[0] within element */

/* CFRuntime extern syms */
typedef struct __CFRuntimeClass {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef cf);
    CFTypeRef (*copy)(CFAllocatorRef allocator, CFTypeRef cf);
    void (*finalize)(CFTypeRef cf);
    Boolean (*equal)(CFTypeRef cf1, CFTypeRef cf2);
    CFHashCode (*hash)(CFTypeRef cf);
    CFStringRef (*copyFormattingDesc)(CFTypeRef cf, CFDictionaryRef formatOptions);
    CFStringRef (*copyDebugDesc)(CFTypeRef cf);
    void (*reclaim)(CFTypeRef cf);
} CFRuntimeClass;

typedef struct __CFRuntimeBase {
    uintptr_t _cfisa;
    uint8_t _cfinfo[4];
#if __LP64__
    uint32_t _rc;
#endif
} CFRuntimeBase;

CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass* const cls);
CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator,
                                   CFTypeID typeID,
                                   CFIndex extraBytes,
                                   unsigned char* category);

static CFRuntimeClass _IOReportSubscriptionClass = { 0, "IOReportSubscription" };
struct IOReportSubscription {
    CFRuntimeBase     base;
    io_connect_t      connection;
    uint64_t          dwordPtr;
    mach_vm_address_t addr;
    mach_vm_size_t    addrSize;
};

// MARK: - Internal helpers

/* Returns a const pointer to the raw IOReportElement bytes for a sample channel dict.
 * Safe: points into an immutable CFData, no allocation needed. */
static const uint64_t *_get_raw_elements(CFDictionaryRef a) {
    if (a == NULL) return NULL;
    CFDataRef data = (CFDataRef)CFDictionaryGetValue(a, kRawElementskey);
    if (data == NULL || CFDataGetLength(data) == 0) return NULL;
    return (const uint64_t *)CFDataGetBytePtr(data);
}

/* Returns the IOReportChannelType packed into a uint64 from the per-channel sub-array. */
static IOReportChannelType _get_channel_type(CFDictionaryRef sample) {
    IOReportChannelType ct = {0};
    if (sample == NULL) return ct;
    CFArrayRef arr = (CFArrayRef)CFDictionaryGetValue(sample, CFSTR(kIOReportLegendChannelsKey));
    if (arr == NULL || CFArrayGetCount(arr) <= kIOReportChannelTypeIdx) return ct;
    CFNumberRef n = (CFNumberRef)CFArrayGetValueAtIndex(arr, kIOReportChannelTypeIdx);
    if (n == NULL) return ct;
    uint64_t raw = 0;
    CFNumberGetValue(n, kCFNumberLongLongType, &raw);
    memcpy(&ct, &raw, sizeof(ct));
    return ct;
}

// MARK: - Channel Functions

CFMutableDictionaryRef _copy_chann(NSString* group) {
    /* Use proper CF retain/release callbacks throughout so nothing is released early. */
    CFMutableDictionaryRef dict =
        CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                  &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    CFMutableArrayRef channels =
        CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

    io_iterator_t iter;
    io_registry_entry_t entry;

    kern_return_t kr = IORegistryCreateIterator(MACH_PORT_NULL, kIOServicePlane,
                                                kIORegistryIterateRecursively, &iter);
    if (kr != kIOReturnSuccess) { CFRelease(channels); CFRelease(dict); return NULL; }

    while ((entry = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        char name[56] = {};
        uint64_t entid = 0;

        CFArrayRef legend = (CFArrayRef)IORegistryEntryCreateCFProperty(
            entry, CFSTR(kIOReportLegendKey), kCFAllocatorDefault, 0);
        if (legend == NULL) { IOObjectRelease(entry); continue; }

        IORegistryEntryGetName(entry, name);
        IORegistryEntryGetRegistryEntryID(entry, &entid);
        /* Retain dname via CFString so it lives as long as the dicts that hold it. */
        CFStringRef dname = CFStringCreateWithFormat(kCFAllocatorDefault, NULL,
                                                     CFSTR("%s <id: 0x%.2llx>"), name, entid);
        CFNumberRef entidNum = CFNumberCreate(kCFAllocatorDefault,
                                              kCFNumberLongLongType, &entid);

        for (int i = 0; i < CFArrayGetCount(legend); i++) {
            CFDictionaryRef legendEntry =
                (CFDictionaryRef)CFArrayGetValueAtIndex(legend, i);

            /* Filter by group name if requested */
            CFStringRef groupName = (CFStringRef)CFDictionaryGetValue(
                legendEntry, CFSTR(kIOReportLegendGroupNameKey));
            if (group != NULL && groupName != NULL &&
                !CFEqual(groupName, (__bridge CFStringRef)group)) {
                continue;
            }

            CFArrayRef chann_array = (CFArrayRef)CFDictionaryGetValue(
                legendEntry, CFSTR(kIOReportLegendChannelsKey));
            if (chann_array == NULL) continue;

            for (int ii = 0; ii < CFArrayGetCount(chann_array); ii++) {
                CFMutableDictionaryRef subbdict =
                    CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);

                CFDictionarySetValue(subbdict, kDriverIdKey, entidNum);
                CFDictionarySetValue(subbdict, kDrivernameKey, dname);

                CFTypeRef v;
                v = CFDictionaryGetValue(legendEntry, CFSTR(kIOReportLegendInfoKey));
                if (v) CFDictionarySetValue(subbdict, CFSTR(kIOReportLegendInfoKey), v);
                v = CFDictionaryGetValue(legendEntry, CFSTR(kIOReportLegendGroupNameKey));
                if (v) CFDictionarySetValue(subbdict, CFSTR(kIOReportLegendGroupNameKey), v);
                v = CFDictionaryGetValue(legendEntry, CFSTR(kIOReportLegendSubGroupNameKey));
                if (v) CFDictionarySetValue(subbdict, CFSTR(kIOReportLegendSubGroupNameKey), v);

                /* Store the per-channel sub-array [channel_id, channel_type, name, ...] */
                CFTypeRef perChan = CFArrayGetValueAtIndex(chann_array, ii);
                if (perChan)
                    CFDictionarySetValue(subbdict, CFSTR(kIOReportLegendChannelsKey), perChan);

                CFArrayAppendValue(channels, subbdict);
                CFRelease(subbdict);
            }
        }

        CFRelease(dname);
        CFRelease(entidNum);
        CFRelease(legend);
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);

    if (CFArrayGetCount(channels) != 0)
        CFDictionarySetValue(dict, CFSTR(kIOReportLegendChannelsKey), channels);
    CFDictionarySetValue(dict, CFSTR("QueryOpts"), CFSTR("0"));
    CFRelease(channels);
    return dict;
}

CFMutableDictionaryRef IOReportCopyChannelsInGroup(NSString* group, NSString* subgroup,
                                                   uint64_t a, uint64_t b, uint64_t c) {
    return _copy_chann(group);
}
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b) {
    return _copy_chann(NULL);
}

/* Append all channels from src into dest. */
void IOReportMergeChannels(CFMutableDictionaryRef dest, CFMutableDictionaryRef src,
                           CFTypeRef nil_unused) {
    if (dest == NULL || src == NULL) return;
    CFMutableArrayRef destArr =
        (CFMutableArrayRef)CFDictionaryGetValue(dest, CFSTR(kIOReportLegendChannelsKey));
    CFArrayRef srcArr =
        (CFArrayRef)CFDictionaryGetValue(src, CFSTR(kIOReportLegendChannelsKey));
    if (destArr == NULL || srcArr == NULL) return;
    for (CFIndex i = 0; i < CFArrayGetCount(srcArr); i++)
        CFArrayAppendValue(destArr, CFArrayGetValueAtIndex(srcArr, i));
}

// MARK: - Subscription Functions

IOReportInterestList* _create_interlist(CFArrayRef channels, int count) {
    IOReportInterestList *interestList = malloc((size_t)count * 0x18 + 8);
    if (!interestList) return NULL;
    interestList->ninterests = count;

    for (int i = 0; i < count; i++) {
        uint64_t channel_id   = 0;
        uint64_t provider_id  = 0;
        uint64_t channel_type_raw = 0;

        CFDictionaryRef chann =
            (CFDictionaryRef)CFArrayGetValueAtIndex(channels, i);
        CFArrayRef legend_chann =
            (CFArrayRef)CFDictionaryGetValue(chann, CFSTR(kIOReportLegendChannelsKey));

        if (legend_chann && CFArrayGetCount(legend_chann) > kIOReportChannelTypeIdx) {
            CFNumberRef n = (CFNumberRef)CFArrayGetValueAtIndex(legend_chann, kIOReportChannelIDIdx);
            if (n) CFNumberGetValue(n, kCFNumberLongLongType, &channel_id);
            n = (CFNumberRef)CFArrayGetValueAtIndex(legend_chann, kIOReportChannelTypeIdx);
            if (n) CFNumberGetValue(n, kCFNumberLongLongType, &channel_type_raw);
        }

        CFNumberRef driver_id = (CFNumberRef)CFDictionaryGetValue(chann, kDriverIdKey);
        if (driver_id) CFNumberGetValue(driver_id, kCFNumberLongLongType, &provider_id);

        IOReportChannelType channel_type = *(IOReportChannelType*)&channel_type_raw;
        IOReportChannel channel = {
            .channel_id   = channel_id,
            .channel_type = channel_type
        };
        IOReportInterest interest = {
            .provider_id = provider_id,
            .channel     = channel
        };
        interestList->interests[i] = interest;
    }
    return interestList;
}

IOReportSubscriptionRef IOReportCreateSubscription(void* a,
                                                   CFMutableDictionaryRef desiredChannels,
                                                   CFMutableDictionaryRef* subbedChannels,
                                                   uint64_t channel_id,
                                                   CFTypeRef b) {
    const uint32_t count = IOReportGetChannelCount(desiredChannels);
    if (count <= 0) return NULL;

    CFTypeID                iorepTypeId;
    IOReportSubscriptionRef iorepSubscription = NULL;
    kern_return_t           kr;
    io_iterator_t           iter;
    io_service_t            service  = 0;
    io_connect_t            connection = 0;

    const uint32_t input  = count * 0x18 + 8;
    uint32_t       output = 1;

    iorepTypeId = _CFRuntimeRegisterClass(&_IOReportSubscriptionClass);
    iorepSubscription = (IOReportSubscriptionRef)
        _CFRuntimeCreateInstance(kCFAllocatorDefault, iorepTypeId, 0x20, 0);

    CFArrayRef channs = (CFArrayRef)CFDictionaryGetValue(
        desiredChannels, CFSTR(kIOReportLegendChannelsKey));
    IOReportInterestList* interestList = _create_interlist(channs, count);
    if (!interestList) return NULL;

    kr = IOServiceGetMatchingServices(MACH_PORT_NULL,
                                      IOServiceMatching("IOReportHub"), &iter);
    if (kr != KERN_SUCCESS) { free(interestList); return NULL; }

    while ((service = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
        kr = IOServiceOpen(service, mach_task_self(), 0, &connection);
        IOObjectRelease(service);
        if (kr == KERN_SUCCESS) break;
        connection = 0;
    }
    IOObjectRelease(iter);
    if (connection == 0) { free(interestList); return NULL; }

    kr = IOConnectCallScalarMethod(connection, kIOReportUserClientOpen, 0, 0, 0, 0);
    if (kr != KERN_SUCCESS) {
        IOServiceClose(connection);
        free(interestList);
        return NULL;
    }

    iorepSubscription->connection = connection;

    kr = IOConnectCallMethod(iorepSubscription->connection,
                             kIOReportUserClientConfigureInterests,
                             NULL, 0,
                             interestList, input,
                             &iorepSubscription->dwordPtr, &output,
                             NULL, 0);
    free(interestList);
    if (kr != KERN_SUCCESS) return NULL;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wconversion"
    kr = IOConnectMapMemory(iorepSubscription->connection,
                            iorepSubscription->dwordPtr,
                            mach_task_self(),
                            &iorepSubscription->addr,
                            &iorepSubscription->addrSize, 1);
#pragma clang diagnostic pop

    if (kr != KERN_SUCCESS) {
        IOConnectUnmapMemory(connection, iorepSubscription->dwordPtr,
                             mach_task_self(), iorepSubscription->addr);
        return NULL;
    }

    /* FIX: set the output parameter so callers can use it in IOReportCreateSamples */
    if (subbedChannels != NULL)
        *subbedChannels = (CFMutableDictionaryRef)CFRetain(desiredChannels);

    return iorepSubscription;
}

// MARK: - Sampling Functions

CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef iorsub,
                                      CFMutableDictionaryRef subbedChannels,
                                      CFTypeRef a) {
    if (iorsub == NULL || subbedChannels == NULL) return NULL;
    if (iorsub->connection == 0) return NULL;

    kern_return_t kr = IOConnectCallMethod(iorsub->connection,
                                           kIOReportUserClientUpdateKernelBuffer,
                                           &iorsub->dwordPtr, 1, 0, 0, 0, 0, 0, 0);
    if (kr != KERN_SUCCESS) return NULL;

    CFArrayRef srcArray = (CFArrayRef)CFDictionaryGetValue(
        subbedChannels, CFSTR(kIOReportLegendChannelsKey));
    if (srcArray == NULL) return NULL;
    int total = IOReportGetChannelCount(subbedChannels);

    /*
     * FIX: The kernel fills shared memory in its own canonical order, which
     * may differ from the order we sent in the interest list.  So we CANNOT
     * use a running byteIndex based on our channel array order.
     *
     * Instead, scan the shared memory sequentially.  Each 64-byte element
     * contains channel_id at byte offset 8 (ptr[1]).  We group consecutive
     * elements that share a channel_id into one NSMutableData, then build a
     * channel_id → raw-bytes dictionary.  Finally we look up each channel in
     * subbedChannels by its channel_id and attach the matching raw bytes.
     */
    const uint64_t *mem = (iorsub->addr && iorsub->addrSize > 0)
        ? (const uint64_t *)(uintptr_t)iorsub->addr : NULL;
    long totalElems = mem ? (long)iorsub->addrSize / kIOReportElemSize : 0;

    /* channel_id(uint64) -> NSMutableData accumulating element bytes */
    NSMutableDictionary<NSNumber*, NSMutableData*> *rawByID =
        [NSMutableDictionary dictionaryWithCapacity:total];

    for (long e = 0; e < totalElems; e++) {
        const uint64_t *elem = mem + e * 8;          /* 8 uint64_t = 64 bytes */
        uint64_t channel_id  = elem[1];              /* byte 8..15 */
        if (channel_id == 0) break;                  /* past end of valid data */

        NSNumber *key  = @(channel_id);
        NSMutableData *data = rawByID[key];
        if (data == nil) {
            data = [NSMutableData dataWithCapacity:kIOReportElemSize];
            rawByID[key] = data;
        }
        [data appendBytes:elem length:kIOReportElemSize];
    }

    /* Build result array in subbedChannels order (what callers iterate). */
    CFMutableArrayRef resultArray =
        CFArrayCreateMutable(kCFAllocatorDefault, total, &kCFTypeArrayCallBacks);

    for (int i = 0; i < total; i++) {
        CFDictionaryRef srcCh =
            (CFDictionaryRef)CFArrayGetValueAtIndex(srcArray, i);

        CFMutableDictionaryRef sampleCh =
            CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, srcCh);

        /* Look up raw data by channel_id */
        CFArrayRef perChan = (CFArrayRef)CFDictionaryGetValue(
            srcCh, CFSTR(kIOReportLegendChannelsKey));
        if (perChan && CFArrayGetCount(perChan) > kIOReportChannelIDIdx) {
            CFNumberRef idNum = (CFNumberRef)
                CFArrayGetValueAtIndex(perChan, kIOReportChannelIDIdx);
            if (idNum) {
                uint64_t cid = 0;
                CFNumberGetValue(idNum, kCFNumberLongLongType, &cid);
                NSMutableData *raw = rawByID[@(cid)];
                if (raw) {
                    CFDataRef cfRaw = (__bridge CFDataRef)raw;
                    CFDictionarySetValue(sampleCh, kRawElementskey, cfRaw);
                }
            }
        }

        CFArrayAppendValue(resultArray, sampleCh);
        CFRelease(sampleCh);
    }

    CFMutableDictionaryRef result =
        CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                  &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(result, CFSTR(kIOReportLegendChannelsKey), resultArray);
    CFRelease(resultArray);
    return result;
}

/*
 * IOReportCreateSamplesDelta
 *
 * For each channel at the same index in prev/curr, subtracts the raw element
 * values to produce a delta snapshot.
 *
 * State format  (kIOReportFormatState):
 *   values[0] = state_id        — preserved (identity, not a counter)
 *   values[1] = intransitions   — subtracted
 *   values[2] = upticks         — subtracted  (residency)
 *   values[3] = last_intransition — preserved (timestamp)
 *
 * Simple / other formats: subtract all values[] fields.
 */
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef curr,
                                           CFTypeRef nil_unused) {
    if (prev == NULL || curr == NULL)
        return curr ? (CFDictionaryRef)CFRetain(curr) : NULL;

    CFArrayRef currArr = (CFArrayRef)CFDictionaryGetValue(curr, CFSTR(kIOReportLegendChannelsKey));
    CFArrayRef prevArr = (CFArrayRef)CFDictionaryGetValue(prev, CFSTR(kIOReportLegendChannelsKey));
    if (currArr == NULL || prevArr == NULL)
        return (CFDictionaryRef)CFRetain(curr);

    CFIndex count = MIN(CFArrayGetCount(currArr), CFArrayGetCount(prevArr));
    CFMutableArrayRef deltaArr =
        CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);

    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef cCh = (CFDictionaryRef)CFArrayGetValueAtIndex(currArr, i);
        CFDictionaryRef pCh = (CFDictionaryRef)CFArrayGetValueAtIndex(prevArr, i);

        CFDataRef cData = (CFDataRef)CFDictionaryGetValue(cCh, kRawElementskey);
        CFDataRef pData = (CFDataRef)CFDictionaryGetValue(pCh, kRawElementskey);

        if (cData == NULL || pData == NULL ||
            CFDataGetLength(cData) != CFDataGetLength(pData) ||
            CFDataGetLength(cData) == 0 ||
            CFDataGetLength(cData) % kIOReportElemSize != 0) {
            CFArrayAppendValue(deltaArr, cCh);
            continue;
        }

        long dataLen   = CFDataGetLength(cData);
        long nelements = dataLen / kIOReportElemSize;

        uint8_t *dbuf = (uint8_t *)malloc((size_t)dataLen);
        if (dbuf == NULL) { CFArrayAppendValue(deltaArr, cCh); continue; }

        memcpy(dbuf, CFDataGetBytePtr(cData), (size_t)dataLen);
        const uint64_t *pPtr = (const uint64_t *)CFDataGetBytePtr(pData);
        uint64_t       *dPtr = (uint64_t *)dbuf;

        int fmt = IOReportChannelGetFormat(cCh);

        for (long e = 0; e < nelements; e++) {
            long base = e * 8;
            if (fmt == kIOReportFormatState) {
                /* values[0] = state_id      → keep */
                /* values[1] = intransitions → subtract */
                dPtr[base + 5] -= pPtr[base + 5];
                /* values[2] = upticks       → subtract */
                dPtr[base + 6] -= pPtr[base + 6];
                /* values[3] = last_intransition → keep */
            } else {
                for (int v = kIOReportValuesOffset; v < 8; v++)
                    dPtr[base + v] -= pPtr[base + v];
            }
        }

        CFDataRef deltaData = CFDataCreate(kCFAllocatorDefault, dbuf, dataLen);
        free(dbuf);

        CFMutableDictionaryRef deltaCh =
            CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, cCh);
        CFDictionarySetValue(deltaCh, kRawElementskey, deltaData);
        CFRelease(deltaData);

        CFArrayAppendValue(deltaArr, deltaCh);
        CFRelease(deltaCh);
    }

    CFMutableDictionaryRef result =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, curr);
    CFDictionarySetValue(result, CFSTR(kIOReportLegendChannelsKey), deltaArr);
    CFRelease(deltaArr);
    return result;
}

// MARK: - Iteration

void IOReportIterate(CFDictionaryRef samples, IOReportiterateblock handler) {
    if (samples == NULL) return;
    uint32_t count = IOReportGetChannelCount(samples);
    CFArrayRef array = (CFArrayRef)CFDictionaryGetValue(samples, CFSTR(kIOReportLegendChannelsKey));
    for (int i = 0; i < (int)count; i++) {
        IOReportSampleRef channel =
            (IOReportSampleRef)CFArrayGetValueAtIndex(array, i);
        int ret = handler(channel);
        if (ret == re_kIOReportIterFailed) return;
    }
}

// MARK: - Channel attribute accessors

int IOReportGetChannelCount(CFDictionaryRef a) {
    if (a == NULL) return 0;
    CFArrayRef arr = (CFArrayRef)CFDictionaryGetValue(a, CFSTR(kIOReportLegendChannelsKey));
    return arr ? (int)CFArrayGetCount(arr) : 0;
}

NSString* IOReportChannelGetChannelName(CFDictionaryRef a) {
    if (a == NULL) return NULL;
    CFArrayRef arr = (CFArrayRef)CFDictionaryGetValue(a, CFSTR(kIOReportLegendChannelsKey));
    if (arr == NULL) return NULL;

    /* First try explicit name string at index 2 */
    if (CFArrayGetCount(arr) > kIOReportChannelNameIdx) {
        CFTypeRef nameRef = CFArrayGetValueAtIndex(arr, kIOReportChannelNameIdx);
        if (nameRef != NULL && CFGetTypeID(nameRef) == CFStringGetTypeID() &&
            CFStringGetLength((CFStringRef)nameRef) > 0) {
            return (__bridge NSString*)nameRef;
        }
    }

    /* Fallback: decode channel_id (index 0) as IOREPORT_MAKEID packed ASCII.
     * Per-core channels (ECPU000, PCPU030 etc.) store their name in channel_id. */
    if (CFArrayGetCount(arr) > kIOReportChannelIDIdx) {
        CFNumberRef idNum = (CFNumberRef)CFArrayGetValueAtIndex(arr, kIOReportChannelIDIdx);
        if (idNum != NULL) {
            uint64_t channel_id = 0;
            CFNumberGetValue(idNum, kCFNumberLongLongType, &channel_id);
            if (channel_id != 0) {
                char name[9] = {};
                int  len = 0;
                for (int shift = 56; shift >= 0; shift -= 8) {
                    char c = (char)((channel_id >> shift) & 0xff);
                    if (c != '\0' && isprint((unsigned char)c)) name[len++] = c;
                }
                if (len > 0) return [NSString stringWithUTF8String:name];
            }
        }
    }
    return NULL;
}

NSString* IOReportChannelGetGroup(CFDictionaryRef a) {
    if (a == NULL) return NULL;
    return (NSString*)CFDictionaryGetValue(a, CFSTR(kIOReportLegendGroupNameKey));
}

NSString* IOReportChannelGetSubGroup(CFDictionaryRef a) {
    if (a == NULL) return NULL;
    return (NSString*)CFDictionaryGetValue(a, CFSTR(kIOReportLegendSubGroupNameKey));
}

NSString* IOReportChannelGetDriverName(CFDictionaryRef a) {
    if (a == NULL) return NULL;
    return (NSString*)CFDictionaryGetValue(a, kDrivernameKey);
}

int IOReportChannelGetFormat(CFDictionaryRef samples) {
    if (samples == NULL) return 0;
    IOReportChannelType ct = _get_channel_type(samples);
    return (int)ct.report_format;
}

NSString* IOReportChannelGetUnitLabel(CFDictionaryRef a) {
    if (a == NULL) return NULL;
    uint64_t unit_label_qword = 0;
    CFDictionaryRef chann_inf =
        (CFDictionaryRef)CFDictionaryGetValue(a, CFSTR(kIOReportLegendInfoKey));
    if (chann_inf == NULL) return NULL;
    CFNumberRef unit_label =
        (CFNumberRef)CFDictionaryGetValue(chann_inf, CFSTR(kIOReportLegendUnitKey));
    if (unit_label == NULL) return NULL;
    CFNumberGetValue(unit_label, kCFNumberLongLongType, &unit_label_qword);

    switch (unit_label_qword) {
        case kIOReportUnit1GHzTicks:  return @"1GTicks";
        case kIOReportUnit24MHzTicks: return @"24MTicks";
        case kIOReportUnitHWTicks:    return @"HWTicks";
        case kIOReportUnitPackets:    return @"packets";
        case kIOReportUnitInstrs:     return @"instrs";
        case kIOReportUnitEvents:     return @"events";
        case kIOReportUnitBits:       return @"bits";
        case kIOReportUnitBytes:      return @"bytes";
        case kIOReportUnit_GI:        return @"gi";
        case kIOReportUnit_KI:        return @"ki";
        case kIOReportUnit_MI:        return @"mi";
        case kIOReportUnit_ms:        return @"ms";
        case kIOReportUnit_ns:        return @"ns";
        case kIOReportUnit_s:         return @"s";
        case kIOReportUnit_J:         return @"j";
        case kIOReportUnit_mJ:        return @"mj";
        case kIOReportUnit_pJ:        return @"pj";
        case kIOReportUnit_uJ:        return @"uj";
        case kIOReportUnit_nJ:        return @"nj";
        case kIOReportUnit_GiB:       return @"gib";
        case kIOReportUnit_MiB:       return @"mib";
        case kIOReportUnit_KiB:       return @"kib";
        case kIOReportUnitNone:
        default:                      return NULL;
    }
}

// MARK: - State format accessors

long IOReportStateGetCount(CFDictionaryRef a) {
    if (a == NULL) return 0;
    CFDataRef data = (CFDataRef)CFDictionaryGetValue(a, kRawElementskey);
    if (data == NULL) return 0;
    long length = CFDataGetLength(data);
    return (length > 0) ? length / kIOReportElemSize : 0;
}

/* FIX: was returning 0. Residency (upticks) is values[2] of element stateIdx.
 * Layout: ptr[stateIdx*8 + kIOReportValuesOffset + 2] */
uint64_t IOReportStateGetResidency(CFDictionaryRef a, int stateIdx) {
    const uint64_t *ptr = _get_raw_elements(a);
    if (ptr == NULL) return 0;
    return ptr[(long)stateIdx * 8 + kIOReportValuesOffset + 2];
}

/* FIX: was returning NULL.
 * Strategy 1 — read from kIOReportLegendStateNamesKey in the channel info dict.
 *              This is the authoritative name array the driver registers in the
 *              IORegistry legend (e.g. ["IDLE","V0","V1",...]).
 * Strategy 2 — decode the state_id field (values[0]) as an 8-char ASCII string
 *              packed via IOREPORT_MAKEID(). Char[0] is in the MSB. */
NSString* IOReportStateGetNameForIndex(CFDictionaryRef a, int stateIdx) {
    if (a == NULL) return NULL;

    /* Strategy 1: decode state_id from raw element via IOREPORT_MAKEID.
     * The kernel encodes state names as packed ASCII in values[0] of each
     * IOReportElement.  This is always the authoritative source — the legend's
     * kIOReportLegendStateNamesKey can be mismatched (e.g. PCPU Voltage States
     * sharing a legend entry with DVD states on some platforms). */
    const uint64_t *ptr = _get_raw_elements(a);
    if (ptr != NULL) {
        uint64_t state_id = ptr[(long)stateIdx * 8 + kIOReportValuesOffset];
        if (state_id != 0) {
            char name[9] = {};
            int  len = 0;
            for (int shift = 56; shift >= 0; shift -= 8) {
                char c = (char)((state_id >> shift) & 0xff);
                if (c != '\0' && isprint((unsigned char)c)) name[len++] = c;
            }
            if (len > 0) return [NSString stringWithUTF8String:name];
        }
    }

    /* Strategy 2: legend kIOReportLegendStateNamesKey (fallback if state_id == 0) */
    CFDictionaryRef info =
        (CFDictionaryRef)CFDictionaryGetValue(a, CFSTR(kIOReportLegendInfoKey));
    if (info != NULL) {
        CFArrayRef names =
            (CFArrayRef)CFDictionaryGetValue(info, CFSTR(kIOReportLegendStateNamesKey));
        if (names != NULL && stateIdx < (int)CFArrayGetCount(names)) {
            CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex(names, stateIdx);
            if (s != NULL) return (__bridge NSString*)s;
        }
    }
    return [NSString stringWithFormat:@"S%d", stateIdx];
}

// MARK: - Simple / array / histogram accessors

/* FIX: was returning *(ptr + 32) = byte offset 256, completely wrong.
 * values[0] of element `b` is at uint64 index b*8 + kIOReportValuesOffset
 * = byte offset b*64 + 32. */
long IOReportSimpleGetIntegerValue(CFDictionaryRef a, int b) {
    const uint64_t *ptr = _get_raw_elements(a);
    if (ptr == NULL) return 0;
    return (long)ptr[(long)b * 8 + kIOReportValuesOffset];
}

uint64_t IOReportArrayGetValueAtIndex(CFDictionaryRef a, int b) {
    const uint64_t *ptr = _get_raw_elements(a);
    if (ptr == NULL) return 0;
    return ptr[(long)b * 8 + kIOReportValuesOffset];
}

int IOReportHistogramGetBucketCount(CFDictionaryRef a)         { return 0; }
int IOReportHistogramGetBucketMinValue(CFDictionaryRef a, int b) { return 0; }
int IOReportHistogramGetBucketMaxValue(CFDictionaryRef a, int b) { return 0; }
int IOReportHistogramGetBucketSum(CFDictionaryRef a, int b)    { return 0; }
int IOReportHistogramGetBucketHits(CFDictionaryRef a, int b)   { return 0; }
