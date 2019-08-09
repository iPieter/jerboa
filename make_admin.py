import sqlite3

conn = sqlite3.connect("data/data.db", check_same_thread=False)

c = conn.cursor()

print("The following users will be promoted to ADMIN status, do you wish to proceed?")

for row in c.execute("select username, state from users"):
    print(" - {} ({})".format(row[0], row[1]))

if input("[Y]es/[n]o: ").lower() == "y":
    c.execute(
        """
        update users
        set state = 'ADMIN'
        """,
        {},
    )

    conn.commit()

    print("Done, have a nice day!")
else:
    print("No users updated to admin")
