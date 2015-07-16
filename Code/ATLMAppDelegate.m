//
//  ATLMAppDelegate.m
//  Atlas Messenger
//
//  Created by Kevin Coleman on 6/10/14.
//  Copyright (c) 2014 Layer, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <LayerKit/LayerKit.h>
#import <Atlas/Atlas.h>
#import <MessageUI/MessageUI.h>
#import <sys/sysctl.h>
#import <asl.h>

#import "ATLMAppDelegate.h"
#import "ATLMNavigationController.h"
#import "ATLMConversationListViewController.h"
#import "ATLMSplashView.h"
#import "SVProgressHUD.h"
#import "ATLMQRScannerController.h"
#import "ATLMUtilities.h"

// TODO: Configure a Layer appID from https://developer.layer.com/dashboard/atlas/build
static NSString *const ATLMLayerAppID = @"layer:///apps/staging/6a30cde0-2a69-11e5-a665-09c843001987";

@interface ATLMAppDelegate () <MFMailComposeViewControllerDelegate>

@property (nonatomic) ATLMQRScannerController *scannerController;
@property (nonatomic) UINavigationController *navigationController;
@property (nonatomic) ATLMConversationListViewController *conversationListViewController;
@property (nonatomic) ATLMSplashView *splashView;
@property (nonatomic) ATLMLayerClient *layerClient;

@end

@implementation ATLMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.applicationController = [ATLMApplicationController controllerWithPersistenceManager:[ATLMPersistenceManager defaultManager]];
    
    // Set up window
    [self configureWindow];
    
    // Setup notifications
    [self registerNotificationObservers];
    
    // Setup Layer
    [self setupLayer];
    
    // Configure Atlas Messenger UI appearance
    [self configureGlobalUserInterfaceAttributes];
    
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [self resumeSession];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    [self setApplicationBadgeNumber];
}

#pragma mark - Setup

- (void)configureWindow
{
    self.scannerController = [ATLMQRScannerController new];
    self.scannerController.applicationController = self.applicationController;
    
    self.navigationController = [[UINavigationController alloc] initWithRootViewController:self.scannerController];
    self.navigationController.navigationBarHidden = YES;
    
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = self.navigationController;
    [self.window makeKeyAndVisible];
    
    [self addSplashView];
}

- (void)setupLayer
{
    NSString *appID = ATLMLayerAppID ?: [[NSUserDefaults standardUserDefaults] valueForKey:ATLMLayerApplicationID];
    if (appID) {
        // Only instantiate one instance of `LYRClient`
        if (!self.layerClient) {
            self.layerClient = [ATLMLayerClient clientWithAppID:[NSURL URLWithString:appID]];
            self.layerClient.autodownloadMIMETypes = [NSSet setWithObjects:ATLMIMETypeImageJPEGPreview, ATLMIMETypeTextPlain, nil];
        }
        ATLMAPIManager *manager = [ATLMAPIManager managerWithBaseURL:ATLMRailsBaseURL(ATLMEnvironmentProduction) layerClient:self.layerClient];
        self.applicationController.layerClient = self.layerClient;
        self.applicationController.APIManager = manager;
        [self connectLayerIfNeeded];
        if (![self resumeSession]) {
            [self.scannerController presentRegistrationViewController];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self removeSplashView];
            });
        }
    } else {
        [self removeSplashView];
    }
}

- (void)registerNotificationObservers
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveLayerAppID:) name:ATLMDidReceiveLayerAppID object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDidAuthenticate:) name:ATLMUserDidAuthenticateNotification object:nil];
    [[NSNotificationCenter defaultCenter]  addObserver:self selector:@selector(userDidAuthenticateWithLayer:) name:LYRClientDidAuthenticateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDidDeauthenticate:) name:ATLMUserDidDeauthenticateNotification object:nil];
}

#pragma mark - Session Management

- (BOOL)resumeSession
{
    if (self.applicationController.layerClient.authenticatedUserID) {
        ATLMSession *session = [self.applicationController.persistenceManager persistedSessionWithError:nil];
        if ([self.applicationController.APIManager resumeSession:session error:nil]) {
            [self presentConversationsListViewController:YES];
            return YES;
        }
    }
    return NO;
}

- (void)connectLayerIfNeeded
{
    if (!self.applicationController.layerClient.isConnected && !self.applicationController.layerClient.isConnecting) {
        [self.applicationController.layerClient connectWithCompletion:^(BOOL success, NSError *error) {
            NSLog(@"Layer Client Connected");
        }];
    }
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
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        [application registerForRemoteNotificationTypes:UIRemoteNotificationTypeAlert | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeBadge];
#pragma GCC diagnostic pop
    }
}

