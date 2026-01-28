// Stub for react-native-document-picker in Node.js test environment

module.exports = {
  default: {
    pick: function(options) { return Promise.resolve([]); },
    pickDirectory: function() { return Promise.resolve(null); },
    pickMultiple: function(options) { return Promise.resolve([]); },
    pickSingle: function(options) { return Promise.resolve(null); },
    isCancel: function(err) { return false; }
  },
  pick: function(options) { return Promise.resolve([]); },
  pickDirectory: function() { return Promise.resolve(null); },
  pickMultiple: function(options) { return Promise.resolve([]); },
  pickSingle: function(options) { return Promise.resolve(null); },
  isCancel: function(err) { return false; },
  types: {
    allFiles: '*/*',
    images: 'image/*',
    plainText: 'text/plain',
    audio: 'audio/*',
    pdf: 'application/pdf',
    zip: 'application/zip',
    csv: 'text/csv',
    doc: 'application/msword',
    docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ppt: 'application/vnd.ms-powerpoint',
    pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    xls: 'application/vnd.ms-excel',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  }
};
