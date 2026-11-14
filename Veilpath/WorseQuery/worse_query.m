/*
 * Derived from forcequitOS/worse_query, Copyright (C) 2026 Taj C (forcequit).
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3, or any later version.
 * This program is distributed WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See LICENSE.txt for the full GNU General Public License.
 *
 * Modified for Veilpath on 2026-11-14: the caller preserves and restores the
 * App Group workspace, including interrupted requests; this bridge never
 * deletes a directory. Error codes are private to this backend.
 */
#import "worse_query.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <xpc/xpc.h>

int64_t veilpath_worse_query(NSString *group, bool alternate_flags) {
    void *manager = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!manager) return -1002;
    void *(*create)(void) = dlsym(manager, "container_query_create");
    void (*set_class)(void *, uint64_t) = dlsym(manager, "container_query_set_class");
    void (*set_identifiers)(void *, xpc_object_t) = dlsym(manager, "container_query_set_group_identifiers");
    void (*set_flags)(void *, uint64_t) = dlsym(manager, "container_query_operation_set_flags");
    void (*set_part)(void *, uint64_t) = dlsym(manager, "container_query_operation_set_part");
    void *(*get_result)(void *) = dlsym(manager, "container_query_get_single_result");
    void (*free_query)(void *) = dlsym(manager, "container_query_free");
    char *(*copy_token)(void *) = dlsym(manager, "container_copy_sandbox_token");
    int64_t (*consume)(const char *) = dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!create || !set_class || !set_identifiers || !set_flags || !set_part ||
        !get_result || !free_query || !copy_token || !consume) {
        dlclose(manager);
        return -1002;
    }
    void *query = create();
    if (!query) { dlclose(manager); return -1003; }
    xpc_object_t identifier = xpc_string_create(group.UTF8String);
    int64_t handle = -1007;
    if (identifier) {
        set_class(query, 7);
        set_identifiers(query, identifier);
        set_part(query, 3);
        set_flags(query, alternate_flags ? 0x0000000800000000ULL : 0x0000008000000000ULL);
        void *result = get_result(query);
        handle = -1005;
        if (result) {
            char *token = copy_token(result);
            handle = -1006;
            if (token) { handle = consume(token); free(token); }
        }
        // XPC objects are managed by ARC in this Objective-C translation unit.
#if !__has_feature(objc_arc)
        xpc_release(identifier);
#endif
    }
    free_query(query);
    dlclose(manager);
    return handle;
}
