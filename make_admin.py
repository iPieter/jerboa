
import psycopg2

conn = psycopg2.connect(user="postgres",
                        password="mysecretpassword", host="localhost")

c = conn.cursor()

print("The following users will be promoted to ADMIN status, do you wish to proceed?")

c.execute("select username, state from users")
for row in c.fetchall():
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
