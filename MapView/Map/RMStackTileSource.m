//
//  RMStackTileSource.h
//
// Copyright (c) 2008-2012, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "RMStackTileSource.h"
#import "RMAbstractMercatorTileSource.h"
#import "RMTileCache.h"
#import "RMMapView.h"

#define kRMTileSourcesContainerMinZoom 0
#define kRMTileSourcesContainerMaxZoom 255

@implementation RMStackTileSource
{
    NSString *_uniqueTilecacheKey;
    
    NSMutableArray *_tileSources;
    NSRecursiveLock *_tileSourcesLock;
    
    RMProjection *_projection;
    RMFractalTileProjection *_mercatorToTileProjection;
    
    RMSphericalTrapezium _latitudeLongitudeBoundingBox;
    
    float _minZoom, _maxZoom;
    NSUInteger _tileSideLength;
    
    BOOL _shouldNotifyOnSourceChange;
}
@synthesize minZoom = _minZoom, maxZoom = _maxZoom, cacheable = _cacheable, opaque = _opaque;

- (id)init
{
    if (self = [super init])
    {
        // http://wiki.openstreetmap.org/index.php/FAQ#What_is_the_map_scale_for_a_particular_zoom_level_of_the_map.3F
        _minZoom = kDefaultMinTileZoom;
        _maxZoom = kDefaultMaxTileZoom;
        _mercatorToTileProjection = nil;
        _projection = nil;
        self.cacheable = YES;
        self.opaque = YES;
        _shouldNotifyOnSourceChange = YES;
        _tileSources = [NSMutableArray new];
        _tileSourcesLock = [NSRecursiveLock new];
    }
    return self;
}


- (NSArray *)tileSources
{
    return [_tileSources copy];
}

- (NSString *)uniqueTilecacheKey
{
    return _uniqueTilecacheKey;
}

- (NSString *)shortName
{
	return @"Generic Map Source";
}

- (NSString *)longDescription
{
	return @"Generic Map Source";
}

- (NSString *)shortAttribution
{
	return @"n/a";
}

- (NSString *)longAttribution
{
	return @"n/a";
}

- (BOOL)tileSourceHasTile:(RMTile)tile
{
    return YES;
}

- (void)cancelAllDownloads
{
    [_tileSourcesLock lock];
    
    for (id <RMTileSource>tileSource in _tileSources)
        [tileSource cancelAllDownloads];
    
    [_tileSourcesLock unlock];
}

- (RMFractalTileProjection *)mercatorToTileProjection
{
    return _mercatorToTileProjection;
}

- (RMProjection *)projection
{
    return _projection;
}

- (float)minZoom
{
    return _minZoom;
}

- (void)setMinZoom:(float)minZoom
{
    if (minZoom < kRMTileSourcesContainerMinZoom)
        minZoom = kRMTileSourcesContainerMinZoom;
    
    _minZoom = minZoom;
}

- (float)maxZoom
{
    return _maxZoom;
}

- (void)setMaxZoom:(float)maxZoom
{
    if (maxZoom > kRMTileSourcesContainerMaxZoom)
        maxZoom = kRMTileSourcesContainerMaxZoom;
    
    _maxZoom = maxZoom;
}

- (NSUInteger)tileSideLength
{
    return _tileSideLength;
}

- (RMSphericalTrapezium)latitudeLongitudeBoundingBox
{
    return _latitudeLongitudeBoundingBox;
}

- (void)setBoundingBoxFromTilesources
{
    [_tileSourcesLock lock];
    
    _latitudeLongitudeBoundingBox = ((RMSphericalTrapezium) {
        .northEast = {.latitude = INT_MIN, .longitude = INT_MIN},
        .southWest = {.latitude = INT_MAX, .longitude = INT_MAX}
    });
    
    for (id <RMTileSource>tileSource in _tileSources)
    {
        RMSphericalTrapezium newLatitudeLongitudeBoundingBox = [tileSource latitudeLongitudeBoundingBox];
        
        _latitudeLongitudeBoundingBox = ((RMSphericalTrapezium) {
            .northEast = {
                .latitude = MAX(_latitudeLongitudeBoundingBox.northEast.latitude, newLatitudeLongitudeBoundingBox.northEast.latitude),
                .longitude = MAX(_latitudeLongitudeBoundingBox.northEast.longitude, newLatitudeLongitudeBoundingBox.northEast.longitude)},
            .southWest = {
                .latitude = MIN(_latitudeLongitudeBoundingBox.southWest.latitude, newLatitudeLongitudeBoundingBox.southWest.latitude),
                .longitude = MIN(_latitudeLongitudeBoundingBox.southWest.longitude, newLatitudeLongitudeBoundingBox.southWest.longitude)
            }
        });
    }
    
    [_tileSourcesLock unlock];
}

