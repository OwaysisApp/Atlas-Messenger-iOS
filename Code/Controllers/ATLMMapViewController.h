//
//  ATLMMapViewController.h
//  Atlas Messenger
//
//  Created by Vivek Trehan on 7/15/15.
//  Copyright (c) 2015 Layer, Inc. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import <MapKit/MKAnnotation.h>


@interface ATLMMapViewController : UIViewController <MKMapViewDelegate, CLLocationManagerDelegate>
@property (nonatomic, retain) MKMapView *mapView;
@property(nonatomic, retain) CLLocationManager *locationManager;

-(void) updateAnnotation: (CLLocationCoordinate2D) coordinate;
@end
