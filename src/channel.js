/*
 * The server joins every socket to rooms keyed by the *integer* channel id,
 * then broadcasts a message to the room named by the `channel` value the
 * client sent. Route params are strings after a page reload ("5"), which
 * would address a room nobody is in, so always send channel ids as Numbers.
 *
 * Without a channel in the route we are on "/", which shows General (1).
 */
export function channelId(value = 1) {
  return Number(value);
}
