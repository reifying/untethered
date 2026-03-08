// Stub for @notifee/react-native in Node.js test environment

module.exports = {
  default: {
    displayNotification: function(notification) { return Promise.resolve(); },
    cancelNotification: function(id) { return Promise.resolve(); },
    cancelAllNotifications: function() { return Promise.resolve(); },
    requestPermission: function() { return Promise.resolve({ authorizationStatus: 1 }); },
    getNotificationSettings: function() { return Promise.resolve({ authorizationStatus: 1 }); },
    setNotificationCategories: function(categories) { return Promise.resolve(); },
    createChannel: function(channel) { return Promise.resolve(); },
    onForegroundEvent: function(handler) { return function() {}; },
    onBackgroundEvent: function(handler) {}
  }
};
