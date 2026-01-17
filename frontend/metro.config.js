const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

/**
 * Metro configuration for React Native with shadow-cljs
 * https://reactnative.dev/docs/metro
 */
const config = {
  // Watch the shadow-cljs output directory
  watchFolders: [__dirname + '/app'],
  
  resolver: {
    // Allow loading .cljs files through shadow-cljs output
    sourceExts: ['js', 'jsx', 'json', 'ts', 'tsx'],
  },
  
  transformer: {
    getTransformOptions: async () => ({
      transform: {
        experimentalImportSupport: false,
        inlineRequires: true,
      },
    }),
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
