"""
Add channels
"""

from yoyo import step

__depends__ = {"20191005_01_4OFBC-session-login-and-device-metadata"}

steps = [
    step(
        """
            CREATE TABLE channels(
                id SERIAL,
                name  TEXT NOT NULL UNIQUE,
                type TEXT
            );
          """,
        "DROP TABLE channels",
    ),
    step(
        """
            CREATE TABLE channels_users(
                id SERIAL,
                channel_id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                joined NUMERIC
            );
          """,
        "DROP TABLE channels_users",
    ),
    step(
        "ALTER TABLE channels_users ADD PRIMARY KEY (id)",
        "ALTER TABLE channels_users DROP CONSTRAINT channels_users_pkey",
    ),
    step(
        "ALTER TABLE channels ADD PRIMARY KEY (id)",
        "ALTER TABLE channels DROP CONSTRAINT channels_pkey",
    ),
]
