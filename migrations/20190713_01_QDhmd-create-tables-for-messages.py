"""
messages, login, users
"""

from yoyo import step

__depends__ = {}

steps = [
    step("""
            CREATE TABLE users(
                id SERIAL,
                username  TEXT NOT NULL UNIQUE,
                password  TEXT NOT NULL,
                display_name  TEXT,
                profile_image TEXT DEFAULT 'default.png',
                state TEXT
            );
          """,
         "DROP TABLE users"),
    step("""
           CREATE TABLE active_logins (
                id    SERIAL,
                queue TEXT UNIQUE,
                last_seen NUMERIC,
                active    INTEGER,
                device    TEXT,
                device_type   TEXT,
                expires   NUMERIC,
                user_id   INTEGER
           );
         """,
         "DROP TABLE active_logins"),
    step("""
            CREATE TABLE messages (
                id    SERIAL,
                sender    INTEGER,
                channel   TEXT,
                message   TEXT,
                message_type   TEXT,
                sent_time NUMERIC
            );
         """, 
         "DROP TABLE messages"),
    step("""
            CREATE TABLE files (
                id    SERIAL,
                file  TEXT,
                user_id   INTEGER,
                type  TEXT,
                size  INTEGER,
                full_name TEXT
            );
         """,
         "DROP TABLE files"),
    step("""
            CREATE TABLE emojis (
                id  SERIAL,
                name    TEXT,
                added    NUMERIC,
                user_id    INTEGER,
                file    TEXT
        );
        """,
        "DROP TABLE emojis"),
]
