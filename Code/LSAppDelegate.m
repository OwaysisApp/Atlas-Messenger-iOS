//
//  LSAppDelegate.m
//  LayerSample
//
//  Created by Kevin Coleman on 6/10/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//

#import <LayerKit/LayerKit.h>
#import <Fabric/Fabric.h>
#import <Crashlytics/Crashlytics.h>
#import <HockeySDK/HockeySDK.h>
#import <LayerUIKit/LayerUIKit.h>
#import <MessageUI/MessageUI.h>
#import <sys/sysctl.h>
#import <asl.h>
#import "LSAppDelegate.h"
#import "LSConversationListViewController.h"
#import "LSAPIManager.h"
#import "LSUtilities.h"
#import "LYRUIConstants.h"
#import "LSAuthenticationViewController.h"
#import "LSSplashView.h"
#import "LSLocalNotificationManager.h"
#import "SVProgressHUD.h" 

extern void LYRSetLogLevelFromEnvironment();
extern dispatch_once_t LYRConfigurationURLOnceToken;
static NSString *const LSAppDidReceiveShakeMotionNotification = @"LSAppDidReceiveShakeMotionNotification";

void LSTestResetConfiguration(void)
{
    extern dispatch_once_t LYRDefaultConfigurationDispatchOnceToken;
    
    NSString *archivePath = [LSApplicationDataDirectory() stringByAppendingPathComponent:@"LayerConfiguration.plist"];
    [[NSFileManager defaultManager] removeItemAtPath:archivePath error:nil];
    
    // Ensure the next call through `LYRDefaultConfiguration` will reload
    LYRDefaultConfigurationDispatchOnceToken = 0;
    LYRConfigurationURLOnceToken = 0;
}

LSEnvironment LSEnvironmentConfiguration(void)
{
    if (LSIsRunningTests()){
        return LSLoadTestEnvironment;
    } else {
        return LSProductionEnvironment;
    }
}

@interface LSShakableWindow : UIWindow

@end

@implementation LSShakableWindow

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake) {
        [[NSNotificationCenter defaultCenter] postNotificationName:LSAppDidReceiveShakeMotionNotification object:event];
    }
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

@end

@interface LSAppDelegate () <LSAuthenticationViewControllerDelegate, MFMailComposeViewControllerDelegate>

@property (nonatomic) LSAuthenticationViewController *authenticationViewController;
@property (nonatomic) LSConversationListViewController *conversationListViewController;
@property (nonatomic) LSSplashView *splashView;
@property (nonatomic) LSEnvironment environment;
@property (nonatomic) LSLocalNotificationManager *localNotificationManager;

@end

@implementation LSAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Enable debug shaking
    application.applicationSupportsShakeToEdit = YES;
    
    // Set up environment configuration
    [self configureApplication:application forEnvironment:LSEnvironmentConfiguration()];
    [self initializeCrashlytics];
    [self initializeHockeyApp];
    [self removeSplashView];
    
    // Set up window
    [self configureWindow];
    
    // Configure sample app UI appearance
    [self configureGlobalUserInterfaceAttributes];
    
    // Setup notifications
    [self registerNotificationObservers];
    
    // Conversation list view controller config
    _cellClass = [LYRUIConversationTableViewCell class];
    _rowHeight = 72;
    _allowsEditing = YES;
    _displaysConversationImage = NO;
    _displaysSettingsButton = YES;
    
    // Connect to Layer and boot the UI
    BOOL deauthenticateAfterConnection = NO;
    BOOL resumingSession = NO;
    if (self.applicationController.layerClient.authenticatedUserID) {
        if ([self resumeSession]) {
            resumingSession = YES;
            [self presentConversationsListViewController:NO];
        } else {
            deauthenticateAfterConnection = YES;
        }
    }
    
    // Connect Layer SDK
    [self.applicationController.layerClient connectWithCompletion:^(BOOL success, NSError *error) {
        if (success) {
            NSLog(@"Layer Client is connected");
            if (deauthenticateAfterConnection) {
                [self.applicationController.layerClient deauthenticateWithCompletion:nil];
            }
        } else {
            NSLog(@"Error connecting Layer: %@", error);
        }
        if (!resumingSession) {
            [self removeSplashView];
        }
    }];
    
    [self registerForRemoteNotifications:application];
    
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [self resumeSession];
    [self loadContacts];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    [self setApplicationBadgeNumber];
}

