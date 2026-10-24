#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "CrashSupport.h"

char *hs_try_objc(void (^block)(void)) {
    @try {
        block();
        return NULL;
    } @catch (NSException *e) {
        NSString *s = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
        return strdup(s.UTF8String ?: "Objective-C exception");
    } @catch (id other) {
        return strdup("Objective-C exception of unknown type");
    }
}
