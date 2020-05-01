import psycopg2
import atexit
import os
import logging


class Database:
    def __init__(self, password):
        self.conn = psycopg2.connect(
            user="postgres", password=password, host="127.0.0.1"
        )
        self.cursor = self.conn.cursor()
        atexit.register(self.cleanup)

    def cleanup(self):
        self.cursor.close()
        self.conn.close()

    def status(self):
        if self.conn.closed:
            return -1, "Connection closed."

        return 0, self.conn.status

    def sql_to_dict(self, query, values={}):
        result = []
        self.cursor.execute(query, values)
        for row in self.cursor.fetchall():

            obj = {}
            names = list(map(lambda x: x[0], self.cursor.description))
            for pair in zip(names, row):
                obj[pair[0]] = pair[1]
            result.append(obj)

        return result

    def insert_user(self, username, password, display_name, state):
        self.cursor.execute(
            """INSERT INTO users (username, password, display_name, state)
            VALUES(%s, %s, %s, %s)""",
            (username, password, display_name, state),
        )
        result = self.cursor.rowcount
        self.conn.commit()
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
        self.conn.commit()
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

        self.cursor.execute(
            """
            UPDATE active_logins
            SET 
              active = 0
            WHERE 
              id = %(session_id)s
            """,
            {"session_id": session_id},
        )
        self.conn.commit()

    def get_users(self):
        return self.sql_to_dict("SELECT * FROM users")

    def get_user(self, username: str):
        result = self.sql_to_dict(
            """
            SELECT * FROM users
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
        self.cursor.execute(
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
        self.conn.commit()

    def set_user_status(self, username, status):
        self.cursor.execute(
            """
            UPDATE users
            SET state = %(status)s
            WHERE username = %(username)s
            """,
            {"username": username, "status": status},
        )
        self.conn.commit()

    def set_user_picture(self, username, picture):
        self.cursor.execute(
            """
            UPDATE users
            SET profile_image = %(picture)s
            WHERE username = %(username)s
            """,
            {"username": username, "picture": picture},
        )
        self.conn.commit()

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
        self.conn.commit()

        return result[0]

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

    def get_daily_message_count(self):
        return self.sql_to_dict(
            """
            select count(*) as "Count", users.display_name as "Username", to_char(date_trunc('day', to_timestamp(m.sent_time)), 'DD/MM/YYYY') as "Date" 
            from messages as m
            INNER JOIN users ON m.sender = users.id 
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
            select channels.*
            from channels
            inner join channels_users on channels.id = channels_users.channel_id
            inner join users on users.id = channels_users.user_id
            where users.username = %(username)s""",
            {"username": username},
        )

    def get_users_for_channel(self, channel_id):
        return self.sql_to_dict(
            """
            select users.username, users.id, users.first_name
            from channels_users
            inner join users on users.id = channels_users.user_id
            where channels_users.channel_id = %(channel_id)s""",
            {"channel_id": channel_id},
        )

    def search(self, query, channel):
        return self.sql_to_dict(
            """
            SELECT * FROM messages  
            WHERE channel=%(channel)s 
              AND messages.message @@ to_tsquery(%(query)s);""",
            {"channel": channel, "query": query},
        )

    def insert_channel(self, name, channel_type):
        result = self.sql_to_dict(
            """INSERT INTO channels (name, type)
            VALUES(%(name)s, %(type)s)
            RETURNING *""",
            {"name": name, "type": channel_type},
        )
        self.conn.commit()

        print(result)
        return result[0]

    def insert_channel_member(self, channel_id, username):
        self.cursor.execute(
            """INSERT INTO channels_users (channel_id, user_id)
            SELECT %(channel_id)s, id
            FROM users
            WHERE username=%(username)s or email=%(username)s
            RETURNING *;""",
            {"channel_id": channel_id, "username": username},
        )
        self.conn.commit()

    def insert_file(self, file_name, username, file_type, size, full_name):
        self.cursor.execute(
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
        self.conn.commit()

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
        self.cursor.execute(
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
        self.conn.commit()

    def delete_emoji(self, file_identifier):
        self.cursor.execute(
            """DELETE
                FROM emojis
                WHERE name=%(name)s""",
            {"name": file_identifier},
        )
        self.conn.commit()

    def delete_all_emoji(self):
        self.cursor.execute("""TRUNCATE emojis""")
        self.conn.commit()

    def get_emojis(self):
        return self.sql_to_dict("SELECT * FROM emojis")

    def get_emoji(self, emoji):
        result = self.sql_to_dict(
            """SELECT file FROM emojis WHERE name = %(emoji)s""", {"emoji": emoji}
        )
        return result[0] if len(result) == 1 else None