#pragma mark - Setup

- (void)configureApplication:(UIApplication *)application forEnvironment:(LSEnvironment)environment
{
    self.environment = environment;
    
    // Configure Layer base URL
    NSString *configURLString = LSLayerConfigurationURL(self.environment);
    NSString *configKey = LSUserDefaultsLayerConfigurationURLKey;
    NSString *currentConfigURL = [[NSUserDefaults standardUserDefaults] objectForKey:configKey];
    if (![currentConfigURL isEqualToString:configURLString]) {
        [[NSUserDefaults standardUserDefaults] setObject:LSLayerConfigurationURL(self.environment) forKey:configKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    LSTestResetConfiguration();
    LYRSetLogLevelFromEnvironment();
    
    // Configure application controllers
    LSLayerClient *client = [LSLayerClient clientWithAppID:LSLayerAppID(self.environment)];
    
    self.applicationController = [LSApplicationController controllerWithBaseURL:LSRailsBaseURL()
                                                                    layerClient:client
                                                             persistenceManager:LSPersitenceManager()];
    
    self.localNotificationManager = [LSLocalNotificationManager new];
    self.authenticationViewController.applicationController = self.applicationController;
}

- (BOOL)resumeSession
{
    LSSession *session = [self.applicationController.persistenceManager persistedSessionWithError:nil];
    if ([self.applicationController.APIManager resumeSession:session error:nil]) {
        return YES;
    }
    return NO;
}

- (void)configureWindow
{
    self.authenticationViewController = [LSAuthenticationViewController new];
    self.authenticationViewController.applicationController = self.applicationController;
    self.authenticationViewController.delegate = self;
    
    self.window = [[LSShakableWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = self.authenticationViewController;
    [self.window makeKeyAndVisible];
    
    [self addSplashView];
}

- (void)registerNotificationObservers
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(userDidAuthenticate:)
                                                 name:LSUserDidAuthenticateNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter]  addObserver:self
                                              selector:@selector(userDidAuthenticateWithLayer:)
                                                  name:LYRClientDidAuthenticateNotification
                                                object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(userDidDeauthenticate:)
                                                 name:LSUserDidDeauthenticateNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(userDidTakeScreenshot:)
                                                 name:UIApplicationUserDidTakeScreenshotNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidReceiveShakeMotion:)
                                                 name:LSAppDidReceiveShakeMotionNotification
                                               object:nil];
}

#pragma mark - Push Notifications

