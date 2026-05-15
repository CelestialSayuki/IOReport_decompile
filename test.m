/* Testing out IOReport - fixed version
 * code by dehydratedpotato, 2023 / fixes 2025
 */

#import <Foundation/Foundation.h>
#include <unistd.h>
#import "IOReport_decompile.h"
#include "IOReportTypes.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        /* Merge CPU + Energy + PMP like PowerMonitor does */
        CFMutableDictionaryRef chn = IOReportCopyChannelsInGroup(@"CPU Stats",    nil, 0, 0, 0);
        CFMutableDictionaryRef nrg = IOReportCopyChannelsInGroup(@"Energy Model", nil, 0, 0, 0);
        CFMutableDictionaryRef pmp = IOReportCopyChannelsInGroup(@"PMP",          nil, 0, 0, 0);
        if (nrg) { IOReportMergeChannels(chn, nrg, nil); CFRelease(nrg); }
        if (pmp) { IOReportMergeChannels(chn, pmp, nil); CFRelease(pmp); }

        CFMutableDictionaryRef subchn = NULL;
        IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, chn, &subchn, 0, 0);
        if (!sub) { NSLog(@"IOReportCreateSubscription failed — need root?"); return 1; }

        /* Two samples 500 ms apart so delta is non-zero */
        CFDictionaryRef s1 = IOReportCreateSamples(sub, subchn, NULL);
        usleep(500000);
        CFDictionaryRef s2 = IOReportCreateSamples(sub, subchn, NULL);
        CFDictionaryRef delta = IOReportCreateSamplesDelta(s1, s2, NULL);

        NSLog(@"=== our IOReport delta (0.5s) ===");

        IOReportIterate(delta, ^(IOReportSampleRef sample) {
            NSString *subgroup  = IOReportChannelGetSubGroup(sample);
            NSString *group     = IOReportChannelGetGroup(sample);
            NSString *chann_name = IOReportChannelGetChannelName(sample);
            NSString *unit_label = IOReportChannelGetUnitLabel(sample);
            int chann_format = IOReportChannelGetFormat(sample);

            if (chann_format == kIOReportFormatState) {
                long state_count = IOReportStateGetCount(sample);
                for (int i = 0; i < state_count; i++) {
                    NSString *idx_name = IOReportStateGetNameForIndex(sample, i);
                    uint64_t  residency = IOReportStateGetResidency(sample, i);
                    printf("[STATE] grp=%-13s sub=%-34s ch=%-10s state[%d]=%-8s res=%llu\n",
                           group.UTF8String, subgroup.UTF8String,
                           chann_name ? chann_name.UTF8String : "nil",
                           i, idx_name ? idx_name.UTF8String : "NIL", residency);
                }
            } else if (chann_format == kIOReportFormatSimple) {
                long val = IOReportSimpleGetIntegerValue(sample, 0);
                printf("[SIMPLE] grp=%-12s sub=%-34s ch=%-20s val=%ld\n",
                       group.UTF8String, subgroup.UTF8String,
                       chann_name ? chann_name.UTF8String : "nil", val);
            }
            return re_kIOReportIterOk;
        });

        CFRelease(delta); CFRelease(s1); CFRelease(s2);
        CFRelease(subchn); CFRelease(chn);
    }
    return 0;
}
