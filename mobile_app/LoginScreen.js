import React from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Image,
  ActivityIndicator,
} from 'react-native';

import AsyncStorage from '@react-native-community/async-storage';
import {Base64} from 'js-base64';

export default class LoginScreen extends React.Component {
  constructor(props) {
    super(props);
    this.state = {
      loading: true,
      username: '',
      password: '',
      waitingResponse: false,
      errorText: '',
    };

    this.loadToken();
  }
  static navigationOptions = {
    header: null,
  };

  loadToken = async () => {
    try {
      const value = await AsyncStorage.getItem('token');
      this.setState({loading: false});
      if (value !== null) {
        this.props.navigation.replace('Chat', {token: value});
      }
    } catch (e) {
      this.setState({errorText: 'Failed to access local storage'});
    }
  };

  login = async () => {
    if (!this.state.waitingResponse) {
      this.setState({errorText: ''});
      this.setState({waitingResponse: true});
      try {
        let response = await fetch('https://chat.ipieter.be/api/login', {
          method: 'GET',
          headers: {
            'X-Requested-With': 'application/x-www-form-urlencoded',
            Authorization:
              'Basic ' +
              Base64.btoa(this.state.username + ':' + this.state.password),
          },
        });
        let responseJson = await response.json();
        await AsyncStorage.setItem('token', responseJson.token);
        this.props.navigation.replace('Chat');
      } catch (e) {
        this.setState({errorText: 'Error while logging in, please try again'});
        this.setState({waitingResponse: false});
        this.setState({username: ''});
        this.setState({password: ''});
      }
    }
  };

  render() {
    if (this.state.loading) {
      return (
        <View style={styles.container}>
          <ActivityIndicator size="large" color="#0000ff" />
          <Text>{this.state.errorText}</Text>
        </View>
      );
    }
    return (
      <View style={styles.container}>
        <Image style={styles.logo} source={require('./icon.png')} />
        <Text style={styles.title}>Jerboa</Text>
        {this.state.errorText !== '' && (
          <Text style={styles.errorText}>{this.state.errorText}</Text>
        )}
        <TextInput
          style={styles.input}
          placeholder="Username"
          onChangeText={text => this.setState({username: text})}
          value={this.state.username}
        />
        <TextInput
          style={styles.input}
          placeholder="Password"
          secureTextEntry
          onChangeText={text => this.setState({password: text})}
          value={this.state.password}
        />
        <TouchableOpacity style={styles.button} onPress={this.login}>
          <Text style={styles.buttonText}>Login</Text>
        </TouchableOpacity>
      </View>
    );
  }
}

const styles = StyleSheet.create({
  container: {
    justifyContent: 'center',
    alignItems: 'center',
    flex: 1,
  },
  title: {
    fontSize: 32,
    color: '#999999',
    marginBottom: 30,
  },
  logo: {
    borderWidth: 2,
    borderRadius: 25,
    borderColor: '#cccccc',
  },
  input: {
    width: '75%',
    textAlign: 'center',
    borderWidth: 1,
    borderRadius: 45,
    borderColor: '#cccccc',
    marginBottom: 5,
  },
  button: {
    borderRadius: 45,
    padding: 15,
    width: '75%',
    backgroundColor: '#007bff',
    textAlign: 'center',
  },
  buttonText: {
    textAlign: 'center',
    color: '#dddddd',
  },
  errorText: {
    color: '#dd2222',
    fontSize: 14,
  },
});
