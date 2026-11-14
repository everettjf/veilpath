# Veilpath licensing boundary

Veilpath is publicly readable for security research, review, and collaboration, but the repository does **not currently provide one open-source license covering the complete work**.

## Derived boundary

The following files are derived from the upstream [`forcequitOS/bad_query`](https://github.com/forcequitOS/bad_query) proof of concept:

- `Veilpath/BadQuery/bad_query.c`
- `Veilpath/BadQuery/bad_query.h`

The upstream repository did not declare a license when this notice was written. Public source availability alone does not grant permission to redistribute, modify, or relicense derived code. These two files therefore remain outside any future license applied only to Veilpath's original code unless the upstream author grants permission or publishes compatible terms.

## worse_query boundary

`Veilpath/WorseQuery/worse_query.m` and `worse_query.h` are derived from
[`forcequitOS/worse_query`](https://github.com/forcequitOS/worse_query),
Copyright (C) 2026 Taj C (forcequit), under **GPL-3.0-or-later**.
The upstream license is retained in `Veilpath/WorseQuery/LICENSE.txt`.
Veilpath modifications dated 2026-11-14 move workspace preservation and recovery
into Swift and retain the upstream container-query technique. These explicit
terms do not resolve the separate, undeclared bad_query licensing boundary.
Before distributing a combined build, resolve that boundary and ensure the
complete distribution and corresponding source satisfy the GPL terms.

## Original Veilpath code

The remaining original Veilpath code has not yet been assigned a separate license. Until an explicit license file is added, no open-source license grant should be inferred for it either.

## Required steps before an open-source release

1. Ask the upstream author to add a license or grant written permission covering use, modification, and redistribution of `bad_query` in Veilpath.
2. Record the grant or upstream license in this repository and preserve its required copyright and attribution notices.
3. Choose and add an explicit license for Veilpath's original code.
4. Update `README.md`, `README.zh-CN.md`, repository metadata, badges, and the project site so they describe the same licensing state.
5. Review third-party assets and dependencies separately; do not treat an upstream grant for `bad_query` as permission for unrelated material.

## Upstream clarification request

The following concise request can be used when contacting the upstream author:

> Veilpath derives `bad_query.c` and `bad_query.h` from forcequitOS/bad_query. Would you be willing to add an open-source license to the upstream repository, or grant written permission for Veilpath to use, modify, and redistribute those files under compatible terms with attribution? We will preserve your copyright and any required notices.

Until these steps are complete, describe Veilpath as **source-available security research**, not as a fully open-source release.
