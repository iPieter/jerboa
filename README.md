# FigChat 2.0

A bit late, but the best chat app you've ever seen.

## Database

```sql
CREATE TABLE `users` (
	`id`	INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
	`username`	TEXT NOT NULL UNIQUE,
	`password`	TEXT NOT NULL,
	`display_name`	TEXT,
	`profile_image`	TEXT DEFAULT 'default.png'
);
```

```sql
CREATE TABLE `active_logins` (
	`id`	INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
	`queue`	TEXT UNIQUE,
	`last_seen`	NUMERIC,
	`active`	INTEGER,
	`device`	TEXT,
	`device_type`	TEXT,
	`expires`	NUMERIC,
	`user_id`	INTEGER
);
```

```sql
CREATE TABLE `messages` (
	`id`	INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
	`sender`	INTEGER,
	`channel`	TEXT,
	`message`	TEXT,
	`sent_time`	NUMERIC
);
```
