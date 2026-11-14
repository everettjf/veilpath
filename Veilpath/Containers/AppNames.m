#import "AppNames.h"
#import <objc/message.h>
#include <dlfcn.h>

// Query only known bundle identifiers. Availability and authorization vary by
// OS; failure leaves the exact bundle identifier visible in the browser.
NSDictionary<NSString *, NSString *> *veilpath_application_names(NSArray<NSString *> *identifiers) {
    void *framework = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY | RTLD_LOCAL);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    NSMutableDictionary *names = [NSMutableDictionary dictionary];
    if ([proxyClass respondsToSelector:lookup]) {
        for (NSString *identifier in identifiers) {
            @try {
                id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, lookup, identifier);
                SEL nameSelector = NSSelectorFromString(@"localizedName");
                SEL identifierSelector = NSSelectorFromString(@"bundleIdentifier");
                if (![proxy respondsToSelector:nameSelector] || ![proxy respondsToSelector:identifierSelector]) continue;
                NSString *actual = ((id (*)(id, SEL))objc_msgSend)(proxy, identifierSelector);
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, nameSelector);
                if ([actual isEqualToString:identifier] && [name isKindOfClass:NSString.class] && name.length && ![name isEqualToString:identifier]) {
                    names[identifier] = name;
                }
            } @catch (NSException *exception) {
                // Private LaunchServices implementations may reject the caller.
            }
        }
    }
    if (framework) dlclose(framework);
    return names;
}
