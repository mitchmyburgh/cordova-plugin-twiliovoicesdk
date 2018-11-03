//
//  TwilioVoicePlugin.m
//  TwilioVoiceExample
//
//  Created by Jeffrey Linwood on 3/11/17.
//  Updated by Adam Rivera 02/24/2018.
//
//  Based on https://github.com/twilio/voice-callkit-quickstart-objc
//

#import "TwilioVoicePlugin.h"

@import AVFoundation;
@import CallKit;
@import PushKit;
@import TwilioVoice;
@import UserNotifications;

@interface TwilioVoicePlugin () <PKPushRegistryDelegate, TVOCallDelegate, TVONotificationDelegate, CXProviderDelegate>

// Callback for the Javascript plugin delegate, used for events
@property(nonatomic, strong) NSString *callback;

// Push registry for APNS VOIP
@property (nonatomic, strong) PKPushRegistry *voipPushRegistry;

// Current call (can be nil)
@property (nonatomic, strong) TVOCall *call;

// Current call invite (can be nil)
@property (nonatomic, strong) TVOCallInvite *callInvite;

// Device Token from Apple Push Notification Service for VOIP
@property (nonatomic, strong) NSString *pushDeviceToken;

// Access Token from Twilio
@property (nonatomic, strong) NSString *accessToken;

// Outgoing call params
@property (nonatomic, strong) NSDictionary *outgoingCallParams;

// Configure whether or not to use CallKit via the plist
// This is a variable from plugin installation (ENABLE_CALLKIT)
@property (nonatomic, assign) BOOL enableCallKit;

// Configure whether or not to mask the incoming phone number for privacy via the plist
// This is a variable from plugin installation (MASK_INCOMING_PHONE_NUMBER)
@property (nonatomic, assign) BOOL maskIncomingPhoneNumber;

// Call Kit member variables
@property (nonatomic, strong) CXProvider *callKitProvider;
@property (nonatomic, strong) CXCallController *callKitCallController;
@property (nonatomic, strong) void(^callKitCompletionCallback)(BOOL);

// Ringing Audio Player
@property (nonatomic, strong) AVAudioPlayer *ringtonePlayer;

@end

@implementation TwilioVoicePlugin

- (void) pluginInitialize {
    [super pluginInitialize];

    NSLog(@"Initializing plugin");

    // set log level for development
    [TwilioVoice setLogLevel:TVOLogLevelOff];

    // read in Enable CallKit preference
    NSString *enableCallKitPreference = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"TVPEnableCallKit"] uppercaseString];
    if ([enableCallKitPreference isEqualToString:@"YES"] || [enableCallKitPreference isEqualToString:@"TRUE"]) {
        self.enableCallKit = YES;
    } else {
        self.enableCallKit = NO;
    }

    // read in MASK_INCOMING_PHONE_NUMBER preference
    NSString *enableMaskIncomingPhoneNumberPreference = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"TVPMaskIncomingPhoneNumber"] uppercaseString];
    if ([enableMaskIncomingPhoneNumberPreference isEqualToString:@"YES"] || [enableMaskIncomingPhoneNumberPreference isEqualToString:@"TRUE"]) {
        self.maskIncomingPhoneNumber = YES;
    } else {
        self.maskIncomingPhoneNumber = NO;
    }

    if (!self.enableCallKit) {
        //ask for notification support
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        UNAuthorizationOptions options = UNAuthorizationOptionAlert + UNAuthorizationOptionSound;

        [center requestAuthorizationWithOptions:options
                              completionHandler:^(BOOL granted, NSError * _Nullable error) {
                                  if (!granted) {
                                      NSLog(@"Notifications not granted");
                                  }
                              }];

        // initialize ringtone player
        NSURL *ringtoneURL = [[NSBundle mainBundle] URLForResource:@"ringing.wav" withExtension:nil];
        if (ringtoneURL) {
            NSError *error = nil;
            self.ringtonePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:ringtoneURL error:&error];
            if (error) {
                NSLog(@"Error initializing ring tone player: %@",[error localizedDescription]);
            } else {
                //looping ring
                self.ringtonePlayer.numberOfLoops = -1;
                [self.ringtonePlayer prepareToPlay];
            }
        }
    }

}

