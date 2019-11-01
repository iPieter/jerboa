import React, {Component} from 'react';
import {
  SafeAreaView,
  View,
  FlatList,
  StyleSheet,
  Text,
  TextInput,
  Image,
  KeyboardAvoidingView,
  ActivityIndicator,
  Dimensions,
  TouchableOpacity,
  Keyboard,
} from 'react-native';

import Fuse from 'fuse.js';
import ImagePicker from 'react-native-image-picker';
import MessageHandler from './MessageHandler';

export default class ChatScreen extends React.Component {
  constructor(props) {
    super(props);
    this.state = {
      showEmojiPicker: false, //Separate menu for emoji
      inputHasFocus: false,
      keyboardHeight: Dimensions.get('window').height * 0.33, // will be replaced
      message: '',
      messages: [],
      emojisLoaded: false,
      emojis: [],
      emojiSearch: '',
      selectedImages: [],
      connected: false,
      showEmojiHelper: false, //Suggestions when typing
      emojiHelperPredictions: [],
    };
    this.token = this.props.navigation.getParam('token');
    this.messageHandler = new MessageHandler(
      this.token,
      this.onMessagesUpdate,
      this.onConnectionUpdate,
    );
    this.loadUsers();
    this.loadEmojis();
  }
  static navigationOptions = {
    header: null,
  };

  componentDidMount() {
    Keyboard.addListener('keyboardDidShow', e => {
      if (this.state.inputHasFocus) {
        this.setState({
          keyboardHeight: e.endCoordinates.height,
        });
      }
    });
  }

  onMessagesUpdate = messages => {
    this.setState({messages: messages});
  };

  onConnectionUpdate = status => {
    this.setState({connected: status});
  };

  loadEmojis = async () => {
    try {
      let response = await fetch('https://chat.ipieter.be/api/emojis/list', {
        method: 'GET',
        headers: {
          Authorization: 'Bearer ' + this.token,
        },
      });
      let responseJson = await response.json();
      this.setState(state => ({
        emojis: responseJson,
        emojisLoaded: true,
      }));
    } catch (e) {
      console.log(e);
    }
  };

  loadUsers = async () => {
    try {
      let response = await fetch('https://chat.ipieter.be/api/users', {
        method: 'GET',
        headers: {
          Authorization: 'Bearer ' + this.token,
        },
      });
      let responseJson = await response.json();
      this.setState(state => ({
        users: responseJson,
      }));
    } catch (e) {
      console.log(e);
    }
  };

  addImage = () => {
    const options = {
      title: 'Add an image',
      chooseWhichLibraryTitle: null,
    };

    ImagePicker.showImagePicker(options, response => {
      if (response.didCancel) {
        console.log('User cancelled image picker');
      } else if (response.error) {
        console.log('ImagePicker Error: ', response.error);
      } else if (response.customButton) {
        console.log('User tapped custom button: ', response.customButton);
      } else {
        this.setState(state => ({
          selectedImages: [...state.selectedImages, response],
        }));
      }
    });
  };

  removeImage = uri => {
    var images = this.state.selectedImages.filter(img => img.uri !== uri);
    this.setState({selectedImages: images});
  };

  renderImages = () => {
    var images = [];
    for (var index in this.state.selectedImages) {
      var img = this.state.selectedImages[index];
      images.push(
        <TouchableOpacity onPress={() => this.removeImage(img.uri)}>
          <Image source={{uri: img.uri}} style={styles.previewImage} />
        </TouchableOpacity>,
      );
    }
    return (
      <View>
        <Text>The following images will be sent:</Text>
        {images}
      </View>
    );
  };

  onInputFocus = e => {
    this.setState({inputHasFocus: true});
  };
  onInputBlur = e => {
    this.setState({inputHasFocus: false});
  };