- (void)registerForRemoteNotifications:(UIApplication *)application
{
    // Registers for push on iOS 7 and iOS 8
    if ([application respondsToSelector:@selector(registerForRemoteNotifications)]) {
        UIUserNotificationSettings *notificationSettings = [UIUserNotificationSettings settingsForTypes:UIUserNotificationTypeAlert | UIUserNotificationTypeBadge | UIUserNotificationTypeSound categories:nil];
        [application registerUserNotificationSettings:notificationSettings];
        [application registerForRemoteNotifications];
    } else {
        [application registerForRemoteNotificationTypes:UIRemoteNotificationTypeAlert | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeBadge];
    }
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    NSLog(@"Application failed to register for remote notifications with error %@", error);
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    self.applicationController.deviceToken = deviceToken;
    NSError *error;
    BOOL success = [self.applicationController.layerClient updateRemoteNotificationDeviceToken:deviceToken error:&error];
    if (success) {
        NSLog(@"Application did register for remote notifications");
    } else {
        NSLog(@"Error updating Layer device token for push:%@", error);
        UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Updating Device Token Failed" message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alertView show];
    }
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    BOOL userTappedRemoteNotification = application.applicationState == UIApplicationStateInactive;
    __block LYRConversation *conversation = [self conversationFromRemoteNotification:userInfo];
    if (userTappedRemoteNotification && conversation) {
        [self navigateToViewForConversation:conversation];
    } else if (userTappedRemoteNotification) {
        [SVProgressHUD showWithStatus:@"Loading Conversation" maskType:SVProgressHUDMaskTypeBlack];
    }
    NSLog(@"Received Push...processing");
    BOOL success = [self.applicationController.layerClient synchronizeWithRemoteNotification:userInfo completion:^(NSArray *changes, NSError *error) {
        NSLog(@"Finished processing push with %lu changes", (unsigned long)changes.count);
        [self setApplicationBadgeNumber];
        if (changes.count) {
            [self processLayerBackgroundChanges:changes];
            completionHandler(UIBackgroundFetchResultNewData);
        } else {
            completionHandler(error ? UIBackgroundFetchResultFailed : UIBackgroundFetchResultNoData);
        }
        if (error) {
            NSLog(@"Background sync failed with error %@", error);
        }
        
        // Try navigating once the synchronization completed
        if (userTappedRemoteNotification && !conversation) {
            [SVProgressHUD dismiss];
            conversation = [self conversationFromRemoteNotification:userInfo];
            [self navigateToViewForConversation:conversation];
        }
    }];
    
    if (!success) {
        completionHandler(UIBackgroundFetchResultNoData);
    }
}

- (void)processLayerBackgroundChanges:(NSArray *)changes
{
    if (self.applicationController.shouldDisplayLocalNotifications) {
        [self.localNotificationManager processLayerChanges:changes];
    }
}

- (LYRConversation *)conversationFromRemoteNotification:(NSDictionary *)remoteNotification
{
    NSURL *conversationIdentifier = [NSURL URLWithString:[remoteNotification valueForKeyPath:@"layer.conversation_identifier"]];
    return [self.applicationController.layerClient conversationForIdentifier:conversationIdentifier];
}

- (void)navigateToViewForConversation:(LYRConversation *)conversation
{
    if (![NSThread isMainThread]) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Attempted to navigate UI from non-main thread" userInfo:nil];
    }
    [self.conversationListViewController selectConversation:conversation];
}

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification
{
    if (application.applicationState != UIApplicationStateInactive) return;

    LYRConversation *conversation;
    NSURL *objectURL = [NSURL URLWithString:notification.userInfo[LSNotificationIdentifierKey]];
    NSString *objectTypeString = notification.userInfo[LSNotificationClassTypeKey];
    if ([objectTypeString isEqualToString:LSNotificationClassTypeConversation]) {
        conversation = [self.applicationController.layerClient conversationForIdentifier:objectURL];
    } else {
        LYRMessage *message = [self.applicationController.layerClient messageForIdentifier:objectURL];
        conversation = message.conversation;
    }

    if (conversation) {
        [self navigateToViewForConversation:conversation];
    }
}

#pragma mark - SDK Initializers

- (void)initializeCrashlytics
{
    [Fabric with:@[CrashlyticsKit]];
    [Crashlytics setObjectValue:LSLayerConfigurationURL(self.environment) forKey:@"ConfigurationURL"];
    [Crashlytics setObjectValue:LSLayerAppID(self.environment) forKey:@"AppID"];
}

- (void)initializeHockeyApp
{
    [[BITHockeyManager sharedHockeyManager] configureWithIdentifier:@"1681559bb4230a669d8b057adf8e4ae3"];
    [BITHockeyManager sharedHockeyManager].disableCrashManager = YES;
    [[BITHockeyManager sharedHockeyManager] startManager];
    [[BITHockeyManager sharedHockeyManager].authenticator authenticateInstallation];
}