- (void) initializeWithAccessToken:(CDVInvokedUrlCommand*)command  {
    NSLog(@"Initializing with an access token");

    // retain this command as the callback to use for raising Twilio events
    self.callback = command.callbackId;

    self.accessToken = [command.arguments objectAtIndex:0];
    if (self.accessToken) {

        // initialize VOIP Push Registry
        self.voipPushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
        self.voipPushRegistry.delegate = self;
        self.voipPushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];

        if (self.enableCallKit) {
            // initialize CallKit (based on Twilio ObjCVoiceCallKitQuickstart)
            NSString *incomingCallAppName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"TVPIncomingCallAppName"];
            CXProviderConfiguration *configuration = [[CXProviderConfiguration alloc] initWithLocalizedName:incomingCallAppName];
            configuration.maximumCallGroups = 1;
            configuration.maximumCallsPerCallGroup = 1;
            UIImage *callkitIcon = [UIImage imageNamed:@"logo.png"];
            configuration.iconTemplateImageData = UIImagePNGRepresentation(callkitIcon);
            configuration.ringtoneSound = @"traditionalring.mp3";

            self.callKitProvider = [[CXProvider alloc] initWithConfiguration:configuration];
            [self.callKitProvider setDelegate:self queue:nil];

            self.callKitCallController = [[CXCallController alloc] init];
        }

        [self javascriptCallback:@"onclientinitialized"];
    }

}

- (void) call:(CDVInvokedUrlCommand*)command {
    if ([command.arguments count] > 0) {
        self.accessToken = command.arguments[0];
        if ([command.arguments count] > 1) {
            self.outgoingCallParams = command.arguments[1];
        }

        if (self.enableCallKit) {
            NSUUID *uuid = [NSUUID UUID];
            NSString *incomingCallAppName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"TVPIncomingCallAppName"];
            [self performStartCallActionWithUUID:uuid handle:incomingCallAppName];
        } else {
            NSLog(@"Making call to with params %@", self.outgoingCallParams);
            self.call = [TwilioVoice call:self.accessToken
                                     params:(self.outgoingCallParams != nil ? self.outgoingCallParams : @{})
                                     delegate:self];
            self.outgoingCallParams = nil;
        }
    }
}

- (void) sendDigits:(CDVInvokedUrlCommand*)command {
    if ([command.arguments count] > 0) {
        [self.call sendDigits:command.arguments[0]];
    }
}

- (void) disconnect:(CDVInvokedUrlCommand*)command {
    if (self.callInvite && self.callInvite.state == TVOCallInviteStatePending) {
        [self.callInvite reject];
        self.callInvite = nil;
    }
    self.callInvite = nil;
    if (self.call) {
        [self.call disconnect];
        self.call = nil;
    }
    if ([self.ringtonePlayer isPlaying]) {
        //pause ringtone
        [self.ringtonePlayer pause];
    }
}

- (void) acceptCallInvite:(CDVInvokedUrlCommand*)command {
    if (self.callInvite) {
        [self.callInvite acceptWithDelegate:self];
    }
    if ([self.ringtonePlayer isPlaying]) {
        //pause ringtone
        [self.ringtonePlayer pause];
    }
}

- (void) rejectCallInvite: (CDVInvokedUrlCommand*)command {
    if (self.callInvite) {
        [self.callInvite reject];
    }
    if ([self.ringtonePlayer isPlaying]) {
        //pause ringtone
        [self.ringtonePlayer pause];
    }
}

