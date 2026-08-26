#pragma once

#include <Security/Security.h>

/// Thin wrappers around deprecated login-keychain ACL APIs.
/// Data-protection keychain uses SecAccessControl; we only need these after -34018
/// when falling back to the file-based login keychain for ad-hoc SPM binaries.

SecTrustedApplicationRef SATrustedApplicationCreate(const char *path);
SecAccessRef SAAccessCreate(CFStringRef descriptor, CFArrayRef trustedList);