- (void)updateCrashlyticsWithUser:(LSUser *)authenticatedUser
{
    // Note: If authenticatedUser is nil, this will nil out everything which is what we want.
    [Crashlytics setUserName:authenticatedUser.fullName];
    [Crashlytics setUserEmail:authenticatedUser.email];
    [Crashlytics setUserIdentifier:authenticatedUser.userID];
}

#pragma mark - Authentication Notification Handlers

- (void)userDidAuthenticateWithLayer:(NSNotification *)notification
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self userDidAuthenticateWithLayer:notification];
        });
        return;
    }
    [self presentConversationsListViewController:YES];
}

- (void)userDidAuthenticate:(NSNotification *)notification
{
    NSError *error;
    LSSession *session = self.applicationController.APIManager.authenticatedSession;
    BOOL success = [self.applicationController.persistenceManager persistSession:session error:&error];
    if (success) {
        NSLog(@"Persisted authenticated user session: %@", session);
    } else {
        NSLog(@"Failed persisting authenticated user: %@. Error: %@", session, error);
        if (self.applicationController.debugModeEnabled) {
            LSAlertWithError(error);
        }
    }
    
    [self updateCrashlyticsWithUser:session.user];
    [self loadContacts];
}

- (void)userDidDeauthenticate:(NSNotification *)notification
{
    NSError *error;
    BOOL success = [self.applicationController.persistenceManager persistSession:nil error:&error];
    
    // Clear out all Crashlytics user information.
    [self updateCrashlyticsWithUser:nil];
    
    if (success) {
        NSLog(@"Cleared persisted user session");
    } else {
        NSLog(@"Failed clearing persistent user session: %@", error);
        if (self.applicationController.debugModeEnabled) {
            LSAlertWithError(error);
        }
    }
    
    [self.authenticationViewController dismissViewControllerAnimated:YES completion:^{
        self.conversationListViewController = nil;
    }];
}

#pragma mark - Contacts

- (void)loadContacts
{
    [self.applicationController.APIManager loadContactsWithCompletion:^(NSSet *contacts, NSError *error) {
        if (error) {
            if (self.applicationController.debugModeEnabled) {
                LSAlertWithError(error);
            }
            return;
        }
        
        NSError *persistenceError;
        BOOL success = [self.applicationController.persistenceManager persistUsers:contacts error:&persistenceError];
        if (!success && self.applicationController.debugModeEnabled) {
            LSAlertWithError(persistenceError);
        }
    }];
}

#pragma mark - Conversations

- (void)presentConversationsListViewController:(BOOL)animated
{
    if (self.conversationListViewController) return;
    
    self.conversationListViewController = [LSConversationListViewController conversationListViewControllerWithLayerClient:self.applicationController.layerClient];
    self.conversationListViewController.applicationController = self.applicationController;
    self.conversationListViewController.displaysConversationImage = self.displaysConversationImage;
    self.conversationListViewController.cellClass = self.cellClass;
    self.conversationListViewController.rowHeight = self.rowHeight;
    self.conversationListViewController.allowsEditing = self.allowsEditing;
    self.conversationListViewController.shouldDisplaySettingsItem = self.displaysSettingsButton;
    
    UINavigationController *authenticatedNavigationController = [[UINavigationController alloc] initWithRootViewController:self.conversationListViewController];
    [self.authenticationViewController presentViewController:authenticatedNavigationController animated:YES completion:^{
        [self.authenticationViewController resetState];
        [self removeSplashView];
    }];
}

#pragma mark - Splash View

- (void)addSplashView
{
    if (!self.splashView) {
        self.splashView = [[LSSplashView alloc] initWithFrame:self.window.bounds];
    }
    [self.window addSubview:self.splashView];
}

- (void)removeSplashView
{
    [UIView animateWithDuration:0.5 animations:^{
        self.splashView.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self.splashView removeFromSuperview];
        self.splashView = nil;
    }];
}