- (UIImage *)imageForTile:(RMTile)tile inCache:(RMTileCache *)tileCache
{
    UIImage *image = nil;
    
	tile = [[self mercatorToTileProjection] normaliseTile:tile];
    
    if (self.isCacheable)
    {
        image = [tileCache cachedImage:tile withCacheKey:[self uniqueTilecacheKey]];
        
        if (image)
            return image;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^(void)
                   {
                       [[NSNotificationCenter defaultCenter] postNotificationName:RMTileRequested object:[NSNumber numberWithUnsignedLongLong:RMTileKey(tile)]];
                   });
    
    for (NSInteger u = 0; u <[_tileSources count] ; ++u)
    {
        id <RMTileSource> tileSource = [_tileSources objectAtIndex:u];
        
        if (tile.zoom < tileSource.minZoom || tile.zoom > tileSource.maxZoom || ![tileSource tileSourceHasTile:tile])
            continue;
        
        UIImage *tileImage = [tileSource imageForTile:tile inCache:tileCache];
        
        if (tileImage)
        {
            dispatch_async(dispatch_get_main_queue(), ^(void)
                           {
                               [[NSNotificationCenter defaultCenter] postNotificationName:RMTileRetrieved object:[NSNumber numberWithUnsignedLongLong:RMTileKey(tile)]];
                           });
            return tileImage;
        }
    }
    return (UIImage *)[NSNull null];
}

- (BOOL)setTileSource:(id <RMTileSource>)tileSource
{
    BOOL result;
    
    [_tileSourcesLock lock];
    
    _shouldNotifyOnSourceChange = NO;
    [self removeAllTileSources];
    result = [self addTileSource:tileSource];
    
    [_tileSourcesLock unlock];
    _shouldNotifyOnSourceChange = YES;
    [self notifyMapOnSourceChange];
   
    return result;
}

- (BOOL)setTileSources:(NSArray *)tileSources
{
    BOOL result = YES;
    
    [_tileSourcesLock lock];
    
    _shouldNotifyOnSourceChange = NO;
    [self removeAllTileSources];
    
    for (id <RMTileSource> tileSource in tileSources)
        result &= [self addTileSource:tileSource];
    
    [_tileSourcesLock unlock];
    _shouldNotifyOnSourceChange = YES;
   
    [self notifyMapOnSourceChange];
    return result;
}

-(void)notifyMapOnSourceChange
{
    if (!_shouldNotifyOnSourceChange) return;
    dispatch_async(dispatch_get_main_queue(), ^(void)
    {
       [[NSNotificationCenter defaultCenter] postNotificationName:RMSourceChanged object:nil];
    });
}

- (BOOL)addTileSource:(id <RMTileSource>)tileSource
{
    return [self addTileSource:tileSource atIndex:-1];
}

