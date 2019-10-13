from app.database import Database
import logging

logging.basicConfig(level=logging.DEBUG, filename="tests.log")


class TestDatabase:
    def setup(self):
        self.db = Database("testpasswd")

    def test_add_user(self):
        self.db.insert_user("test_user", "test123", "test", "ADMIN")
        user = self.db.get_user("test_user")
        assert user["username"] == "test_user"

    def test_messages(self):
        messages = self.db.get_messages("1")
        assert len(messages) == 0

        self.db.insert_message("test_user", "1", "TestMessage", "TYPE_TEXT", 0.0)

        messages = self.db.get_messages("1")
        assert len(messages) == 1

    def test_files(self):

        # file counts are grouped per channel, so to just check the length we need `len()`
        file_count = len(self.db.get_file_count())
        assert file_count == 0

        self.db.insert_file(
            "test_file", "test_user", "test_type", 100, "full_path_test_file"
        )

        file_count = len(self.db.get_file_count())
        assert file_count == 1

        file_info = self.db.get_file("test_file")
        assert file_info["file"] == "test_file"
        assert file_info["type"] == "test_type"
        assert file_info["size"] == 100
        assert file_info["full_name"] == "full_path_test_file"

    def test_emojis(self):
        emojis = self.db.get_emojis()
        assert len(emojis) == 0

        self.db.insert_emoji("test_user", "test_emoji", "test_emoji_file_name", 0)

        emojis = self.db.get_emojis()
        assert len(emojis) == 1

        emoji = self.db.get_emoji("test_emoji")
        assert emoji["file"] == "test_emoji_file_name"