#pragma mark - AVAudioSession
- (void)toggleAudioRoute:(BOOL)toSpeaker {
    // The mode set by the Voice SDK is "VoiceChat" so the default audio route is the built-in receiver. Use port override to switch the route.
    NSError *error = nil;
    if (toSpeaker) {
        if (![[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error]) {
            NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
        }
    } else {
        if (![[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error]) {
            NSLog(@"Unable to reroute audio: %@", [error localizedDescription]);
        }
    }
}

-(void)setSpeaker:(CDVInvokedUrlCommand*)command {
    NSString *mode = [command.arguments objectAtIndex:0];
    if([mode isEqual: @"on"]) {
        [self toggleAudioRoute:YES];
    }
    else {
        [self toggleAudioRoute:NO];
    }
}

- (void) muteCall: (CDVInvokedUrlCommand*)command {
    if (self.call) {
        self.call.muted = YES;
    }
}

- (void) unmuteCall: (CDVInvokedUrlCommand*)command {
    if (self.call) {
        self.call.muted = NO;
    }
}

- (void) turnRingerOn: (CDVInvokedUrlCommand*)command {
    [self.ringtonePlayer play];
}

- (void) turnRingerOff: (CDVInvokedUrlCommand*)command {
  if ([self.ringtonePlayer isPlaying]) {
      //pause ringtone
      [self.ringtonePlayer pause];
  }
}

- (void) isCallMuted: (CDVInvokedUrlCommand*)command {
    if (self.call) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:self.call.muted];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    } else {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:NO];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }
}

#pragma mark PKPushRegistryDelegate methods
- (void)pushRegistry:(PKPushRegistry *)registry didUpdatePushCredentials:(PKPushCredentials *)credentials forType:(PKPushType)type {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        self.pushDeviceToken = [credentials.token description];
        NSLog(@"Updating push device token for VOIP: %@",self.pushDeviceToken);
        [TwilioVoice registerWithAccessToken:self.accessToken
                                                  deviceToken:self.pushDeviceToken completion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error registering Voice Client for VOIP Push: %@", [error localizedDescription]);
            } else {
                NSLog(@"Registered Voice Client for VOIP Push");
            }
        }];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didInvalidatePushTokenForType:(PKPushType)type {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        NSLog(@"Invalidating push device token for VOIP: %@",self.pushDeviceToken);
        [TwilioVoice unregisterWithAccessToken:self.accessToken
                                                    deviceToken:self.pushDeviceToken completion:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error unregistering Voice Client for VOIP Push: %@", [error localizedDescription]);
            } else {
                NSLog(@"Unegistered Voice Client for VOIP Push");
            }
            self.pushDeviceToken = nil;
        }];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry didReceiveIncomingPushWithPayload:(PKPushPayload *)payload forType:(PKPushType)type {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        NSLog(@"Received Incoming Push Payload for VOIP: %@",payload.dictionaryPayload);
        [TwilioVoice handleNotification:payload.dictionaryPayload delegate:self];
    }
}

#pragma mark TVONotificationDelegate
- (void)callInviteReceived:(TVOCallInvite *)callInvite {
    if (callInvite.state == TVOCallInviteStatePending) {
        [self handleCallInviteReceived:callInvite];
    } else if (callInvite.state == TVOCallInviteStateCanceled) {
        [self handleCallInviteCanceled:callInvite];
    }
}

- (void)handleCallInviteReceived:(TVOCallInvite *)callInvite {
    NSLog(@"Call Invite Received: %@", callInvite.uuid);
    // Two simlutaneous callInvites or calls are not supported by Twilio and cause an error
    // if the user attempts to answer the second call invite through CallKit.
    // Rather than surface the second invite, just reject it which will most likely
    // result in the second invite going to voicemail
    if (self.callInvite == nil && self.call == nil) {
        self.callInvite = callInvite;
        NSDictionary *callInviteProperties = @{
                                               @"from":callInvite.from,
                                               @"to":callInvite.to,
                                               @"callSid":callInvite.callSid,
                                               @"state":[self stringFromCallInviteState:callInvite.state]
                                               };
        if (self.enableCallKit) {
            [self reportIncomingCallFrom:(self.maskIncomingPhoneNumber ? @"Unknown" : callInvite.from) withUUID:callInvite.uuid];
        } else {
            [self showNotification:(self.maskIncomingPhoneNumber ? @"Unknown" : callInvite.from)];
            //play ringtone
            [self.ringtonePlayer play];
        }

        [self javascriptCallback:@"oncallinvitereceived" withArguments:callInviteProperties];
    } else {
        [callInvite reject];
        NSLog(@"Call Invite Received During Call. Rejecting: %@", callInvite.uuid);
    }
}