- (BOOL)addTileSource:(id<RMTileSource>)tileSource atIndex:(NSUInteger)index
{
    if ( ! tileSource)
        return NO;
    
    [_tileSourcesLock lock];
    
    RMProjection *newProjection = [tileSource projection];
    RMFractalTileProjection *newFractalTileProjection = [tileSource mercatorToTileProjection];
    
    if ( ! _projection)
    {
        _projection = newProjection;
    }
    else if (_projection != newProjection)
    {
        NSLog(@"The tilesource '%@' has a different projection than the tilesource container", [tileSource shortName]);
        [_tileSourcesLock unlock];
        return NO;
    }
    
    if ( ! _mercatorToTileProjection)
        _mercatorToTileProjection = newFractalTileProjection;
    
    // minZoom and maxZoom are the min and max values of all tile sources, so that individual tilesources
    // could have a smaller zoom level range
    self.minZoom = MAX(_minZoom, [tileSource minZoom]);
    self.maxZoom = MIN(_maxZoom, [tileSource maxZoom]);
    
    if (_tileSideLength == 0)
    {
        _tileSideLength = [tileSource tileSideLength];
    }
    else if (_tileSideLength != [tileSource tileSideLength])
    {
        NSLog(@"The tilesource '%@' has a different tile side length than the tilesource container", [tileSource shortName]);
        [_tileSourcesLock unlock];
        return NO;
    }
    
    
    if (index >= [_tileSources count])
        [_tileSources addObject:tileSource];
    else
        [_tileSources insertObject:tileSource atIndex:index];
    
    [self setBoundingBoxFromTilesources];
    [_tileSourcesLock unlock];
    
    [self notifyMapOnSourceChange];
    
    RMLog(@"Added the tilesource '%@' to the container", [tileSource shortName]);
    
    return YES;
}

- (void)removeTileSource:(id <RMTileSource>)tileSource
{
    [tileSource cancelAllDownloads];
    
    [_tileSourcesLock lock];
    
    [_tileSources removeObject:tileSource];
    
    RMLog(@"Removed the tilesource '%@' from the container", [tileSource shortName]);
    
    if ([_tileSources count] == 0) {
        _shouldNotifyOnSourceChange = NO;
        [self removeAllTileSources]; // cleanup
        _shouldNotifyOnSourceChange = YES;
    } else
        [self setBoundingBoxFromTilesources];
    
    [_tileSourcesLock unlock];
    [self notifyMapOnSourceChange];
}

- (void)removeTileSourceAtIndex:(NSUInteger)index
{
    [_tileSourcesLock lock];
    
    if (index >= [_tileSources count])
    {
        [_tileSourcesLock unlock];
        return;
    }
    
    id <RMTileSource> tileSource = [_tileSources objectAtIndex:index];
    [tileSource cancelAllDownloads];
    [_tileSources removeObject:tileSource];
    
    RMLog(@"Removed the tilesource '%@' from the container", [tileSource shortName]);
    
    if ([_tileSources count] == 0) {
        _shouldNotifyOnSourceChange = NO;
        [self removeAllTileSources]; // cleanup
        _shouldNotifyOnSourceChange = YES;
    } else
        [self setBoundingBoxFromTilesources];
    
    [_tileSourcesLock unlock];
    [self notifyMapOnSourceChange];

}

- (void)moveTileSourceAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex
{
    if (fromIndex == toIndex)
        return;
    
    [_tileSourcesLock lock];
    
    if (fromIndex >= [_tileSources count])
    {
        [_tileSourcesLock unlock];
        return;
    }
    
    id tileSource = [_tileSources objectAtIndex:fromIndex];
    [_tileSources removeObjectAtIndex:fromIndex];
    
    if (toIndex >= [_tileSources count])
        [_tileSources addObject:tileSource];
    else
        [_tileSources insertObject:tileSource atIndex:toIndex];
    
    [_tileSourcesLock unlock];
    
}

- (void)removeAllTileSources
{
    [_tileSourcesLock lock];
    
    [self cancelAllDownloads];
    [_tileSources removeAllObjects];
    
    _projection = nil;
    _mercatorToTileProjection = nil;
    
    _latitudeLongitudeBoundingBox = ((RMSphericalTrapezium) {
        .northEast = {.latitude = INT_MIN, .longitude = INT_MIN},
        .southWest = {.latitude = INT_MAX, .longitude = INT_MAX}
    });
    
    _minZoom = kRMTileSourcesContainerMinZoom;
    _maxZoom = kRMTileSourcesContainerMaxZoom;
    _tileSideLength = 0;
    
    [_tileSourcesLock unlock];
    [self notifyMapOnSourceChange];
}


- (void)didReceiveMemoryWarning
{
    LogMethod();
}

@end
