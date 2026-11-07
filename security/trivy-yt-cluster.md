# Trivy: YT Cluster

The nightly's scan (yt-cluster-tests nightly/nightly.sh, `security_report`), run 20261107-122434, 2026-11-07 17:14 UTC:
Trivy 0.69.3 on YT Cluster's crates - the lock file of the source the run tested - and on the
image `dbinvent/yt:latest` as Docker Hub serves it: every known vulnerability counted by severity, the CRITICAL
and HIGH ones listed.

Software bills of materials, CycloneDX: [sbom-yt-cluster.cdx.json](sbom-yt-cluster.cdx.json) (the crates),
[sbom-yt-cluster-image.cdx.json](sbom-yt-cluster-image.cdx.json) (the image).

## The crates

```text

Report Summary

┌────────────┬───────┬─────────────────┐
│   Target   │ Type  │ Vulnerabilities │
├────────────┼───────┼─────────────────┤
│ Cargo.lock │ cargo │        1        │
└────────────┴───────┴─────────────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)

Report Summary

┌────────────┬───────┬─────────────────┐
│   Target   │ Type  │ Vulnerabilities │
├────────────┼───────┼─────────────────┤
│ Cargo.lock │ cargo │        0        │
└────────────┴───────┴─────────────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)
```

## The image `dbinvent/yt:latest`