- (void)handleCallInviteCanceled:(TVOCallInvite *)callInvite {
    NSLog(@"Call Invite Cancelled: %@", callInvite.uuid);
    if (self.enableCallKit) {
        [self performEndCallActionWithUUID:callInvite.uuid];
    } else {
        [self cancelNotification];
        //pause ringtone
        [self.ringtonePlayer pause];
    }
    self.callInvite = nil;
    [self javascriptCallback:@"oncallinvitecanceled"];
}

- (void)notificationError:(NSError *)error {
    NSLog(@"Twilio Voice Notification Error: %@", [error localizedDescription]);
    [self javascriptErrorback:error];
}

#pragma mark TVOCallDelegate

- (void)callDidConnect:(TVOCall *)call {
    NSLog(@"Call Did Connect: %@", [call description]);
    if ([self.ringtonePlayer isPlaying]) {
        //pause ringtone
        [self.ringtonePlayer pause];
    }
    self.call = call;

    if (!self.enableCallKit) {
        [self cancelNotification];
        if ([self.ringtonePlayer isPlaying]) {
            //pause ringtone
            [self.ringtonePlayer pause];
        }
    } else {
        self.callKitCompletionCallback(YES);
        self.callKitCompletionCallback = nil;
    }

    NSMutableDictionary *callProperties = [NSMutableDictionary new];
    if (call.from) {
        callProperties[@"from"] = call.from;
    }
    if (call.to) {
        callProperties[@"to"] = call.to;
    }
    if (call.sid) {
        callProperties[@"callSid"] = call.sid;
    }
    callProperties[@"isMuted"] = [NSNumber numberWithBool:call.isMuted];
    NSString *callState = [self stringFromCallState:call.state];
    if (callState) {
        callProperties[@"state"] = callState;
    }
    self.callInvite = nil;
    [self javascriptCallback:@"oncalldidconnect" withArguments:callProperties];
}

- (void)call:(TVOCall *)call didFailToConnectWithError:(NSError *)error {
    NSLog(@"Call Did Fail with Error: %@, %@", [call description], [error localizedDescription]);
    if (self.enableCallKit) {
        self.callKitCompletionCallback(NO);
    }
    [self callDisconnected:call];
    [self javascriptErrorback:error];
}

- (void)call:(TVOCall *)call didDisconnectWithError:(NSError *)error {
    if (error) {
        NSLog(@"Call failed: %@", error);
        [self javascriptErrorback:error];
    } else {
        NSLog(@"Call disconnected");
    }

    [self callDisconnected:call];
}

- (void)callDisconnected:(TVOCall *)call {
    NSLog(@"Call Did Disconnect: %@", [call description]);

    // Call Kit Integration
    if (self.enableCallKit) {
        [self performEndCallActionWithUUID:call.uuid];
    }

    self.call = nil;
    self.callKitCompletionCallback = nil;
    [self javascriptCallback:@"oncalldiddisconnect"];
}

#pragma mark Conversion methods for the plugin

- (NSString*) stringFromCallInviteState:(TVOCallInviteState)state {
    if (state == TVOCallInviteStatePending) {
        return @"pending";
    } else if (state == TVOCallInviteStateAccepted) {
        return @"accepted";
    } else if (state == TVOCallInviteStateRejected) {
        return @"rejected";
    } else if (state == TVOCallInviteStateCanceled) {
        return @"cancelled";
    }

    return nil;
}