  sendMessage = async () => {
    if (
      this.state.message.length === 0 &&
      this.state.selectedImages.length === 0
    ) {
      return;
    }

    var message = this.state.message;

    if (this.state.selectedImages.length > 0) {
      var formData = new FormData();

      for (var i in this.state.selectedImages) {
        var file = this.state.selectedImages[i];
        formData.append('files[' + i + ']', {
          uri: file.uri,
          type: file.type,
          name: 'Uploaded file',
        });
      }

      try {
        let response = await fetch('https://chat.ipieter.be/api/files', {
          method: 'POST',
          headers: {
            Authorization: 'Bearer ' + this.token,
            'Content-Type': 'multipart/form-data',
          },
          body: formData,
        });
        let responseJson = await response.json();

        var extendedMessage = ' ';
        for (var i in responseJson) {
          extendedMessage +=
            '![https://chat.ipieter.be/api/files?f=' +
            responseJson[i].file +
            '](https://chat.ipieter.be/api/files?f=' +
            responseJson[i].file +
            ')';
        }
        message += extendedMessage;
      } catch (e) {
        console.log(e);
        return;
      }
    }

    var newMessage = {
      message_type: 'TEXT_MESSAGE',
      sender: this.token,
      channel: '1',
      message: message,
      sent_time: new Date(),
      signature: 'na',
      nonce: Math.random()
        .toString(36)
        .substring(7),
    };
    this.messageHandler.sendMessage(newMessage);

    this.setState(state => ({
      message: '',
      selectedImages: [],
    }));
  };

  onEmojiPicked = name => {
    this.setState(state => ({
      message: state.message + ' :' + name + ': ',
    }));
  };

  renderEmojiPicker = () => {
    var emojis = this.state.emojis;
    if (this.state.emojiSearch.length > 0) {
      // {"emoticons": [], "imageUrl": "emoji/pieters-internet", "keywords": ["custom"], "name": "pieters-internet", "short_names": ["pieters-internet"]}
      var options = {
        shouldSort: true,
        threshold: 0.6,
        location: 0,
        distance: 100,
        maxPatternLength: 32,
        minMatchCharLength: 1,
        keys: ['name'],
      };
      var fuse = new Fuse(this.state.emojis, options);
      emojis = fuse.search(this.state.emojiSearch);
    }

    const cols = Math.floor(Dimensions.get('window').width / 42);
    return (
      <KeyboardAvoidingView
        style={[styles.emojiPicker, {height: this.state.keyboardHeight}]}>
        <View style={styles.emojiPickerInputContainer}>
          <TouchableOpacity
            onPress={() => {
              this.mainInput.focus();
              this.setState({showEmojiPicker: false});
            }}>
            <Image
              style={styles.emojiPickerButton}
              source={require('./btn_keyboard.png')}
            />
          </TouchableOpacity>
          <TextInput
            placeholder="Search for emojis"
            style={styles.emojiPickerInput}
            onChangeText={text => this.setState({emojiSearch: text})}
            value={this.state.emojiSearch}
          />
          <TouchableOpacity onPress={() => this.setState({emojiSearch: ''})}>
            <Image
              style={styles.emojiPickerButton}
              source={require('./btn_clear.png')}
            />
          </TouchableOpacity>
        </View>
        {!this.state.emojisLoaded && (
          <ActivityIndicator size="large" color="#0000ff" />
        )}
        {this.state.emojisLoaded && (
          <FlatList
            keyboardShouldPersistTaps="handled"
            style={styles.emojiList}
            horizontal={false}
            numColumns={cols}
            data={emojis}
            renderItem={({item}) => (
              <TouchableOpacity onPress={() => this.onEmojiPicked(item.name)}>
                <Image
                  source={{
                    uri: `https://chat.ipieter.be/api/${item.imageUrl}`,
                    method: 'GET',
                  }}
                  style={styles.emoji}
                />
              </TouchableOpacity>
            )}
            keyExtractor={item => item.name}
          />
        )}
      </KeyboardAvoidingView>
    );
  };

