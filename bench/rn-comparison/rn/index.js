/**
 * RN 0.76.9 entry point for the RND-5 benchmark sibling.
 * Registers App (see App.js) under the app name the native shell expects.
 *
 * When scaffolded by scripts/init-rn-project.sh, the generated android/ project's
 * MainActivity returns getMainComponentName() === "CanopyBenchRN", matching APP_NAME below.
 */
import { AppRegistry } from 'react-native';
import App from './App';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => App);
