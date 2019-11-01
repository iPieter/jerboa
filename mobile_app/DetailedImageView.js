import React from 'react';
import {View, StyleSheet, Image, Dimensions, PanResponder} from 'react-native';

export default class DetailedImageView extends React.Component {
  static navigationOptions = {
    title: 'Image',
  };

  constructor(props) {
    super(props);
    this.state = {
      x: 0,
      y: 0,
      width: Dimensions.get('window').width,
      height: Dimensions.get('window').height,
      timestamp: 0,
      dist: 0,
      lastX: 0,
      lastY: 0,
    };
    this.uri = this.props.navigation.getParam('uri');

    this._panResponder = PanResponder.create({
      onStartShouldSetPanResponder: (evt, gestureState) => true,
      onStartShouldSetPanResponderCapture: (evt, gestureState) => true,
      onMoveShouldSetPanResponder: (evt, gestureState) => true,
      onMoveShouldSetPanResponderCapture: (evt, gestureState) => true,

      onPanResponderMove: (evt, gestureState) => {
        if (evt.nativeEvent.touches.length == 2) {
          var t1 = evt.nativeEvent.touches[0];
          var t2 = evt.nativeEvent.touches[1];

          var deltaX = t1.pageX - t2.pageX;
          var deltaY = t1.pageY - t2.pageY;
          var size = Math.sqrt(deltaX * deltaX + deltaY * deltaY);

          var delta = 1.0;
          if (t1.timestamp - this.state.timestamp < 1000) {
            if (size - this.state.dist > 0) {
              delta = 1.1;
            } else {
              delta = 0.9;
            }
            var winW = Dimensions.get('window').width;
            var winH = Dimensions.get('window').height;
            this.setState(state => ({
              width: this.clamp(state.width * delta, winW * 0.5, winW * 4.0),
              height: this.clamp(state.height * delta, winH * 0.5, winH * 4.0),
            }));
          }

          this.setState({
            dist: size,
            timestamp: t1.timestamp,
          });
        } else if (evt.nativeEvent.touches.length === 1) {
          var t = evt.nativeEvent.touches[0];

          var deltaX = t.pageX - this.state.lastX;
          var deltaY = t.pageY - this.state.lastY;
          var size = Math.sqrt(deltaX * deltaX + deltaY * deltaY);
          if (size === 0.0) {
            size = 1.0;
          }
          var DELTA = 15;
          deltaX /= size;
          deltaX *= DELTA;
          deltaY /= size;
          deltaY *= DELTA;

          console.log(deltaX + ',' + deltaY);

          if (t.timestamp - this.state.timestamp < 1000 && size > 5) {
            this.setState(state => ({
              //TODO, determine correct values based on image width and zoom
              //so that the image always stays visible
              x: this.clamp(state.x + deltaX, -500, 500),
              y: this.clamp(state.y + deltaY, -500, 500),
            }));
          }

          this.setState({
            lastX: t.pageX,
            lastY: t.pageY,
            timestamp: t.timestamp,
          });
        }
      },
      onPanResponderTerminationRequest: (evt, gestureState) => true,
      onPanResponderRelease: (evt, gestureState) => {
        // The user has released all touches while this view is the
        // responder. This typically means a gesture has succeeded
      },
      onPanResponderTerminate: (evt, gestureState) => {
        // Another component has become the responder, so this gesture
        // should be cancelled
      },
      onShouldBlockNativeResponder: (evt, gestureState) => {
        // Returns whether this component should block native components from becoming the JS
        // responder. Returns true by default. Is currently only supported on android.
        return true;
      },
    });
  }

  clamp = (x, min, max) => {
    if (x < min) {
      return min;
    }
    if (x > max) {
      return max;
    }
    return x;
  };

  render() {
    return (
      <View style={styles.container} {...this._panResponder.panHandlers}>
        <Image
          style={[
            styles.image,
            {width: this.state.width},
            {height: this.state.height},
            {left: this.state.x},
            {top: this.state.y},
          ]}
          source={{
            uri: `${this.uri}`,
            method: 'GET',
          }}
        />
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
  image: {
    resizeMode: 'contain',
  },
});
