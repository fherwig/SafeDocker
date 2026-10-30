#ifndef CSANDBOX_H
#define CSANDBOX_H

// Deny this process all network access for the rest of its life, with
// sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, error). Returns 0 on
// success; on failure returns -1 and sets *error to a message that the caller
// frees with safe_free_error.
int safe_deny_network(char **error);

// Free a message returned by safe_deny_network. NULL is allowed.
void safe_free_error(char *error);

#endif
