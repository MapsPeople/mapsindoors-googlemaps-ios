////
////  DebugHelpers.m
////  MapsIndoorsGoogleMaps
////
////  Created by Shahab Shajarat on 31/08/2022.
////  Copyright © 2022 MapsPeople A/S. All rights reserved.
////
//
#pragma mark - MapsIndoors+DebugHelpers
//
////
////  MapsIndoors+DebugHelpers.h
////  MapsIndoors App
////
////  Created by Michael Bech Hansen on 19/03/2018.
////  Copyright © 2018 MapsPeople A/S. All rights reserved.
////
//
//#import <MapsIndoors/MapsIndoors.h>
//#import "MPRouteNetwork.h"
//#import "MPRouteGraphVisualizer.h"
//
//
//@interface MPRoute (DebugHelpers)
//
//- (NSString*) dbg_describeRoute;
//- (NSString*) dbg_describeRouteIncludeLegs:(BOOL)includeLegs includeSteps:(BOOL)includeSteps;
//
//@end
//
//
//@interface MPVenue (DebugHelpers)
//
//- (GMSPolygon*) dbg_boundingBoxPolygon;
//- (GMSPolygon*) dbg_outlinePolygon;
//
//@end
//
//
//@interface MPBuilding (DebugHelpers)
//
//- (GMSPolygon*) dbg_outlinePolygon;
//
//@end
//
//
//@interface MPRouteNetwork (DebugHelpers)
//
//- (GMSPolygon*) dbg_outlinePolygon;
//
//@end
//
//
//@interface GMSMapView (DebugHelpers)
//
//@property (nonatomic, strong, setter=mp_setVenueBoundingBoxPolygon:) GMSPolygon*            mp_venueBoundingBoxPolygon;
//@property (nonatomic, strong, setter=mp_setVenueOutlinePolygon:) GMSPolygon*                mp_venueOutlinePolygon;
//@property (nonatomic, strong, setter=mp_setBuildingOutlinePolygons:) NSArray<GMSPolygon*>*  mp_buildingOutlinePolygons;
//@property (nonatomic, strong, setter=mp_setRouteNetworkPolygon:) GMSPolygon*                mp_routeNetworkPolygon;
//@property (nonatomic, strong, setter=mp_setRouteGraphVisualizer:) MPRouteGraphVisualizer*   mp_routeGraphVisualizer;
//
//- (void) dbg_addGeometryPolygonsForVenue:(MPVenue*)venue addBuildingOutlines:(BOOL)addBuildingOutlines;
//- (void) dbg_showRoutingGraph:(NSString*)graphId solutionId:(NSString*)solutionId;
//
//@end
//
#pragma mark - MPVenue+DebugHelpers
//
////
////  MPVenue+DebugHelpers.m
////  MapsIndoors App
////
////  Created by Michael Bech Hansen on 19/03/2018.
////  Copyright © 2018 MapsPeople A/S. All rights reserved.
////
//
//#import "MapsIndoors+DebugHelpers.h"
//#import "MPLog.h"
//#import "MPPolygonGeometry+Private.h"
//#import <objc/runtime.h>
//#import "MPRouteGraphVisualizer.h"
//#import "MPRouteNetworkService.h"
//#import "MPRouteNetworkData.h"
//#import "MPRouteNetwork.h"
//
//#import "MapsIndoorsLegacy+Private.h"
//
//
//typedef NS_ENUM( int, DebugHelperOverlayIndex ) {
//    DebugHelperOverlayIndex_VenueBoundsPolygon = 5000,
//    DebugHelperOverlayIndex_VenueOutlinePolygon,
//    DebugHelperOverlayIndex_BuildingOutlinePolygon,
//    DebugHelperOverlayIndex_RouteNetwork,
//};
//
//
#pragma mark - Internal helper methods
//
//static GMSPolygon* dbg_polygonFromBoundsArray( NSArray<NSArray*>* boundsArray ) {
//
//    GMSPolygon*             resultPolygon;
//    NSMutableArray* paths = [NSMutableArray array];
//
//    for ( NSArray* bounds in boundsArray ) {
//        GMSMutablePath* path = [GMSMutablePath path];
//        for ( NSArray* coordinates in bounds ) {
//            CLLocationCoordinate2D coord = CLLocationCoordinate2DMake([[coordinates objectAtIndex:1] doubleValue], [[coordinates objectAtIndex:0] doubleValue]);
//            [path addCoordinate:coord];
//        }
//        [paths addObject:path];
//    }
//
//    if ( paths.count ) {
//        resultPolygon = [GMSPolygon polygonWithPath:paths.firstObject];
//        resultPolygon.holes = (paths.count > 1) ? [paths subarrayWithRange:NSMakeRange(1, paths.count-1)] : nil;
//    }
//
//    return resultPolygon;
//}
//
//
#pragma mark - MPVenue helpers
//
//@implementation MPVenue (DebugHelpers)
//
//- (GMSPolygon*) dbg_boundingBoxPolygon {
//
//    GMSPolygon*             resultPolygon;
//    id<MPCoordinateBounds>    bounds = [self getBoundingBox];
//
//    if ( bounds.isValid ) {
//
//        id<MPPath> rect = [MapsIndoors.mapConfig.mapProvider.pathClass path];
//        [rect addCoordinate:bounds.northEast];
//        [rect addCoordinate:CLLocationCoordinate2DMake(bounds.northEast.latitude, bounds.southWest.longitude)];
//        [rect addCoordinate:bounds.southWest];
//        [rect addCoordinate:CLLocationCoordinate2DMake(bounds.southWest.latitude, bounds.northEast.longitude)];
//
//        // Create polygon with some default looks:
//        resultPolygon = [GMSPolygon polygonWithPath:rect];
//        resultPolygon.fillColor = [UIColor colorWithRed:0.25 green:0 blue:0 alpha:0.05];
//        resultPolygon.strokeColor = [UIColor redColor];
//        resultPolygon.strokeWidth = 2;
//        resultPolygon.zIndex = DebugHelperOverlayIndex_VenueBoundsPolygon;
//        resultPolygon.userData = self;
//    }
//
//    return resultPolygon;
//}
//
//- (GMSPolygon*) dbg_outlinePolygon {
//
//    GMSPolygon*             resultPolygon = dbg_polygonFromBoundsArray( self.bounds );
//
//    resultPolygon.fillColor = [UIColor colorWithRed:0 green:0.25 blue:0 alpha:0.05];
//    resultPolygon.strokeColor = [UIColor greenColor];
//    resultPolygon.strokeWidth = 2;
//    resultPolygon.zIndex = DebugHelperOverlayIndex_VenueOutlinePolygon;
//    resultPolygon.userData = self;
//
//    return resultPolygon;
//}
//
//@end
//
//
#pragma mark - MPBuilding helpers
//
//@implementation MPBuilding (DebugHelpers)
//
//- (GMSPolygon*) dbg_outlinePolygon {
//
//    GMSPolygon*             resultPolygon = dbg_polygonFromBoundsArray( self.bounds );
//
//    resultPolygon.fillColor = [UIColor colorWithRed:0 green:0 blue:0.25 alpha:0.05];
//    resultPolygon.strokeColor = [UIColor blueColor];
//    resultPolygon.strokeWidth = 2;
//    resultPolygon.zIndex = DebugHelperOverlayIndex_BuildingOutlinePolygon;
//    resultPolygon.userData = self;
//
//    return resultPolygon;
//}
//
//@end
//
//
#pragma mark - MPBuilding helpers
//
//@implementation MPRouteNetwork (DebugHelpers)
//
//- (GMSPolygon*) dbg_outlinePolygon {
//
//    NSArray<GMSPath*>*      paths = self.graphArea.gmspaths;
//    GMSPolygon*             resultPolygon = [GMSPolygon polygonWithPath:paths[0]];
//
//    if ( paths.count > 1 ) {
//        resultPolygon.holes = [paths subarrayWithRange:NSMakeRange(1, paths.count -1)];
//    }
//
//    resultPolygon.strokeColor = [UIColor orangeColor];
//    resultPolygon.fillColor = [resultPolygon.strokeColor colorWithAlphaComponent:0.05];
//    resultPolygon.strokeWidth = 1;
//    resultPolygon.zIndex = DebugHelperOverlayIndex_RouteNetwork;
//    resultPolygon.userData = self;
//
//    return resultPolygon;
//}
//
//@end
//
//
//
#pragma mark - GMSMapView helpers
//
//@implementation GMSMapView (DebugHelpers)
//
//- (GMSPolygon *)mp_venueBoundingBoxPolygon {
//
//    return (GMSPolygon *)objc_getAssociatedObject( self, @selector(mp_venueBoundingBoxPolygon) );
//}
//
//- (void)mp_setVenueBoundingBoxPolygon:(GMSPolygon *)venueBoundingBoxPolygon {
//
//    objc_setAssociatedObject( self, @selector(mp_venueBoundingBoxPolygon), venueBoundingBoxPolygon, OBJC_ASSOCIATION_RETAIN_NONATOMIC );
//}
//
//
//- (GMSPolygon *)mp_venueOutlinePolygon {
//
//    return (GMSPolygon *)objc_getAssociatedObject( self, @selector(mp_venueOutlinePolygon) );
//}
//
//- (void)mp_setVenueOutlinePolygon:(GMSPolygon *)venueOutlinePolygon {
//
//    objc_setAssociatedObject( self, @selector(mp_venueOutlinePolygon), venueOutlinePolygon, OBJC_ASSOCIATION_RETAIN_NONATOMIC );
//}
//
//
//- (NSArray<GMSPolygon *> *)mp_buildingOutlinePolygons {
//
//    return (NSArray<GMSPolygon *> *)objc_getAssociatedObject( self, @selector(mp_buildingOutlinePolygons) );
//}
//
//- (void)mp_setBuildingOutlinePolygons:(NSArray<GMSPolygon *> *)buildingOutlinePolygons {
//
//    objc_setAssociatedObject( self, @selector(mp_buildingOutlinePolygons), buildingOutlinePolygons, OBJC_ASSOCIATION_RETAIN_NONATOMIC );
//}
//
//- (void) dbg_addGeometryPolygonsForVenue:(MPVenue*)venue addBuildingOutlines:(BOOL)addBuildingOutlines {
//
//    // Remove old overlays from map:
//    self.mp_venueOutlinePolygon.map = nil;
//    self.mp_venueBoundingBoxPolygon.map = nil;
//    for ( GMSOverlay* o in self.mp_buildingOutlinePolygons ) {
//        o.map = nil;
//    }
//
//    // Add new overlays:
//    GMSPolygon* outline = self.mp_venueOutlinePolygon = [venue dbg_outlinePolygon];
//    GMSPolygon* bbox = self.mp_venueBoundingBoxPolygon = [venue dbg_boundingBoxPolygon];
//    outline.map = self;
//    bbox.map = self;
//
//    if ( addBuildingOutlines ) {
//
//        MPVenueProvider*    venueProvider = [MPVenueProvider new];
//        [venueProvider getBuildingsWithCompletion:^(NSArray<MPBuilding *> *buildings, NSError *error) {
//
//            NSMutableArray<GMSOverlay*>*    buildingOverlays = [NSMutableArray array];
//            for ( MPBuilding* b in buildings ) {
//                GMSOverlay* o = [b dbg_outlinePolygon];
//                if ( o ) {
//                    o.map = self;
//                    [buildingOverlays addObject:o];
//                }
//            }
//            self.mp_buildingOutlinePolygons = [buildingOverlays copy];
//        }];
//    }
//}
//
//
//- (GMSPolygon *)mp_routeNetworkPolygon {
//
//    return (GMSPolygon *)objc_getAssociatedObject( self, @selector(mp_routeNetworkPolygon) );
//}
//
//- (void)mp_setRouteNetworkPolygon:(GMSPolygon *)routeNetworkPolygon {
//
//    if ( self.mp_routeNetworkPolygon != routeNetworkPolygon ) {
//        self.mp_routeNetworkPolygon.map = nil;
//        objc_setAssociatedObject( self, @selector(mp_routeNetworkPolygon), routeNetworkPolygon, OBJC_ASSOCIATION_RETAIN_NONATOMIC );
//        routeNetworkPolygon.map = self;
//    }
//}
//
//
//- (MPRouteGraphVisualizer *)mp_routeGraphVisualizer {
//
//    return (MPRouteGraphVisualizer *)objc_getAssociatedObject( self, @selector(mp_routeGraphVisualizer) );
//}
//
//- (void) mp_setRouteGraphVisualizer:(MPRouteGraphVisualizer *)routeGraphVisualizer {
//
//    objc_setAssociatedObject( self, @selector(mp_routeGraphVisualizer), routeGraphVisualizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC );
//}
//
//- (void) dbg_showRoutingGraph:(NSString *)graphId solutionId:(NSString*)solutionId {
//
//    if ( self.mp_routeGraphVisualizer == nil ) {
//        self.mp_routeGraphVisualizer = [MPRouteGraphVisualizer newWithMap:self];
//        self.accessibilityElementsHidden = YES;     // Performance sucks BIG TIME when adding a lot of polylines with accessibility=ON
//    }
//
//    [MPRouteNetworkService getRouteNetworkForSolution:solutionId completion:^(MPRouteNetworkData * _Nullable rnd, NSError * _Nullable err) {
//
//        MPRouteNetwork*     routeNetwork = rnd.networkFromGraphId[[graphId lowercaseString]];
//
//        if ( err ) {
//            MPDebugLog( @"[DBG] Error fetching routing graph '%@': %@", graphId, err );
//        }
//
//        if ( routeNetwork ) {
//            self.mp_routeGraphVisualizer.routingGraph = routeNetwork.graph;
//        }
//    }];
//}
//
//@end
//
//
//
#pragma mark - MPRoute
//
//@implementation MPRoute (DebugHelpers)
//
//- (NSString*) dbg_describeRoute {
//    return [self dbg_describeRouteIncludeLegs:YES includeSteps:YES];
//}
//
//- (NSString*) dbg_describeRouteIncludeLegs:(BOOL)includeLegs includeSteps:(BOOL)includeSteps {
//
//    NSMutableString* s = [NSMutableString string];
//    [s appendFormat: @"MPRoute %p: '%@', %@ legs", self, self.summary, @(self.legs.count) ];
//
//    if ( includeLegs ) {
//        for ( MPRouteLeg* leg in self.legs ) {
//            [s appendFormat:  @"\n    Leg %@: %@, %.1f m (%@ to %@)", @([self.legs indexOfObject:leg]), leg.routeLegType == MPRouteLegTypeMapsIndoors ? @"INDOOR" : @"GOOGLE", leg.distance.doubleValue, leg.start_address, leg.end_address ];
//
//            if ( includeSteps ) {
//                double stepSumDistance = 0;
//                for ( MPRouteStep* step in leg.steps ) {
//                    [s appendFormat:  @"\n       Step %@ (%@), %.1fm, %@s", step.travel_mode, step.highway, step.distance.doubleValue, @(step.duration.unsignedIntegerValue)];
//                    stepSumDistance += step.distance.doubleValue;
//                }
//                [s appendFormat: @"\n       TOTAL %.1f m", stepSumDistance ];
//            }
//        }
//    }
//
//    return [s copy];
//}
//
//@end
//
//

