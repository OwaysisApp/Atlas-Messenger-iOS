//
//  ATLMSettingsViewController.h
//  Atlas Messenger
//
//  Created by Kevin Coleman on 10/20/14.
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

#import <UIKit/UIKit.h>
#import "ATLMApplicationController.h"

@class ATLMSettingsViewController;

NSString *const ATLMSettingsViewControllerTitle;
NSString *const ATLMSettingsTableViewAccessibilityIdentifier;
NSString *const ATLMSettingsHeaderAccessibilityLabel;

extern NSString *const ATLMDefaultCellIdentifier;
extern NSString *const ATLMCenterTextCellIdentifier;

NSString *const ATLMConnected;
NSString *const ATLMDisconnected;
NSString *const ATLMLostConnection;
NSString *const ATLMConnecting;

/**
 @abstract The `ATLMSettingsViewControllerDelegate` protocol informs the receiver of events that have occurred within the controller.
 */
@protocol ATLMSettingsViewControllerDelegate <NSObject>

/**
 @abstract Informs the receiver that a logout button has been tapped in the controller.
 @param settingsViewController The controller in which the selection occurred.
 */
- (void)logoutTappedInSettingsViewController:(ATLMSettingsViewController *)settingsViewController;

/**
 @abstract Informs the receiver that the user wants to dismiss the controller.
 @param settingsViewController The controller in which the selection occurred.
 */
- (void)settingsViewControllerDidFinish:(ATLMSettingsViewController *)settingsViewController;

@end

/**
 @abstract The `ATLMSettingsViewController` presents a user interface for viewing and configuring application settings in addition to viewing information related to the application.
 */
@interface ATLMSettingsViewController : UITableViewController

/**
 @abstract The controller object for the application.
 */
@property (nonatomic) ATLMApplicationController *applicationController;

/**
 @abstract The `ATLMSettingsViewControllerDelegate` object for the controller.
 */
@property (nonatomic) id<ATLMSettingsViewControllerDelegate> settingsDelegate;

@end
