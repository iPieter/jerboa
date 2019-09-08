"""
Add primary keys
"""

from yoyo import step

__depends__ = {'20190713_01_QDhmd-create-tables-for-messages'}

steps = [
    step("ALTER TABLE users ADD PRIMARY KEY (id)",
         "ALTER TABLE users DROP CONSTRAINT users_pkey"),

    step("ALTER TABLE active_logins ADD PRIMARY KEY (id)",
         "ALTER TABLE active_logins DROP CONSTRAINT active_logins_pkey"),
    
    step("ALTER TABLE messages ADD PRIMARY KEY (id)",
         "ALTER TABLE messages DROP CONSTRAINT messages_pkey"),

    step("ALTER TABLE files ADD PRIMARY KEY (id)",
         "ALTER TABLE files DROP CONSTRAINT files_pkey"),

    step("ALTER TABLE emojis ADD PRIMARY KEY (id)",
         "ALTER TABLE emojis DROP CONSTRAINT emojis_pkey")
]
