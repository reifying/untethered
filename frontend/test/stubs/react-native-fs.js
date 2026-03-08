// Stub for react-native-fs in Node.js test environment

const rnfs = {
  readFile: function(path, encoding) { return Promise.resolve(''); },
  writeFile: function(path, contents, encoding) { return Promise.resolve(); },
  unlink: function(path) { return Promise.resolve(); },
  exists: function(path) { return Promise.resolve(false); },
  mkdir: function(path, options) { return Promise.resolve(); },
  readDir: function(path) { return Promise.resolve([]); },
  stat: function(path) { return Promise.resolve({ isFile: function() { return true; }, size: 0 }); },
  DocumentDirectoryPath: '/mock/documents',
  CachesDirectoryPath: '/mock/caches',
  TemporaryDirectoryPath: '/mock/temp'
};

module.exports = rnfs;
module.exports.default = rnfs;
