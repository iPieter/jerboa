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
        query = """SELECT messages.*, display_name from messages 
                   INNER JOIN users ON messages.sender = users.id 
                   WHERE channel=%(channel)s 
                   AND messages.id > %(msg_id)s
                   ORDER BY messages.id DESC 
                   LIMIT 30 
                """
        return self.sql_to_dict(query, {"channel": channel, "msg_id": message_id})

    def get_message(self, msg_id):
        result = self.sql_to_dict(
            """
            SELECT * FROM messages 
            WHERE id=%(msg_id)s""",
            {"msg_id": msg_id},
        )
        return result[0] if len(result) == 1 else None

    def get_channel_count(self):
        return self.sql_to_dict(
            """
            SELECT channel, count(*) FROM messages GROUP BY channel"""
        )

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
        return len(
            self.sql_to_dict(
                """
                    SELECT type, COUNT(*), SUM(size) FROM files GROUP BY type
               """
            )
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

    def get_emojis(self):
        return self.sql_to_dict("SELECT * FROM emojis")

    def get_emoji(self, emoji):
        result = self.sql_to_dict(
            """SELECT file FROM emojis WHERE name = %(emoji)s""", {"emoji": emoji}
        )
        return result[0] if len(result) == 1 else None