#pragma mark - UI Config

- (void)configureGlobalUserInterfaceAttributes
{
    [[UINavigationBar appearance] setTintColor:LYRUIBlueColor()];
    [[UINavigationBar appearance] setBarTintColor:LYRUILightGrayColor()];
    [[UINavigationBar appearance] setTitleTextAttributes:@{NSFontAttributeName: LYRUIBoldFont(18)}];
    
    [[UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil] setTitleTextAttributes:@{NSFontAttributeName : LYRUIMediumFont(16)} forState:UIControlStateNormal];
    [[UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil] setTintColor:LYRUIBlueColor()];
}

#pragma mark - Bug Reporting

- (void)appDidReceiveShakeMotion:(NSNotification *)notification
{
    NSLog(@"Receive Shake Event: Dumping LayerKit Diagnostics:\n%@", [self.applicationController.layerClient valueForKey:@"diagnosticDescription"]);
}

- (void)userDidTakeScreenshot:(NSNotification *)notification
{
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Report Issue?"
                                                        message:@"Would you like to report a bug with the sample app?"
                                                       delegate:self
                                              cancelButtonTitle:@"Not Now"
                                              otherButtonTitles:@"Yes", nil];
    [alertView show];
}

- (void)presentBugReportMailComposer
{
    LYRUILastPhotoTaken(^(UIImage *image, NSError *error) {
        NSString *appVersion = [self bugReportAppVersion];
        NSString *layerKitVersion = [self bugReportLayerKitVersion];
        NSData *consoleData = [self bugReportConsoleData];
        NSString *deviceVersion = [self bugReportDeviceVersion];
        NSString *environmentName = [LSApplicationController layerServerHostname];
        NSString *timestamp = [self bugReportTimeStamp];
        NSString *email = [self bugReportEmail];
        NSString *platformWithOSVersion = [NSString stringWithFormat:@"iOS %@", [UIDevice currentDevice].systemVersion];
        NSString *userID = self.applicationController.layerClient.authenticatedUserID ?: @"None";
        NSString *deviceToken = self.applicationController.deviceToken.description ?: @"None";

        NSString *emailBody = [NSString stringWithFormat:@"email: %@\ntime: %@\nplatform: %@\ndevice: %@\napp: %@\nsdk: %@\nenv: %@\nuserid: %@\ndevice token: %@", email, timestamp, platformWithOSVersion, deviceVersion, appVersion, layerKitVersion, environmentName, userID, deviceToken];
        
        MFMailComposeViewController *mailComposeViewController = [MFMailComposeViewController new];
        mailComposeViewController.mailComposeDelegate = self;
        [mailComposeViewController setMessageBody:emailBody isHTML:NO];
        [mailComposeViewController setToRecipients:@[@"kevin@layer.com", @"jira@layer.com"]];
        if (!error) {
            [mailComposeViewController addAttachmentData:UIImageJPEGRepresentation(image, 0.5) mimeType:@"image/jpeg" fileName:@"screenshot.jpg"];
        }
        [mailComposeViewController addAttachmentData:consoleData mimeType:@"text/plain" fileName:@"console.log"];

        UIViewController *controller = self.window.rootViewController;
        while (controller.presentedViewController) {
            controller = controller.presentedViewController;
        }
        [controller presentViewController:mailComposeViewController animated:YES completion:nil];
    });
}

