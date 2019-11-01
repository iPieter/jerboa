import {createAppContainer} from 'react-navigation';
import {createStackNavigator} from 'react-navigation-stack';
import ChatScreen from './ChatScreen';
import LoginScreen from './LoginScreen';
import DetailedImageView from './DetailedImageView';

const MainNavigator = createStackNavigator({
  Login: {screen: LoginScreen},
  Chat: {screen: ChatScreen},
  DetailedImageView: {screen: DetailedImageView},
});

const App = createAppContainer(MainNavigator);

export default App;
