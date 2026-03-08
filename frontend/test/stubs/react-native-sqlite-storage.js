// Stub for react-native-sqlite-storage in Node.js test environment

module.exports = {
  openDatabase: function(params) {
    return {
      transaction: function(txCallback, errorCallback, successCallback) {
        var tx = {
          executeSql: function(sql, params, success, error) {
            if (success) success(tx, { rows: { length: 0, item: function() { return null; } } });
          }
        };
        txCallback(tx);
        if (successCallback) successCallback();
      },
      close: function(success, error) {
        if (success) success();
      }
    };
  },
  enablePromise: function(enable) {},
  DEBUG: function(debug) {}
};
