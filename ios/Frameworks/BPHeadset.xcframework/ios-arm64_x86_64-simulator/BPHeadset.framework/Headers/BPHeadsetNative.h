//
//  BPHeadset.h
//
//  Copyright  [2017-2023] GN Audio A/S. All rights reserved.
//

#import <CoreBluetooth/CoreBluetooth.h>

#define kBP_PARROTTBUTTON_SERVICE_UUID_STRING              @"95665a00-8704-11e5-960c-0002a5d5c51b"

/*!
 *  The mode of the BlueParrott Button.
 */
typedef NS_ENUM(NSInteger, BPButtonMode) {
    /*!
     *  An unknown mode (the current mode may not have been read yet)
     */
    BPButtonModeUnknown       = -1,
    
    /*!
     *  Mute on call mode. This is the default mode.
     */
    BPButtonModeMute          = 0,
    
    /*!
     *  Speed dial a specific number
     */
    BPButtonModeSpeedDial     = 1,
    
    /*!
     *  Compatible app or SDK Mode
     */
    BPButtonModeApp           = 2
};


/*!
 *  The headset button that was pressed. (More buttons may be added in the future)
 */
typedef NS_ENUM(NSInteger, BPButtonID) {
    /*!
     *  The BlueParrott Button
     */
    BPButtonIDParrott                       = 1,
};

/*!
 *  Whether the headset is currently bondable.
 */
typedef NS_ENUM(NSInteger, BPBondable) {
    /*!
     *  An unknown status (e.g. if the value has not been read from the headset yet)
     */
    BPBondableUnknown         = -1,
    /*!
     *  Bonding is currently disabled
     */
    BPBondableDisabled        = 0,
    /*!
     *  Bonding is currently enabled
     */
    BPBondableEnabled         = 1
};


/*!
 *  The resonCode provided to the onModeUpdateFailure callback on BPHeadsetListener
 */
typedef NS_ENUM(NSInteger, BPModeUpdateError) {
    /*!
     *  An unknown error
     */
    BPModeUpdateErrorUnknown              = 0,
    /*!
     *  Device was disconnected
     */
    BPModeUpdateErrorDisconnected         = 1
};

/*!
 *  The resonCode provided to the onReadFailure callback on BPHeadsetListener
 */
typedef NS_ENUM(NSInteger, BPReadError) {
    /*!
     *  An unknown error
     */
    BPReadErrorUnknown              = 0,
    
    /*!
     *  The attempt to read the values timed out
     */
    BPReadErrorTimeout              = 1
};


/*!
 *  The resonCode provided to the onConnectFailure callback on BPHeadsetListener
 */
typedef NS_ENUM(NSInteger, BPConnectError) {
    /*!
     *  An unknown error
     */
    BPConnectErrorUnknown              = 0,
    /*!
     *  Bluetooth is disabled
     */
    BPConnectErrorBluetoothDisabled    = 1,
    /*!
     *  Incompatible firmware version
     */
    BPConnectErrorFirmwareTooOld       = 2,
    /*!
     *  Incompatible SDK version
     */
    BPConnectErrorSDKTooOld            = 3,
    /*!
     *  Unauthorized - the user has not given permission for BT
     */
    BPConnectErrorBluetoothUnauthorized    = 4,
    /*!
     *  Bluetooth is Unsupported
     */
    BPConnectErrorBluetoothUnsupported     = 5
    
};


/*!
 *  The status provided to the onConnectProgress callback on BPHeadsetListener
 */
typedef NS_ENUM(NSInteger, BPConnectProgress) {
    /*!
     *  Started connecting to the headset
     */
    BPConnectProgressStarted             = 0,
    /*!
     *  Scanning for device
     */
    BPConnectProgressScanning            = 1,
    /*!
     *  Device Found, but not yet connected
     */
    BPConnectProgressFound               = 2,
    /*!
     *  Reading current settings from headset
     */
    BPConnectProgressReading             = 3
};

/*!
 *  The state of the proximity sensor in the headset
 */