- (void)unregisterForRemoteNotifications:(UIApplication *)application
{
    [application unregisterForRemoteNotifications];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    NSLog(@"Application failed to register for remote notifications with error %@", error);
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    NSError *error;
    BOOL success = [self.applicationController.layerClient updateRemoteNotificationDeviceToken:deviceToken error:&error];
    if (success) {
        NSLog(@"Application did register for remote notifications");
    } else {
        NSLog(@"Error updating Layer device token for push:%@", error);
    }
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    NSLog(@"User Info: %@", userInfo);
    BOOL userTappedRemoteNotification = application.applicationState == UIApplicationStateInactive;
    __block LYRConversation *conversation = [self conversationFromRemoteNotification:userInfo];
    if (userTappedRemoteNotification && conversation) {
        [self navigateToViewForConversation:conversation];
    } else if (userTappedRemoteNotification) {
        [SVProgressHUD showWithStatus:@"Loading Conversation" maskType:SVProgressHUDMaskTypeBlack];
    }
    
    BOOL success = [self.applicationController.layerClient synchronizeWithRemoteNotification:userInfo completion:^(NSArray *changes, NSError *error) {
        if (changes.count) {
            completionHandler(UIBackgroundFetchResultNewData);
        } else {
            completionHandler(error ? UIBackgroundFetchResultFailed : UIBackgroundFetchResultNoData);
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

-(BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    return YES;
}

- (LYRConversation *)conversationFromRemoteNotification:(NSDictionary *)remoteNotification
{
    NSURL *conversationIdentifier = [NSURL URLWithString:[remoteNotification valueForKeyPath:@"layer.conversation_identifier"]];
    return [self.applicationController.layerClient existingConversationForIdentifier:conversationIdentifier];
}

- (void)navigateToViewForConversation:(LYRConversation *)conversation
{
    if (![NSThread isMainThread]) {
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Attempted to navigate UI from non-main thread" userInfo:nil];
    }
    [self.conversationListViewController selectConversation:conversation];
}

#pragma mark - Authentication Notification Handlers

- (void)didReceiveLayerAppID:(NSNotification *)notification
{
    [self setupLayer];
}

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
    ATLMSession *session = self.applicationController.APIManager.authenticatedSession;
    BOOL success = [self.applicationController.persistenceManager persistSession:session error:&error];
    if (success) {
        NSLog(@"Persisted authenticated user session: %@", session);
    } else {
        NSLog(@"Failed persisting authenticated user: %@. Error: %@", session, error);
    }
    [self registerForRemoteNotifications:[UIApplication sharedApplication]];
}

- (void)userDidDeauthenticate:(NSNotification *)notification
{
    NSError *error;
    BOOL success = [self.applicationController.persistenceManager persistSession:nil error:&error];
    if (success) {
        NSLog(@"Cleared persisted user session");
    } else {
        NSLog(@"Failed clearing persistent user session: %@", error);
        //TODO - Handle Error
    }
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        self.conversationListViewController = nil;
        [self setupLayer];
    }];
    
    [self unregisterForRemoteNotifications:[UIApplication sharedApplication]];
}

#pragma mark - Conversations

- (void)presentConversationsListViewController:(BOOL)animated
{
    if (self.conversationListViewController) return;
    self.conversationListViewController = [ATLMConversationListViewController conversationListViewControllerWithLayerClient:self.applicationController.layerClient];
    self.conversationListViewController.applicationController = self.applicationController;
    
    ATLMNavigationController *authenticatedNavigationController = [[ATLMNavigationController alloc] initWithRootViewController:self.conversationListViewController];
    [self.navigationController presentViewController:authenticatedNavigationController animated:YES completion:^{
        [self removeSplashView];
    }];
}

#pragma mark - Splash View

- (void)addSplashView
{
    if (!self.splashView) {
        self.splashView = [[ATLMSplashView alloc] initWithFrame:self.window.bounds];
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
    [[UINavigationBar appearance] setTintColor:ATLBlueColor()];
    [[UINavigationBar appearance] setBarTintColor:ATLLightGrayColor()];
    [[UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil] setTintColor:ATLBlueColor()];
}

#pragma mark - Application Badge Setter

- (void)setApplicationBadgeNumber
{
    NSUInteger countOfUnreadMessages = [self.applicationController.layerClient countOfUnreadMessages];
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:countOfUnreadMessages];
}

@end