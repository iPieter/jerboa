# Jerboa https://travis-ci.org/iPieter/chat.svg?branch=master

A bit late, but the best chat app you've ever seen.

## Database

```sql
CREATE TABLE `users` (
	`id`	INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
	`username`	TEXT NOT NULL UNIQUE,
	`password`	TEXT NOT NULL,
	`display_name`	TEXT,
	`profile_image`	TEXT DEFAULT 'default.png',
	`state`	TEXT
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

```sql
CREATE TABLE `files` (
	`id`	INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
	`file`	TEXT,
	`user_id`	INTEGER,
	`type`	TEXT,
	`size`	INTEGER,
	`full_name`	TEXT
);
```

## Message types

```json
{
  "message_type": "TEXT_MESSAGE",
  "sender": "a json web token or other server-issued token",
  "channel": "channel identifier",
  "message": "...",
  "sent_time": "date time",
  "signature": "na"
}
```

With `TEXT_MESSAGE`, the message is a simple string that can optionally be formatted in markdown. Other message types might have other contents in this field.

### FILES_MESSAGE

```json
{
  "message": "the actual message",
  "files": ["abc123", "cde456"]
}
```