typedef NS_ENUM(NSInteger, BPProximityState) {
    /*!
     *  The headset is not being worn
     */
    BPProximityStateOff                      = 0,
    /*!
     *  The headset is being worn
     */
    BPProximityStateOn                       = 1,
    /*!
     *  The proximity status is unknown (e.g. headset has no proximity sensor)
     */
    BPProximityStateUnknown                       = -1
};


/*!
 *  Notifies the application when there are headset events (connect/disconnect, button presses etc.) All events are optional so the application only needs to implement the methods for the events it wants to receive.
 */
@protocol BPHeadsetListener <NSObject>

@optional

/*!
 *  Status updates during the connection process.
 *
 *  @param status The current status of the connection process..
 */
- (void) onConnectProgress:(BPConnectProgress) status;

/*!
 *  The headset has connected. State values from the headset (App Name, Speed Dial Number, Firmware Version and all Enterprise values)
 *  will not be available until the onValuesRead callback is called.
 */
- (void) onConnect;

/*!
 *  The reading of headset values has completed.
 */
- (void) onValuesRead;

/*!
 *  The reading of enterprise headset values has completed.
 */
- (void) onEnterpriseValuesRead;

/*!
 *  The headset failed to connect e.g. headset not powered on.
 *
 *  @param reasonCode The error generated while trying to connect.
 */
- (void) onConnectFailure:(BPConnectError) reasonCode;

/*!
 *  The headset has disconnected.
 */
- (void) onDisconnect;

/*!
 *  The attempt to set the mode of the headset succeeded.
 */
- (void) onModeUpdate;

/*!
 *  The attempt to set the bondable state of the headset succeeded.
 */
- (void) onBondableUpdate;

/*!
 *  The attempt to set the mode of the headset failed.
 *
 *  @param reasonCode The error generated while trying to set the mode.
 */
- (void) onModeUpdateFailure:(BPModeUpdateError) reasonCode;

/*!
 *  The attempt to set the bondable state of the headset failed.
 *
 *  @param reasonCode The error generated while trying to set the mode.
 */
- (void) onBondableUpdateFailure:(BPModeUpdateError) reasonCode;

/*!
 *  The attempt to read the values from the headset failed (e.g. during connect process)
 *
 *  @param reasonCode The error generated while trying to set the mode.
 */
- (void) onReadFailure:(BPReadError) reasonCode;

/*!
 *  The BlueParrott button was tapped once.
 *
 *  @param buttonID The ID of the button that was tapped.
 */
- (void) onTap:(BPButtonID) buttonID;

/*!
 *  The BlueParrott button was double-tapped.
 *
 *  @param buttonID The ID of the button that was double tapped.
 */
- (void) onDoubleTap:(BPButtonID) buttonID;

/*!
 *  The BlueParrott button was pressed down.
 *
 *  @param buttonID The ID of the button that was pressed.
 */
- (void) onButtonDown:(BPButtonID) buttonID;

/*!
 *  The BlueParrott button was released.
 *
 *  @param buttonID The ID of the button that was released.
 */
- (void) onButtonUp:(BPButtonID) buttonID;

/*!
 *  The BlueParrott button was long pressed.
 *
 *  @param buttonID The ID of the button that was long pressed.
 */
- (void) onLongPress:(BPButtonID) buttonID;

/*!
 *  The proximity sensor on the headset changed state (e.g. the user put the headset on).
 *
 *  @param proximityState The new state for the proximity sensor.
 */
- (void) onProximityChanged:(BPProximityState) proximityState;


@end


