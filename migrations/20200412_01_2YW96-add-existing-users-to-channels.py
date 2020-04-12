"""
add existing users to channels
"""

from yoyo import step

__depends__ = {"20191222_01_xEgbR-add-channels"}

steps = [
    step("INSERT INTO channels (id, name, type) VALUES(1, 'General', 'DEFAULT')"),
    step(
        """
insert into channels_users (channel_id, user_id, joined)
select 1, users.id, (SELECT extract(epoch from now() at time zone 'utc'))
from users """
    ),
]
