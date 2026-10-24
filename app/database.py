import psycopg2
import psycopg2.pool
import atexit
import os
import logging
from contextlib import contextmanager


logger = logging.getLogger(__name__)

# Columns of `users` that any logged-in user may see about any other user.
PUBLIC_USER_COLUMNS = (
    "id",
    "username",
    "display_name",
    "first_name",
    "last_name",
    "profile_image",
    "state",
    "title",
)

# Columns a user may see about themselves: everything except the password hash.
SELF_USER_COLUMNS = PUBLIC_USER_COLUMNS + (
    "email",
    "timezone",
    "update_timezone",
    "language",
)


def connection_kwargs(password, environ=None):
    """Builds the psycopg2 connection arguments.

    `db_user` (default "postgres"), `db_host` (default "127.0.0.1") and
    `db_name` (default: unset, so libpq picks its default database) are read
    from the environment. With none of them set this is exactly what the app
    has always used.
    """
    if environ is None:
        environ = os.environ
    kwargs = {
        "user": environ.get("db_user") or "postgres",
        "password": password,
        "host": environ.get("db_host") or "127.0.0.1",
    }
    if environ.get("db_name"):
        kwargs["dbname"] = environ["db_name"]
    return kwargs


class Database:
    def __init__(self, password, minconn=1, maxconn=10):
        self.pool = psycopg2.pool.ThreadedConnectionPool(
            minconn, maxconn, **connection_kwargs(password)
        )
        atexit.register(self.cleanup)

    def cleanup(self):
        try:
            self.pool.closeall()
        except psycopg2.pool.PoolError:
            pass

    @contextmanager
    def cursor(self):
        """Yields a fresh cursor on a pooled connection.

        The transaction is committed when the block succeeds and rolled back
        when it raises, so one failing statement can't leave the connection
        stuck in an aborted transaction. Broken connections (server restart,
        network drop) are discarded so the next call reconnects.
        """
        conn = self.pool.getconn()
        broken = False
        try:
            with conn.cursor() as cur:
                yield cur
            conn.commit()
        except (psycopg2.OperationalError, psycopg2.InterfaceError):
            broken = True
            raise
        except Exception:
            try:
                conn.rollback()
            except (psycopg2.OperationalError, psycopg2.InterfaceError):
                broken = True
            raise
        finally:
            self.pool.putconn(conn, close=broken or bool(conn.closed))

    def status(self):
        try:
            with self.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        except psycopg2.Error as e:
            return -1, "Connection error: {}".format(type(e).__name__)
        return 0, 1

    def execute(self, query, values=None):
        """Runs a statement and returns its rowcount."""
        with self.cursor() as cur:
            cur.execute(query, values if values is not None else {})
            return cur.rowcount

    def sql_to_dict(self, query, values=None):
        with self.cursor() as cur:
            cur.execute(query, values if values is not None else {})
            if cur.description is None:
                return []
            names = [column[0] for column in cur.description]
            return [dict(zip(names, row)) for row in cur.fetchall()]

    def insert_user(self, username, password, display_name, state):
        try:
            result = self.execute(
                """INSERT INTO users (username, password, display_name, state)
                VALUES(%s, %s, %s, %s)""",
                (username, password, display_name, state),
            )
        except psycopg2.IntegrityError:
            return False
        return result == 1

    def insert_session(self, username, last_seen, device, client, expires):

        result = self.sql_to_dict(
            """INSERT INTO active_logins (last_seen, active, device, client, expires, user_id)
            SELECT %(last_seen)s, %(active)s, %(device)s, %(client)s, %(expires)s, id
            FROM users
            WHERE username=%(username)s
            RETURNING id""",
            {
                "last_seen": last_seen,
                "active": "1",
                "device": device,
                "client": client,
                "expires": expires,
                "username": username,
            },
        )
        return result[0]

    def get_sessions(self, username):
        result = self.sql_to_dict(
            """
            select *
            from active_logins
            where active = 1 AND user_id = (select id from users where username = %(username)s)""",
            {"username": username},
        )
        return result

    def get_session(self, session_id):
        """Returns one session if it can be found based on a session id, `None` otherwise."""

        result = self.sql_to_dict(
            """
            select *
            from active_logins
            where
              id = %(session_id)s
            """,
            {"session_id": session_id},
        )
        return result[0] if len(result) == 1 else None

    def disable_session(self, session_id):

        self.execute(
            """
            UPDATE active_logins
            SET
              active = 0
            WHERE
              id = %(session_id)s
            """,
            {"session_id": session_id},
        )

    def get_users(self):
        """All users, without private columns."""
        return self.sql_to_dict(
            "SELECT {} FROM users ORDER BY id".format(", ".join(PUBLIC_USER_COLUMNS))
        )

    def get_public_user(self, username: str):
        """One user as other users may see them, or `None`."""
        result = self.sql_to_dict(
            "SELECT {} FROM users WHERE username = %(username)s".format(
                ", ".join(PUBLIC_USER_COLUMNS)
            ),
            {"username": username},
        )
        return result[0] if len(result) == 1 else None

    def get_user(self, username: str):
        """One user with every column except the password hash, or `None`."""
        result = self.sql_to_dict(
            "SELECT {} FROM users WHERE username = %(username)s".format(
                ", ".join(SELF_USER_COLUMNS)
            ),
            {"username": username},
        )
        return result[0] if len(result) == 1 else None

    def get_user_credentials(self, username: str):
        """`id`, `username`, `state` and the password hash, for logging in only."""
        result = self.sql_to_dict(
            """
            SELECT id, username, state, password FROM users
            WHERE username = %(username)s""",
            {"username": username},
        )
        return result[0] if len(result) == 1 else None

    def update_user(self, user):
        """
        Updates the user record based on the field `username` in the user object.

        The following fields are set:
        - `title`
        - `first_name`
        - `last_name`
        - `email`
        - `language`
        """
        self.execute(
            """
            UPDATE users
            SET
              title = %(title)s,
              first_name = %(first_name)s,
              last_name = %(last_name)s,
              email = %(email)s,
              language = %(language)s
            WHERE
              username = %(username)s
            """,
            user,
        )

    def set_user_status(self, username, status):
        return self.execute(
            """
            UPDATE users
            SET state = %(status)s
            WHERE username = %(username)s
            """,
            {"username": username, "status": status},
        )

    def set_user_picture(self, username, picture):
        self.execute(
            """
            UPDATE users
            SET profile_image = %(picture)s
            WHERE username = %(username)s
            """,
            {"username": username, "picture": picture},
        )

    def insert_message(
        self, username, channel, message, message_type, sent_time, previous_message=None
    ):
        result = self.sql_to_dict(
            """
            INSERT INTO messages(sender, channel, message, sent_time, message_type,
            previous_message)
            SELECT id, %(channel)s, %(message)s, %(sent_time)s, %(message_type)s, %(previous_message)s
            FROM users
            WHERE username=%(username)s
            RETURNING *, %(username)s;
        """,
            {
                "username": username,
                "channel": channel,
                "message": message,
                "sent_time": sent_time,
                "message_type": message_type,
                "previous_message": previous_message,
            },
        )

        return result[0] if result else None

    def get_messages(self, channel, message_id=0):
        query = """SELECT messages.*, username from messages
                   INNER JOIN users ON messages.sender = users.id
                   WHERE channel=%(channel)s
                   {}
                   ORDER BY messages.id DESC
                   LIMIT 30
                """.format(
            "" if message_id == 0 else "AND messages.id < %(msg_id)s"
        )
        return self.sql_to_dict(query, {"channel": channel, "msg_id": message_id})

    def get_message(self, msg_id):
        result = self.sql_to_dict(
            """
            SELECT * FROM messages
            WHERE id=%(msg_id)s""",
            {"msg_id": msg_id},
        )
        return result[0] if len(result) == 1 else None

    def get_message_with_sender(self, msg_id):
        """A message joined with its sender's username, or `None`."""
        result = self.sql_to_dict(
            """
            SELECT messages.*, users.username FROM messages
            INNER JOIN users ON messages.sender = users.id
            WHERE messages.id = %(msg_id)s""",
            {"msg_id": msg_id},
        )
        return result[0] if len(result) == 1 else None

    def get_latest_edit(self, msg_id, sender_id):
        """The newest edit of a message by its own author, or `None`."""
        result = self.sql_to_dict(
            """
            SELECT messages.*, users.username FROM messages
            INNER JOIN users ON messages.sender = users.id
            WHERE messages.previous_message = %(msg_id)s
              AND messages.message_type = 'TEXT_MESSAGE_UPDATE'
              AND messages.sender = %(sender_id)s
            ORDER BY messages.id DESC
            LIMIT 1""",
            {"msg_id": msg_id, "sender_id": sender_id},
        )
        return result[0] if result else None

    def get_daily_message_count(self):
        return self.sql_to_dict(
            """
            select count(*) as "Count", users.display_name as "Username", to_char(date_trunc('day', to_timestamp(m.sent_time)), 'DD/MM/YYYY') as "Date"
            from messages as m
            INNER JOIN users ON m.sender = users.id
            where date_trunc('day', to_timestamp(m.sent_time)) >  CURRENT_DATE - INTERVAL '1 month'
            group by users.display_name, date_trunc('day', to_timestamp(m.sent_time))
            order by date_trunc('day', to_timestamp(m.sent_time))"""
        )

    def get_channel_count(self):
        return self.sql_to_dict(
            """
            SELECT channels.name, count(*) FROM messages
            join channels on cast(channels.id as text) = messages.channel
            GROUP BY channels.name
            order by count(*) DESC"""
        )

    def get_channels(self, username):
        return self.sql_to_dict(
            """
            select distinct channels.*
            from channels
            inner join channels_users on channels.id = channels_users.channel_id
            inner join users on users.id = channels_users.user_id
            where users.username = %(username)s
            order by channels.id""",
            {"username": username},
        )

    def get_channel(self, channel_id):
        result = self.sql_to_dict(
            "SELECT * FROM channels WHERE id = %(channel_id)s",
            {"channel_id": channel_id},
        )
        return result[0] if len(result) == 1 else None

    def is_channel_member(self, channel_id, username):
        result = self.sql_to_dict(
            """
            SELECT 1 FROM channels_users
            INNER JOIN users ON users.id = channels_users.user_id
            WHERE channels_users.channel_id = %(channel_id)s
              AND users.username = %(username)s
            LIMIT 1""",
            {"channel_id": channel_id, "username": username},
        )
        return len(result) > 0

    def get_users_for_channel(self, channel_id):
        return self.sql_to_dict(
            """
            select distinct users.username, users.id, users.first_name
            from channels_users
            inner join users on users.id = channels_users.user_id
            where channels_users.channel_id = %(channel_id)s""",
            {"channel_id": channel_id},
        )

    def search(self, query, channel):
        """Full-text search in one channel.

        `websearch_to_tsquery` (PostgreSQL 11+) accepts free-form user input,
        so stray spaces or punctuation can't cause a syntax error.
        """
        return self.sql_to_dict(
            """
            SELECT * FROM messages
            WHERE channel=%(channel)s
              AND messages.message @@ websearch_to_tsquery(%(query)s);""",
            {"channel": channel, "query": query},
        )

    def insert_channel(self, name, channel_type):
        result = self.sql_to_dict(
            """INSERT INTO channels (name, type)
            VALUES(%(name)s, %(type)s)
            RETURNING *""",
            {"name": name, "type": channel_type},
        )
        return result[0]

    def insert_channel_member(self, channel_id, username):
        """Adds a user (matched on username) to a channel, once."""
        return self.execute(
            """INSERT INTO channels_users (channel_id, user_id)
            SELECT %(channel_id)s, id
            FROM users
            WHERE username=%(username)s
              AND NOT EXISTS (
                SELECT 1 FROM channels_users
                WHERE channel_id = %(channel_id)s AND user_id = users.id
              );""",
            {"channel_id": channel_id, "username": username},
        )

    def insert_file(self, file_name, username, file_type, size, full_name):
        self.execute(
            """INSERT INTO files (file, user_id, type, size, full_name)
            SELECT %(file)s, id, %(type)s, %(size)s, %(full_name)s
            FROM users
            WHERE username=%(username)s""",
            {
                "username": username,
                "file": file_name,
                "type": file_type,
                "size": size,
                "full_name": full_name,
            },
        )

    def get_file(self, file_identifier):
        result = self.sql_to_dict(
            """SELECT * FROM files WHERE file = %(f)s""", {"f": file_identifier}
        )
        return result[0] if len(result) == 1 else None

    def get_file_count(self):
        return self.sql_to_dict(
            """
                    SELECT type, COUNT(*), SUM(size) FROM files GROUP BY type
               """
        )

    def insert_emoji(self, username, name, file_name, date_added):
        self.execute(
            """INSERT INTO emojis (name, file, user_id, added)
                SELECT %(name)s, %(file)s, id, %(added)s
                FROM users
                WHERE username=%(username)s""",
            {
                "username": username,
                "name": name,
                "file": file_name,
                "added": date_added,
            },
        )

    def delete_emoji(self, file_identifier):
        self.execute(
            """DELETE
                FROM emojis
                WHERE name=%(name)s""",
            {"name": file_identifier},
        )

    def delete_all_emoji(self):
        self.execute("""TRUNCATE emojis""")

    def get_emojis(self):
        return self.sql_to_dict("SELECT * FROM emojis")

    def get_emoji(self, emoji):
        result = self.sql_to_dict(
            """SELECT file FROM emojis WHERE name = %(emoji)s""", {"emoji": emoji}
        )
        return result[0] if len(result) == 1 else None

    def get_emoji_owners(self, name):
        """User ids that uploaded an emoji with this name."""
        return [
            row["user_id"]
            for row in self.sql_to_dict(
                "SELECT user_id FROM emojis WHERE name = %(name)s", {"name": name}
            )
        ]