/*!
 The main interface to the BlueParrott Headset.
 
 To instantiate, just use `sharedInstance`:
 
     BPHeadset *headset = [BPHeadset sharedInstance];
 
 To connect, set a listener that conforms to the [BPHeadsetListener](BPHeadsetListener) protocol, then call connect:
 
    // ViewController.h
    @interface ViewController : UIViewController <BPHeadsetListener>
         // ...
    @end
 
    // ViewController.m
    @implementation ViewController
      - (void)viewDidLoad {
        [super viewDidLoad];
        headset = [BPHeadset sharedInstance];
        [headset addListener:self];
      }
 
      - (IBAction)connectButtonTouched:(id)sender {
        [headset connect];
      }
    @end
 
 
 Then simply implement the methods from [BPHeadsetListener](BPHeadsetListener) that you are interested in:
 
    @implementation ViewController
      // ...
 
    #pragma mark BPHeadsetListener methods
      - (void) onConnect {
        // Update UI
 
        // Enable SDK Mode
        [headset enableSDKMode];
      }
 
      - (void) onConnectFailure:(BPConnectError) resonCode {
        // Inform the user
      }
 
      - (void) onDisconnect {
        // e.g. headset was powered off
      }
 
      - (void) onButtonDown:(BPButtonID) buttonID {
        // Button was pushed down, start recording...
      }
 
      - (void) onButtonUp:(BPButtonID) buttonID {
        // Button was released, stop recording...
      }
 
    @end
 
 */
@interface BPHeadset : NSObject
 /** @name Class Properties */

/*!
 * Set/get whether the SDK should automatically reconnect to a headset when disconnected.
 * When set to YES, on a disconnect the SDK will call connectPeripheral on the headset so that
 * the OS will automatically try to reconnect the BLE connection when the device connects again.
 */
@property (class) BOOL autoReconnect;

/*!
 * Set/get whether the SDK should send logs to BlueParrott/GN.
 * Remote logs allow us to improve the product’s quality and assist with development/release issues.
 * Defaults to YES.
 */
@property (class) BOOL remoteLogging;

/*!
 * Set/get the Customer UUID..
 * A unique ID that is assigned to each account/customer and must be set during the development and release of your application.
 * To retrieve your Customer ID, login to https://developer.jabra.com with your credentials and copy your Partner Key.
 */
@property (class) NSString *customerUUID;

/** @name Instantiating */

/*!
 *  Get an instance of the BPHeadset class
 *
 *  @return An instance of BPHeadset, or nil if running in the simulator
 */
+ (instancetype)sharedInstance;

/** @name Properties */

/*!
 *  Indicates if a headset is currently connected
 */
@property (nonatomic, readonly) BOOL connected;

/*!
 * The friendly name of the BlueParrott Headset
 */
@property (nonatomic, readonly) NSString *friendlyName;

/*!
 * The model number of the BlueParrott Headset (hexadecimal)
 */
@property (nonatomic, readonly) NSString *model;

/*!
 * The current mode for the BlueParrott Button
 */
@property (nonatomic, readonly) BPButtonMode buttonMode;

/*!
 *  Returns the App Key configured in the SDK (if the headset is in App Mode)
 */
@property (nonatomic, readonly) NSString *appKey;

/*!
 *  Returns the App Name configured in the SDK (if the headset is in App Mode)
 */
@property (nonatomic, readonly) NSString *appName;

/*!
 *  Returns the version of the SDK
 */
@property (nonatomic, readonly) NSString *speedDialNumber;


/*!
 *  Indicates if all values have been read from headset (e.g. speed dial number, App Name etc.)
 */
@property (nonatomic, readonly) BOOL valuesRead;

/*!
 *  Indicates if all enterprise values have been read from headset
 */
@property (nonatomic, readonly) BOOL enterpriseValuesRead;

/*!
 *  Indicates if the headset is currently in SDK Mode
 */
@property (nonatomic, readonly) BOOL sdkModeEnabled;

/*!
 *  Indicates if the headset is currently bondable
 */
@property (nonatomic, readonly) BPBondable bondableEnabled;

/*!
 *  Returns the version of the SDK
 */
@property (nonatomic, readonly) NSString *version;

/*!
 *  Returns the firmware version of the headset
 */
@property (nonatomic, readonly) NSString *firmwareVersion;

/*!
 *  The current state of the proximity sensor
 */
@property (nonatomic, readonly) BPProximityState proximityState;

/** @name Methods */