  renderMessage = ({index, item}) => {
    var progressive = false;
    if (index + 1 < this.state.messages.length) {
      var prevMessage = this.state.messages[index + 1];
      if (prevMessage.sender === item.sender) {
        var delta = item.sent_time - prevMessage.sent_time;
        if (delta < 100) {
          progressive = true;
        }
      }
    }

    const RGX_EMOJI = /(:[\w,-]+:)/g;
    var messageText = '';
    if (item.message_type === 'FILES_MESSAGE') {
      messageText = item.message.message;
    } else {
      messageText = item.message;
    }
    var parts = messageText.split(RGX_EMOJI);

    var messageContent = [];

    for (var part in parts) {
      var hasMatch = false;
      var keyName = 'message-' + item.id + '-part-' + part;
      if (parts[part].match(RGX_EMOJI)) {
        var emojiName = parts[part].substring(1, parts[part].length - 1);

        // TODO: Replace by lookup table
        for (var emoji in this.state.emojis) {
          if (this.state.emojis[emoji].name === emojiName) {
            hasMatch = true;
            messageContent.push(
              <Image
                key={keyName}
                source={{
                  uri: `https://chat.ipieter.be/api/${
                    this.state.emojis[emoji].imageUrl
                  }`,
                  method: 'GET',
                }}
                style={styles.inlineEmoji}
              />,
            );
            break;
          }
        }
      }
      if (!hasMatch) {
        messageContent.push(
          <Text key={keyName} style={styles.msgContentText}>
            {parts[part]}
          </Text>,
        );
      }
    }

    if (item.message_type === 'FILES_MESSAGE') {
      for (var i in item.message.files) {
        var file = item.message.files[i];
        var url = 'https://chat.ipieter.be/api/files?f=' + file.file;
        if (file.type.includes('image')) {
          messageContent.push(
            <TouchableOpacity
              key={file.file}
              onPress={() => {
                this.props.navigation.navigate('DetailedImageView', {uri: url});
              }}>
              <Image
                source={{
                  uri: url,
                  method: 'GET',
                }}
                style={styles.inlineImage}
              />
            </TouchableOpacity>,
          );
        } else {
          messageContent.push(
            <TouchableOpacity key={file.file} onPress={() => {}}>
              <Text>
                A file has been shared by {file.user} {file.size} {file.type}
              </Text>
            </TouchableOpacity>,
          );
        }
      }
    }

    var imageSource = null;
    // TODO
    for (var user in this.state.users) {
      if (item.sender === this.state.users[user].username) {
        imageSource = (
          <Image
            style={styles.msgUserImg}
            source={{
              uri: `https://chat.ipieter.be/api/files?f=${
                this.state.users[user].profile_image
              }`,
              method: 'GET',
            }}
          />
        );
      }
    }
    if (imageSource === null) {
      imageSource = (
        <Image style={styles.msgUserImg} source={require('./user_image.gif')} />
      );
    }

    return (
      <View style={[!progressive && styles.item, styles.itemDefault]}>
        {!progressive && imageSource}
        <View style={styles.msgBody}>
          {!progressive && (
            <View style={styles.msgHeader}>
              <Text style={styles.msgSender}>{item.sender}</Text>
              <Text style={styles.msgDate}>
                {new Date(item.sent_time * 1000).toLocaleString()}
              </Text>
            </View>
          )}
          <View
            style={[
              styles.msgContent,
              progressive && styles.msgContentProgressive,
            ]}>
            {messageContent}
          </View>
        </View>
      </View>
    );
  };

  handleMessageInput = text => {
    this.setState({message: text});

    var lastColon = text.lastIndexOf(':');
    if (lastColon >= 0) {
      var word = text.substring(lastColon + 1);
      if (word.length < 1) return;
      if (/\s/g.test(word)) return;

      this.setState({showEmojiHelper: true});
      var options = {
        shouldSort: true,
        threshold: 0.6,
        location: 0,
        distance: 100,
        maxPatternLength: 32,
        minMatchCharLength: 1,
        keys: ['name'],
      };
      var fuse = new Fuse(this.state.emojis, options);
      var emojis = fuse.search(word).slice(0, 5);
      this.setState({emojiHelperPredictions: emojis});
    } else {
      this.setState({showEmojiHelper: false, emojiHelperPredictions: []});
    }
  };

  renderEmojiSuggestions = () => {
    return (
      <FlatList
        style={styles.emojiHelper}
        data={this.state.emojiHelperPredictions}
        renderItem={({item}) => (
          <TouchableOpacity
            style={styles.emojiSuggestion}
            onPress={() => {
              var message = this.state.message;
              message = message.substring(0, message.lastIndexOf(':'));
              message = message + ' :' + item.name + ': ';

              this.setState(state => ({
                showEmojiHelper: false,
                emojiHelperPredictions: [],
                message: message,
              }));
            }}>
            <Image
              source={{
                uri: `https://chat.ipieter.be/api/${item.imageUrl}`,
                method: 'GET',
              }}
              style={styles.inlineEmoji}
            />
            <Text>:{item.name}:</Text>
          </TouchableOpacity>
        )}
        keyExtractor={emoji => 'emoji-suggestion-' + emoji.name}
        initialNumToRender="5"
        keyboardShouldPersistTaps="handled"
      />
    );
  };

