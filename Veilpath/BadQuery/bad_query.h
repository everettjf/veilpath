#ifndef VEILPATH_BAD_QUERY_H
#define VEILPATH_BAD_QUERY_H

#include <stdbool.h>
#include <stdint.h>

/// Returns a non-negative sandbox extension handle on success.
int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group);

/// Returns a malloc-owned newline-delimited string. The caller must free it.
char *bad_query_list(char *path, int64_t max_inode);

void bad_query_release(int64_t handle);

#endif