- (NSString*) stringFromCallState:(TVOCallState)state {
    if (state == TVOCallStateConnected) {
        return @"connected";
    } else if (state == TVOCallStateConnecting) {
        return @"connecting";
    } else if (state == TVOCallStateDisconnected) {
        return @"disconnected";
    }
    return nil;
}

#pragma mark Cordova Integration methods for the plugin Delegate - from TCPlugin.m/Stevie Graham

- (void) javascriptCallback:(NSString *)event withArguments:(NSDictionary *)arguments {
    NSDictionary *options   = [NSDictionary dictionaryWithObjectsAndKeys:event, @"callback", arguments, @"arguments", nil];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:options];
    [result setKeepCallbackAsBool:YES];

    [self.commandDelegate sendPluginResult:result callbackId:self.callback];
}

- (void) javascriptCallback:(NSString *)event {
    [self javascriptCallback:event withArguments:nil];
}

- (void) javascriptErrorback:(NSError *)error {
    NSDictionary *object    = [NSDictionary dictionaryWithObjectsAndKeys:[error localizedDescription], @"message", nil];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsDictionary:object];
    [result setKeepCallbackAsBool:YES];

    [self.commandDelegate sendPluginResult:result callbackId:self.callback];
}

#pragma mark - Local Notification methods used if CallKit isn't enabled

-(void) showNotification:(NSString*)alertBody {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

    [center removeAllPendingNotificationRequests];


    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.sound = [UNNotificationSound soundNamed:@"ringing.wav"];
    content.title = @"Answer";
    content.body = alertBody;


    UNNotificationRequest *request = [UNNotificationRequest
                                      requestWithIdentifier:@"IncomingCall" content:content trigger:nil];

    [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
        if (error != nil) {
            NSLog(@"Error adding local notification for incoming call: %@", error.localizedDescription);
        }
    }];

}

-(void) cancelNotification {
    [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
}

#pragma mark - CXProviderDelegate - based on Twilio Voice with CallKit Quickstart ObjC

- (void)provider:(CXProvider *)provider performPlayDTMFCallAction:(CXPlayDTMFCallAction *)action {
    if (self.call) {
        NSLog(@"Sending Digits: %@", action.digits);
        [self.call sendDigits:action.digits];
    } else {
        NSLog(@"No current call");
    }

}

// All CallKit Integration Code comes from https://github.com/twilio/voice-callkit-quickstart-objc/blob/master/ObjCVoiceCallKitQuickstart/ViewController.m

- (void)providerDidReset:(CXProvider *)provider {
    NSLog(@"providerDidReset:");
    TwilioVoice.audioEnabled = YES;
}

- (void)providerDidBegin:(CXProvider *)provider {
    NSLog(@"providerDidBegin:");
}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    NSLog(@"provider:didActivateAudioSession:");
    TwilioVoice.audioEnabled = YES;
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    NSLog(@"provider:didDeactivateAudioSession:");
    TwilioVoice.audioEnabled = NO;
}

- (void)provider:(CXProvider *)provider timedOutPerformingAction:(CXAction *)action {
    NSLog(@"provider:timedOutPerformingAction:");
}


- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
    NSLog(@"provider:performStartCallAction:");

    [TwilioVoice configureAudioSession];
    TwilioVoice.audioEnabled = NO;

    [self.callKitProvider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:[NSDate date]];

    TwilioVoicePlugin __weak *weakSelf = self;
    [self performVoiceCallWithUUID:action.callUUID client:nil completion:^(BOOL success) {
        TwilioVoicePlugin __strong *strongSelf = weakSelf;
        if (success) {
            [strongSelf.callKitProvider reportOutgoingCallWithUUID:action.callUUID connectedAtDate:[NSDate date]];
            [action fulfill];
        } else {
            [action fail];
        }
    }];
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    NSLog(@"provider:performAnswerCallAction:");

    // RCP: Workaround from https://forums.developer.apple.com/message/169511 suggests configuring audio in the
    //      completion block of the `reportNewIncomingCallWithUUID:update:completion:` method instead of in
    //      `provider:performAnswerCallAction:` per the WWDC examples.
    // [[TwilioVoice sharedInstance] configureAudioSession];

    NSAssert([self.callInvite.uuid isEqual:action.callUUID], @"We only support one Invite at a time.");

    TwilioVoice.audioEnabled = NO;
    [self performAnswerVoiceCallWithUUID:action.callUUID completion:^(BOOL success) {
        if (success) {
            [action fulfill];
        } else {
            [action fail];
        }
    }];

    [action fulfill];
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    NSLog(@"provider:performEndCallAction:");

    if (self.callInvite && self.callInvite.state == TVOCallInviteStatePending) {
        [self.callInvite reject];
        self.callInvite = nil;
        [self javascriptCallback:@"oncallinvitecanceled"];
    } else if (self.call) {
        [self.call disconnect];
    }

    [action fulfill];
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action {
    if (self.call && self.call.state == TVOCallStateConnected) {
        [self.call setOnHold:action.isOnHold];
        [action fulfill];
    } else {
        [action fail];
    }
}

#pragma mark - CallKit Actions
- (void)performStartCallActionWithUUID:(NSUUID *)uuid handle:(NSString *)handle {
    if (uuid == nil || handle == nil) {
        return;
    }

    CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:handle];
    CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:callHandle];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:startCallAction];

    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"StartCallAction transaction request failed: %@", [error localizedDescription]);
        } else {
            NSLog(@"StartCallAction transaction request successful");

            CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
            callUpdate.remoteHandle = callHandle;
            callUpdate.supportsDTMF = YES;
            callUpdate.supportsHolding = YES;
            callUpdate.supportsGrouping = NO;
            callUpdate.supportsUngrouping = NO;
            callUpdate.hasVideo = NO;

            [self.callKitProvider reportCallWithUUID:uuid updated:callUpdate];
        }
    }];
}

- (void)reportIncomingCallFrom:(NSString *) from withUUID:(NSUUID *)uuid {
    CXHandle *callHandle = [[CXHandle alloc] initWithType:CXHandleTypeGeneric value:from];

    CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
    callUpdate.remoteHandle = callHandle;
    callUpdate.supportsDTMF = YES;
    callUpdate.supportsHolding = YES;
    callUpdate.supportsGrouping = NO;
    callUpdate.supportsUngrouping = NO;
    callUpdate.hasVideo = NO;

    [self.callKitProvider reportNewIncomingCallWithUUID:uuid update:callUpdate completion:^(NSError *error) {
        if (!error) {
            NSLog(@"Incoming call successfully reported.");

            // RCP: Workaround per https://forums.developer.apple.com/message/169511
            [TwilioVoice configureAudioSession];
        }
        else {
            NSLog(@"Failed to report incoming call successfully: %@.", [error localizedDescription]);
        }
    }];
}

- (void)performEndCallActionWithUUID:(NSUUID *)uuid {
    if (uuid == nil) {
        return;
    }

    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];

    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"EndCallAction transaction request failed: %@", [error localizedDescription]);
        }
        else {
            NSLog(@"EndCallAction transaction request successful");
        }
    }];
}

- (void)performVoiceCallWithUUID:(NSUUID *)uuid
                          client:(NSString *)client
                      completion:(void(^)(BOOL success))completionHandler {

    self.call = [TwilioVoice call:self.accessToken
                           params:(self.outgoingCallParams != nil ? self.outgoingCallParams : @{})
                             uuid:uuid
                         delegate:self];
    self.outgoingCallParams = nil;
    self.callKitCompletionCallback = completionHandler;
}

- (void)performAnswerVoiceCallWithUUID:(NSUUID *)uuid
                            completion:(void(^)(BOOL success))completionHandler {

    self.call = [self.callInvite acceptWithDelegate:self];
    self.callInvite = nil;
    self.callKitCompletionCallback = completionHandler;
}

@end