  render() {
    if (!this.state.connected) {
      return (
        <View style={styles.connectionStatusContainer}>
          <ActivityIndicator size="large" color="#0000ff" />
          <Text>Connecting...</Text>
        </View>
      );
    }

    return (
      <SafeAreaView style={styles.container}>
        <FlatList
          inverted
          data={this.state.messages}
          renderItem={this.renderMessage}
          keyExtractor={item => 'message-' + item.id}
          style={styles.messages}
        />
        {this.state.showEmojiHelper && this.renderEmojiSuggestions()}
        <KeyboardAvoidingView style={styles.inputView}>
          <TouchableOpacity
            onPress={() => {
              Keyboard.dismiss();
              this.setState({showEmojiPicker: !this.state.showEmojiPicker});
            }}>
            <Image style={styles.button} source={require('./btn_emoji.png')} />
          </TouchableOpacity>
          <TextInput
            style={styles.input}
            multiline
            placeholder="Messsage"
            ref={ref => {
              this.mainInput = ref;
            }}
            onFocus={this.onInputFocus}
            onBlur={this.onInputBlur}
            onChangeText={this.handleMessageInput}
            value={this.state.message}
          />
          <TouchableOpacity onPress={this.addImage}>
            <Image
              style={styles.button}
              source={require('./btn_add_image.png')}
            />
          </TouchableOpacity>
          <TouchableOpacity onPress={this.sendMessage}>
            <Image style={styles.button} source={require('./btn_send.png')} />
          </TouchableOpacity>
        </KeyboardAvoidingView>
        {this.state.selectedImages.length > 0 && this.renderImages()}
        {this.state.showEmojiPicker && this.renderEmojiPicker()}
      </SafeAreaView>
    );
  }
}

const styles = StyleSheet.create({
  connectionStatusContainer: {
    justifyContent: 'center',
    alignItems: 'center',
    flex: 1,
  },
  container: {
    flex: 1,
    flexDirection: 'column',
    justifyContent: 'flex-end',
  },
  messages: {
    flexGrow: 1,
  },
  item: {
    padding: 8,
    borderTopColor: '#cccccc',
    borderTopWidth: 1,
  },
  itemDefault: {
    flexDirection: 'row',
  },
  inputView: {
    flexDirection: 'row',
    alignItems: 'center',
    borderTopColor: '#aaaaaa',
    borderTopWidth: 1,
    paddingTop: 5,
  },
  title: {
    fontSize: 16,
  },
  input: {
    flex: 1,
    padding: 5,
  },
  button: {
    width: 24,
    height: 24,
    resizeMode: 'contain',
    marginRight: 5,
    marginLeft: 5,
  },
  msgUserImg: {
    width: 32,
    height: 32,
    resizeMode: 'contain',
  },
  msgHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    textAlign: 'center',
  },
  msgDate: {
    fontSize: 12,
    marginLeft: 4,
    color: '#878787',
  },
  msgSender: {
    fontSize: 15,
    fontWeight: 'bold',
  },
  msgBody: {
    marginLeft: 5,
    flexDirection: 'column',
  },
  msgContent: {
    alignItems: 'center',
    flexDirection: 'row',
    flexShrink: 1,
  },
  msgContentProgressive: {
    marginLeft: 40, // FIXME
  },
  msgContentText: {},
  inlineEmoji: {
    width: 24,
    height: 24,
    resizeMode: 'contain',
    margin: 0,
  },
  inlineImage: {
    width: 200,
    height: 200,
    resizeMode: 'contain',
  },
  emojiPickerInputContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    borderTopWidth: 0.5,
    borderBottomWidth: 0.5,
  },
  emojiPickerInput: {
    padding: 2,
    flex: 1,
  },
  emojiPickerButton: {
    margin: 5,
    width: 24,
    height: 24,
    resizeMode: 'contain',
  },
  emojiPicker: {},
  emojiList: {},
  emoji: {
    margin: 5,
    width: 32,
    height: 32,
    resizeMode: 'contain',
  },
  previewImage: {
    margin: 5,
    width: 50,
    height: 50,
    resizeMode: 'contain',
  },
  emojiSuggestion: {
    flexDirection: 'row',
    padding: 5,
  },
  emojiHelper: {
    borderTopColor: '#aaaaaa',
    borderTopWidth: 1,
  },
});
