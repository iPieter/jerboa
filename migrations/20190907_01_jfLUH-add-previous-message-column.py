"""
Add previous_message column
"""

from yoyo import step

__depends__ = {'20190829_01_YSiWP-add-primary-keys'}

steps = [
    step("ALTER TABLE messages ADD COLUMN previous_message integer",
        "ALTER TABLE messages DROP column previous_message")
]
