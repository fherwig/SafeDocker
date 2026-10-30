#include "CSandbox.h"
#include <sandbox.h>

// sandbox_init is deprecated but works (tested on macOS 26.3); the app checks
// it with --self-test on every machine.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int safe_deny_network(char **error)
{
    if (error)
        *error = NULL;
    return sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, error);
}

void safe_free_error(char *error)
{
    if (error)
        sandbox_free_error(error);
}

#pragma clang diagnostic pop
