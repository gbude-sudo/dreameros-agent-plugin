"""Release keys embedded by the protected stable build.

Source checkouts and unsigned candidate builds intentionally contain no trusted
stable key. The protected release workflow replaces this mapping before the
standalone binaries are built.
"""

PINNED_RELEASE_KEYS: dict[str, str] = {}
PINNED_LINUX_PACKAGE_PUBLIC_KEY_B64 = ""