```text

Report Summary

┌──────────────────────────────────┬──────────┬─────────────────┐
│              Target              │   Type   │ Vulnerabilities │
├──────────────────────────────────┼──────────┼─────────────────┤
│ dbinvent/yt:latest (debian 13.7) │  debian  │       890       │
├──────────────────────────────────┼──────────┼─────────────────┤
│ usr/local/bin/gosu               │ gobinary │        0        │
└──────────────────────────────────┴──────────┴─────────────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)

Report Summary

┌──────────────────────────────────┬──────────┬─────────────────┐
│              Target              │   Type   │ Vulnerabilities │
├──────────────────────────────────┼──────────┼─────────────────┤
│ dbinvent/yt:latest (debian 13.7) │  debian  │       60        │
├──────────────────────────────────┼──────────┼─────────────────┤
│ usr/local/bin/gosu               │ gobinary │        0        │
└──────────────────────────────────┴──────────┴─────────────────┘
Legend:
- '-': Not scanned
- '0': Clean (no security findings detected)


dbinvent/yt:latest (debian 13.7)
================================
Total: 60 (HIGH: 59, CRITICAL: 1)

┌───────────────────┬─────────────────┬──────────┬──────────────┬──────────────────────────────────────┬───────────────┬──────────────────────────────────────────────────────────────┐
│      Library      │  Vulnerability  │ Severity │    Status    │          Installed Version           │ Fixed Version │                            Title                             │
├───────────────────┼─────────────────┼──────────┼──────────────┼──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ bsdutils          │ CVE-2026-76642  │ HIGH     │ affected     │ 1:2.41.5-0+deb13u1                   │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libacl1           │ CVE-2026-54369  │          │              │ 2.3.2-2+b1                           │               │ acl: Symlink traversal privilege escalation via libacl       │
│                   │                 │          │              │                                      │               │ functions                                                    │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-54369                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libblkid1         │ CVE-2026-76642  │          │              │ 2.41.5-0+deb13u1                     │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libcurl4t64       │ CVE-2026-12064  │          │              │ 8.14.1-2+deb13u7                     │               │ curl: curl: SSH host verification bypass when using          │
│                   │                 │          │              │                                      │               │ schemeless URLs with SFTP/SCP...                             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-12064                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-8458   │          │              │                                      │               │ curl: libcurl: Unauthorized connection reuse due to a        │
│                   │                 │          │              │                                      │               │ logical error                                                │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-8458                    │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ liblastlog2-2     │ CVE-2026-76642  │          │              │ 2.41.5-0+deb13u1                     │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│ libmount1         │ CVE-2026-76642  │          │              │                                      │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libncursesw6      │ CVE-2025-69720  │          │              │ 6.5+20250216-2                       │               │ ncurses: ncurses: Buffer overflow vulnerability may lead to  │
│                   │                 │          │              │                                      │               │ arbitrary code execution.                                    │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2025-69720                   │
├───────────────────┼─────────────────┤          ├──────────────┼──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libperl5.40       │ CVE-2026-9538   │          │ fix_deferred │ 5.40.1-6+deb13u1                     │               │ perl-Archive-Tar: perl-Archive-Tar: Denial of Service via    │
│                   │                 │          │              │                                      │               │ crafted tar header with large entry...                       │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-9538                    │
├───────────────────┼─────────────────┤          ├──────────────┼──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libsmartcols1     │ CVE-2026-76642  │          │ affected     │ 2.41.5-0+deb13u1                     │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libsqlite3-0      │ CVE-2026-119373 │          │              │ 3.46.1-7+deb13u2                     │               │ sqlite: sqlite: Denial of service via heap-based buffer      │
│                   │                 │          │              │                                      │               │ overflow in FTS5                                             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-119373                  │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-119374 │          │              │                                      │               │ sqlite: sqlite: Arbitrary code execution via corrupted FTS5  │
│                   │                 │          │              │                                      │               │ index                                                        │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-119374                  │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-119379 │          │              │                                      │               │ sqlite: sqlite: Arbitrary code execution via crafted session │
│                   │                 │          │              │                                      │               │ changesets                                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-119379                  │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libsystemd0       │ CVE-2026-16742  │          │              │ 257.13-1~deb13u1                     │               │ systemd: systemd-homed: Local privilege escalation via       │
│                   │                 │          │              │                                      │               │ missing home-record signature verification                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-16742                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libtinfo6         │ CVE-2025-69720  │          │              │ 6.5+20250216-2                       │               │ ncurses: ncurses: Buffer overflow vulnerability may lead to  │
│                   │                 │          │              │                                      │               │ arbitrary code execution.                                    │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2025-69720                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libudev1          │ CVE-2026-16742  │          │              │ 257.13-1~deb13u1                     │               │ systemd: systemd-homed: Local privilege escalation via       │
│                   │                 │          │              │                                      │               │ missing home-record signature verification                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-16742                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libuuid1          │ CVE-2026-76642  │          │              │ 2.41.5-0+deb13u1                     │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┼──────────┤              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ libxml2           │ CVE-2026-6653   │ CRITICAL │              │ 2.12.7+dfsg+really2.9.14-2.1+deb13u3 │               │ libxml2: mingw-libxml2: libxml2: Denial of Service via       │
│                   │                 │          │              │                                      │               │ crafted XML input due to...                                  │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-6653                    │
│                   ├─────────────────┼──────────┤              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-74860  │ HIGH     │              │                                      │               │ libxml2: double-free/UAF in libxml2 Python bindings          │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-74860                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-86138  │          │              │                                      │               │ libxml2: libxml2: Arbitrary code execution via heap-based    │
│                   │                 │          │              │                                      │               │ buffer overflow                                              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-86138                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-86139  │          │              │                                      │               │ libxml2: libxml2: Integer overflow in xmlURIEscapeStr may    │
│                   │                 │          │              │                                      │               │ lead to arbitrary code execution...                          │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-86139                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-86140  │          │              │                                      │               │ libxml2: libxml2: Arbitrary code execution via stack-based   │
│                   │                 │          │              │                                      │               │ buffer overflow in xmlSnprintfElements                       │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-86140                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-86142  │          │              │                                      │               │ libxml2: libxml2: Heap-based buffer overflow in xmlXPtrEval  │
│                   │                 │          │              │                                      │               │ due to xpointer length saturation...                         │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-86142                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-86143  │          │              │                                      │               │ libxml2: libxml2: Data integrity issues due to integer       │
│                   │                 │          │              │                                      │               │ overflow in write callbacks...                               │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-86143                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-86144  │          │              │                                      │               │ libxml2: libxml2: Information disclosure, SSRF, or denial of │
│                   │                 │          │              │                                      │               │ service due to improper...                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-86144                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ login             │ CVE-2026-76642  │          │              │ 1:4.16.0-2+really2.41.5-0+deb13u1    │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ mount             │ CVE-2026-76642  │          │              │ 2.41.5-0+deb13u1                     │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
├───────────────────┼─────────────────┤          │              ├──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ ncurses-base      │ CVE-2025-69720  │          │              │ 6.5+20250216-2                       │               │ ncurses: ncurses: Buffer overflow vulnerability may lead to  │
│                   │                 │          │              │                                      │               │ arbitrary code execution.                                    │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2025-69720                   │
├───────────────────┤                 │          │              │                                      ├───────────────┤                                                              │
│ ncurses-bin       │                 │          │              │                                      │               │                                                              │
│                   │                 │          │              │                                      │               │                                                              │
│                   │                 │          │              │                                      │               │                                                              │
├───────────────────┼─────────────────┤          ├──────────────┼──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ perl              │ CVE-2026-9538   │          │ fix_deferred │ 5.40.1-6+deb13u1                     │               │ perl-Archive-Tar: perl-Archive-Tar: Denial of Service via    │
│                   │                 │          │              │                                      │               │ crafted tar header with large entry...                       │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-9538                    │
├───────────────────┤                 │          │              │                                      ├───────────────┤                                                              │
│ perl-base         │                 │          │              │                                      │               │                                                              │
│                   │                 │          │              │                                      │               │                                                              │
│                   │                 │          │              │                                      │               │                                                              │
├───────────────────┤                 │          │              │                                      ├───────────────┤                                                              │
│ perl-modules-5.40 │                 │          │              │                                      │               │                                                              │
│                   │                 │          │              │                                      │               │                                                              │
│                   │                 │          │              │                                      │               │                                                              │
├───────────────────┼─────────────────┤          ├──────────────┼──────────────────────────────────────┼───────────────┼──────────────────────────────────────────────────────────────┤
│ util-linux        │ CVE-2026-76642  │          │ affected     │ 2.41.5-0+deb13u1                     │               │ util-linux: util-linux: failed external mount helper still   │
│                   │                 │          │              │                                      │               │ runs privileged X-mount post-hooks                           │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-76642                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78408  │          │              │                                      │               │ util-linux: util-linux: nsenter --join-cgroup leaks root     │
│                   │                 │          │              │                                      │               │ cgroup migration authority                                   │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78408                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78409  │          │              │                                      │               │ util-linux: util-linux: X-mount.subdir detached-tree         │
│                   │                 │          │              │                                      │               │ resolution can escape via intermediate symlinks              │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78409                   │
│                   ├─────────────────┤          │              │                                      ├───────────────┼──────────────────────────────────────────────────────────────┤
│                   │ CVE-2026-78410  │          │              │                                      │               │ util-linux: util-linux: restricted bind mounts do not pin    │
│                   │                 │          │              │                                      │               │ the source, allowing X-mount.owner/group/mode...             │
│                   │                 │          │              │                                      │               │ https://avd.aquasec.com/nvd/cve-2026-78410                   │
└───────────────────┴─────────────────┴──────────┴──────────────┴──────────────────────────────────────┴───────────────┴──────────────────────────────────────────────────────────────┘
```
