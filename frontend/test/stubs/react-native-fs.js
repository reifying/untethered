// Stub for react-native-fs in Node.js test environment

const rnfs = {
  readFile: function(path, encoding) { return Promise.resolve(''); },
  writeFile: function(path, contents, encoding) { return Promise.resolve(); },
  appendFile: function(path, contents, encoding) { return Promise.resolve(); },
  unlink: function(path) { return Promise.resolve(); },
  exists: function(path) { return Promise.resolve(false); },
  mkdir: function(path, options) { return Promise.resolve(); },
  moveFile: function(from, to) { return Promise.resolve(); },
  copyFile: function(from, to) { return Promise.resolve(); },
  readDir: function(path) { return Promise.resolve([]); },
  stat: function(path) { return Promise.resolve({ isFile: function() { return true; }, isDirectory: function() { return false; }, size: 0, mtime: new Date() }); },
  hash: function(path, algorithm) { return Promise.resolve(''); },
  downloadFile: function(options) { return { jobId: 1, promise: Promise.resolve({ statusCode: 200, bytesWritten: 0 }) }; },
  uploadFiles: function(options) { return { jobId: 1, promise: Promise.resolve({ statusCode: 200 }) }; },
  stopDownload: function(jobId) {},
  stopUpload: function(jobId) {},
  DocumentDirectoryPath: '/mock/documents',
  CachesDirectoryPath: '/mock/caches',
  LibraryDirectoryPath: '/mock/library',
  MainBundlePath: '/mock/bundle',
  TemporaryDirectoryPath: '/mock/temp',
  ExternalDirectoryPath: '/mock/external',
  ExternalStorageDirectoryPath: '/mock/external-storage'
};

// Export both as default and as named exports for compatibility
module.exports = rnfs;
module.exports.default = rnfs;