- (NSData *)bugReportConsoleData
{
    // Adopted from http://stackoverflow.com/a/7151773
    NSMutableString *consoleLog = [NSMutableString new];
    aslclient client = asl_open(NULL, NULL, ASL_OPT_STDERR);

    aslmsg query = asl_new(ASL_TYPE_QUERY);
    asl_set_query(query, ASL_KEY_MSG, NULL, ASL_QUERY_OP_NOT_EQUAL);
    aslresponse response = asl_search(client, query);
    asl_free(query);

    aslmsg message;
    // We're using aslresponse_next here even though it's deprecated because asl_next causes a crash on iOS 7.1 despite the documentation saying it is available.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    while((message = aslresponse_next(response))) {
#pragma GCC diagnostic pop
        const char *msg = asl_get(message, ASL_KEY_MSG);
        if (consoleLog.length > 0) {
            [consoleLog appendString:@"\n"];
        }
        [consoleLog appendString:[NSString stringWithCString:msg encoding:NSUTF8StringEncoding]];
    }

    // We're using aslresponse_free here even though it's deprecated because asl_release causes a crash on iOS 7.1 despite the documentation saying it is available.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    aslresponse_free(response);
#pragma GCC diagnostic pop
    asl_close(client);

    NSData *consoleData = [consoleLog dataUsingEncoding:NSUTF8StringEncoding];
    return consoleData;
}

- (NSString *)bugReportAppVersion
{
    NSDictionary *infoDictionary = [NSBundle mainBundle].infoDictionary;
    NSString *appVersion = [NSString stringWithFormat:@"LayerSample v%@ (%@)", infoDictionary[@"CFBundleShortVersionString"], infoDictionary[@"CFBundleVersion"]];
    return appVersion;
}

- (NSString *)bugReportLayerKitVersion
{
    NSDictionary *infoDictionary = [NSBundle mainBundle].infoDictionary;
    NSDictionary *layerKitBuildInformation = infoDictionary[@"LYRBuildInformation"];
    NSString *layerKitVersion = [NSString stringWithFormat:@"LayerKit v%@", layerKitBuildInformation[@"LYRBuildLayerKitVersion"]];
    return layerKitVersion;
}

- (NSString *)bugReportDeviceVersion
{
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *deviceVersion = @(machine);
    free(machine);
    return deviceVersion;
}

- (NSString *)bugReportTimeStamp
{
    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    dateFormatter.dateStyle = NSDateFormatterShortStyle;
    dateFormatter.timeStyle = NSDateFormatterLongStyle;
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    return timestamp;
}

- (NSString *)bugReportEmail
{
    NSString *authenticatedUserID = self.applicationController.layerClient.authenticatedUserID;
    if (authenticatedUserID) {
        LSUser *user = [self.applicationController.persistenceManager userForIdentifier:authenticatedUserID];
        if (user) {
            return user.email;
        }
    }
    return @"";
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.firstOtherButtonIndex) {
        [self presentBugReportMailComposer];
    }
}

#pragma mark - MFMailComposeViewControllerDelegate

- (void)mailComposeController:(MFMailComposeViewController *)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError *)error
{
    switch (result) {
        case MFMailComposeResultSaved:
            [SVProgressHUD showSuccessWithStatus:@"Email Saved"];
            break;
        case MFMailComposeResultSent:
            [SVProgressHUD showSuccessWithStatus:@"Email Sent! Now go tell Kevin or Ben to fix it!"];
            break;
        case MFMailComposeResultFailed:
            [SVProgressHUD showSuccessWithStatus:[NSString stringWithFormat:@"Email Failed to Send. Error: %@", error]];
            break;
        default:
            break;
    }
    [controller dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - LSAuthenticationViewControllerDelegate

- (void)authenticationViewController:(LSAuthenticationViewController *)authenticationViewController didSelectEnvironment:(LSEnvironment)environment
{
    if (self.applicationController.layerClient.isConnected) {
        [self.applicationController.layerClient disconnect];
    }
    [self configureApplication:[UIApplication sharedApplication] forEnvironment:environment];
    [SVProgressHUD showSuccessWithStatus:@"New Environment Configured"];
}

#pragma mark - Application Badge Setter

- (void)setApplicationBadgeNumber
{
    NSUInteger countOfUnreadMessages = [self.applicationController.layerClient countOfUnreadMessages];
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:countOfUnreadMessages];
}

@end
