"""
Extends user attributes
"""

from yoyo import step

__depends__ = {"20190907_01_jfLUH-add-previous-message-column"}

steps = [
    step(
        "ALTER TABLE users ADD COLUMN email TEXT", "ALTER TABLE users DROP COLUMN email"
    ),
    step(
        "ALTER TABLE users ADD COLUMN title TEXT", "ALTER TABLE users DROP COLUMN title"
    ),
    step(
        "ALTER TABLE users ADD COLUMN first_name TEXT",
        "ALTER TABLE users DROP COLUMN first_name",
    ),
    step(
        "ALTER TABLE users ADD COLUMN last_name TEXT",
        "ALTER TABLE users DROP COLUMN last_name",
    ),
    step(
        "ALTER TABLE users ADD COLUMN timezone TEXT",
        "ALTER TABLE users DROP COLUMN timezone",
    ),
    step(
        "ALTER TABLE users ADD COLUMN update_timezone boolean",
        "ALTER TABLE users DROP COLUMN update_timezone",
    ),
    step(
        "ALTER TABLE users ADD COLUMN language TEXT default 'en'",
        "ALTER TABLE users DROP COLUMN language",
    ),
]
