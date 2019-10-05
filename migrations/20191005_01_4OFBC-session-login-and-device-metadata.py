"""
session login and device metadata
"""

from yoyo import step

__depends__ = {"20190928_01_UbRYL-extends-user-attributes"}

steps = [
    step(
        "ALTER TABLE active_logins DROP COLUMN queue",
        "ALTER TABLE active_logins ADD COLUMN queue TEXT UNIQUE",
    ),
    step(
        "ALTER TABLE active_logins DROP COLUMN device_type",
        "ALTER TABLE active_logins ADD COLUMN device_type TEXT",
    ),
    step(
        "ALTER TABLE active_logins ADD COLUMN client TEXT",
        "ALTER TABLE active_logins DROP COLUMN client",
    ),
]
