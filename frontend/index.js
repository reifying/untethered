/**
 * React Native entry point
 * This file loads the shadow-cljs compiled ClojureScript application
 */
import {AppRegistry} from 'react-native';
import App from './app/index';
import {name as appName} from './app.json';

AppRegistry.registerComponent(appName, () => App);