/*!
 *  Connect to the headset
 */
- (void) connect;

/*!
 *  Disconnect from the headset
 */
- (void) disconnect;


/*!
 *  Add a listener which will respond to headset button events
 *
 *  @param listener The listener object to send disconnect and button events to.
 */
- (void) addListener:(id<BPHeadsetListener>) listener;

/*!
 *  Remove an already added listener. Will not generate an error if the listener wasn't added.
 *
 *  @param listener The listener object remove.
 */
- (void) removeListener:(id<BPHeadsetListener>) listener;

/*!
 *  Sets the headset to mute-on-call mode
 */
- (void) setMuteMode;

/*!
 *  Sets the headset to a custom mode
 *
 *  @param mode The new mode for the headset. Values other than those in BPButtonMode are permitted, to allow for future custom modes.
 */
- (void) setCustomMode:(NSInteger)mode;


/*!
 *  Enables SDK mode on the headset, allowing the current app to receive button events.
 *  This will set the App Name to "SDK" by default.
 *  When disabled, the headset will return to mute-on-call mode.
 */
- (void) enableSDKMode;

/*!
 *  Enables SDK mode on the headset, allowing the current app to receive button events.
 *  This will set the App Name to the value specified, allowing the developer to query the value later
 *  in order to detect if multiple apps are using SDK mode.
 *  When disabled, the headset will return to mute-on-call mode.
 *
 *  @param appName The App Name to be returned while in SDK mode.
 */
- (void) enableSDKMode:(NSString *)appName;

/*!
 *  Disables SDK mode on the headset.
 *  When disabled, the headset will return to mute-on-call mode.
 */
- (void) disableSDKMode;

/*!
 *  NOTE: Changing the bondable setting on a headset may cause the headset to restart.
 *  Use caution when changing this value. Read the detailed description in the SDK guide for more information.
 *
 *  Enables or disables BLE bonding on the headset, allowing the the headset to bond to the
 *  handset so that it automatically reconnects when within range.
 *  If the value is changed, the headset will restart, and may need to be unpaired on the handset (if bonding was disabled).
 *  Defaults to enabled, so should normally not need to be changed.
 *
 *  @param enabled Sets whether bondable is enabled or disabled.
 */
- (void) setBondable:(BOOL) enabled;

/*!
 *  Sets the headset to App Mode with the specified App Key and App Name.
 *  This allows an app to check if another app has set the BlueParrott Button function, and possibly ignore events in that case.
 *  Success or failure will be indicated by callbacks to the onModeUpdate callback.
 *
 *  @param appKey The App Key for the current app. Uniquely identifies the current app. Must be 20 characters or less.
 *  @param appName A display name for the current app.
 */
- (void) setAppModeWithAppKey:(NSString *)appKey appName:(NSString *)appName;


/*!
 *  Sets the headset to Spped Dial mode with the specified phone number. Pressing the BlueParrott Button will dial the number.
 *  Success or failure will be indicated by callbacks to the onModeUpdate callback.
 *
 *  @param phoneNumber The phone number to dial when the BlueParrott Button is pressed.
 */
- (void) setSpeedDialMode:(NSString *)phoneNumber;

/*!
 *  Sets an enterprise config key to the specified value.
 *  For up-to-date information on the keys and expected values, check the online documentation.
 *
 *  @param key The Key for the Enterprise Value
 *  @param value The Value for the Enterprise Value
 */
- (void) setConfigValue:(NSUInteger)key value:(NSString *)value;

/*!
 *  Gets an enterprise config value for the specified key.
 *  If the value has not been set, nil will be returned.
 *
 *  @param key The Key for the Enterprise Value to be retrieved
 */
- (NSString *) getConfigValue:(NSUInteger)key;

/*!
 *  Gets all of the enterprise config keys and their values
 *  The returned dictionary will contain NSNumber keys representing the Enterprise key
 *  and a corresponding NSString value for the key.
 *  Note: not all keys may be set and the keys may not be in order
 */
- (NSDictionary*) getConfigValues;

@end
