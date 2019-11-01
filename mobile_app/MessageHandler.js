/*
 *  This class wraps a connection to the server.
 *  It has two responsibilites:
 *  - Easy to lookup a message by id or date
 *  - Handle connection changes and keep the message up to date
 * */
import io from 'socket.io-client';

export default class MessageHandler {
  // @param url: ws url
  // @param handleMessages: callback which can be used to listen
  // to message changes
  constructor(token, handleMessages, handleConnection) {
    this.token = token;
    this.handleMessages = handleMessages;
    this.handleConnection = handleConnection;
    this.setupConnection();

    // Messages are stored in an array, indices to messages are stored
    // in two maps: one for id, one for the date
    this.messages = [];
    this.messageById = new Map();
    this.messageByDate = new Map();
  }

  handleMessage = async msg => {
    // Add to messages
    // Update two maps
    // Call callback with messages sorted by date

    //TODO: replace by a sane implementation
    for (var i in this.messages) {
      if (msg.id === this.messages[i].id) return;
    }
    if (
      msg.message_type == 'TEXT_MESSAGE' ||
      msg.message_type == 'FILES_MESSAGE'
    ) {
      this.messages.push(msg);
    } else if (msg.message_type === 'TEXT_MESSAGE_UPDATE') {
      for (var i in this.messages) {
        if (this.messages[i].id === msg.previous_message) {
          this.messages[i].message = msg.message;
        }
      }
    }
    this.messages = this.messages.sort((a, b) => b.id - a.id);
    this.handleMessages(this.messages);
  };

  sendMessage = async msg => {
    console.log('Message handler');
    this.socket.emit('msg', JSON.stringify(msg));
  };

  setupConnection = async () => {
    console.log('Making connection');
    const socket = io('https://chat.ipieter.be/', {
      origins: '*',
      transports: ['websocket'],
    });
    socket.on('connect', () => {
      console.log('Connected, loading messages');
      this.socket = socket;
      this.loadMessages();
      this.connected = true;
    });
    socket.on('connect_error', error => {
      console.log('Error connecting');
      console.log(error);
    });
    socket.on('disconnect', msg => {
      this.handleConnection(false);
    });
    socket.on('msg', msg => {
      this.handleMessage(msg);
    });
    socket.on('error', e => {
      console.log('ERROR');
      console.log(e);
    });
  };

  loadMessages = async () => {
    const params = {
      channel: '1',
      initial_msg_id: 0,
    };
    try {
      let response = await fetch(
        `https://chat.ipieter.be/api/messages?channel=${encodeURIComponent(
          params.channel,
        )}&initial_msg_id=${encodeURIComponent(params.initial_msg_id)}`,
        {
          method: 'GET',
          headers: {
            Authorization: 'Bearer ' + this.token,
          },
        },
      );
      let responseJson = await response.json();
      responseJson = responseJson.reverse();
      for (var i in responseJson) {
        this.handleMessage(responseJson[i]);
      }
      this.handleConnection(true);
    } catch (e) {
      console.log(e);
    }
  };
}
