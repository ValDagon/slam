#include "KeychainACL.h"

SecTrustedApplicationRef SATrustedApplicationCreate(const char *path) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SecTrustedApplicationRef app = NULL;
    OSStatus status = SecTrustedApplicationCreateFromPath(path, &app);
#pragma clang diagnostic pop
    if (status != errSecSuccess) {
        return NULL;
    }
    return app;
}

SecAccessRef SAAccessCreate(CFStringRef descriptor, CFArrayRef trustedList) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SecAccessRef access = NULL;
    OSStatus status = SecAccessCreate(descriptor, trustedList, &access);
#pragma clang diagnostic pop
    if (status != errSecSuccess) {
        return NULL;
    }
    return access;
}