#pragma mark - MPMapControl setDebugObstacles
//- (void)setDebugObstacles:(NSArray<GMSPolygon *> *)debugObstacles {
//    for (GMSPolygon* poly in _debugObstacles) {
//        poly.map = nil;
//    }
//    _debugObstacles = debugObstacles;
//}

#pragma mark - MPMapControl showObstaclesForLocations
//- (void) debug_showObstaclesForLocations:(NSArray<NSString*>*)locationIds {
//    
//    NSArray<MPRouteObstacle*>* obstacles = [self.debugRouteLayerService obstaclesForLocationsWithIds:locationIds];
//    
//    NSMutableArray* polys = [NSMutableArray array];
//    
//    for (MPRouteObstacle* obstacle in obstacles) {
//        
//        GMSPolygon* poly = [[GMSPolygon alloc] init];
//        
//        poly.fillColor = [UIColor.redColor colorWithAlphaComponent:0.1];
//        poly.path = obstacle.geometry.mpPathForPath;
//        poly.map = self.map;
//        [polys addObject:poly];
//    }
//    
//    self.debugObstacles = polys;
//    
//}

#pragma mark - MPLocationMarkerManager updateClonePolygon
//- (void) debug_updateClonePolygon:(GMSPolygon*)poly locationId:(NSString*)locationId {
//
//#define DOUBLE_POLYGON_PERF_TEST    0
//
//#if DOUBLE_POLYGON_PERF_TEST
//    NSString*   cloneId = [locationId stringByAppendingFormat:@"-clone"];
//
//    if ( poly.map ) {
//
//        if ( self.polygons[cloneId] == nil ) {
//
//            GMSPolygon*     p = [poly copy];
//
//            p.path = [poly.path pathOffsetByLatitude:-0.0005 longitude:0];
//            p.holes = nil;
//
//            p.map = poly.map;
//
//            self.polygons[ cloneId ] = p;
//        }
//
//    } else {
//
//        self.polygons[ cloneId ].map = nil;
//        [self.polygons removeObjectForKey:cloneId];
//    }
//#endif
//}
