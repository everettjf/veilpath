// Derived from forcequitOS/worse_query, Copyright (C) 2026 Taj C (forcequit).
// SPDX-License-Identifier: GPL-3.0-or-later
// Modified for Veilpath on 2026-11-14: workspace staging is managed in Swift.
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

// Caller must exclusively stage Library/Caches in its own App Group first.
int64_t veilpath_worse_query(NSString *group, bool alternate_flags);
