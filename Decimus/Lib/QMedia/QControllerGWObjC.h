//
//  QMediaI.h
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#ifndef QControllerGWObc_h
#define QControllerGWObc_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "QControllerGW.h"
#include <cantina/logger.h>
#endif

#import "QDelegatesObjC.h"
#import "TransportConfig.h"

typedef void(*CantinaLogCallback)(uint8_t, NSString*, bool);

typedef unsigned PublicationState NS_TYPED_ENUM;
static PublicationState const PublicationStateActive = 0;
static PublicationState const PublicationStatePaused = 1;

typedef unsigned SubscriptionState NS_TYPED_ENUM;
static SubscriptionState const SubscriptionStateUnknown = 0;
static SubscriptionState const SubscriptionStatePending = 1;
static SubscriptionState const SubscriptionStateReady = 2;
static SubscriptionState const SubscriptionStatePaused = 3;

@interface PublicationReport: NSObject
@property PublicationState state;
@property NSString* quicrNamespace;
#ifdef __cplusplus
-(id)initWithReport:(qmedia::QController::PublicationReport)report;
#endif
@end

@interface QControllerGWObjC<PubDelegate: id<QPublisherDelegateObjC>,
                             SubDelegate: id<QSubscriberDelegateObjC>> : NSObject<QPublishObjectDelegateObjC> {
#ifdef __cplusplus
    QControllerGW qControllerGW;
#endif
}

@property (nonatomic, strong) PubDelegate publisherDelegate;
@property (nonatomic, strong) SubDelegate subscriberDelegate;

-(instancetype) initCallback:(CantinaLogCallback)callback;
-(int) connect: (NSString*) endpointID
                relay:(NSString*)remoteAddress
                port:(UInt16)remotePort
                protocol:(UInt8)protocol
                chunk_size:(UInt32)chunkSize
                config:(TransportConfig)config
                useParentLogger:(bool)useParentLogger
                encrypt:(bool)encrypt;
-(void) disconnect;
-(bool) connected;
-(void) updateManifest: (NSString*)manifest;
-(void) setSubscriptionSingleOrdered:(bool) new_value;
-(void) setPublicationSingleOrdered:(bool) new_value;
-(void) stopSubscription: (NSString*) quicrNamespace;
-(NSMutableArray*) getSwitchingSets;
-(NSMutableArray*) getSubscriptions: (NSString*) sourceId;
-(NSMutableArray*) getPublications;
-(void) setPublicationState:(NSString*) quicrNamespace publicationState:(PublicationState)publicationState;
-(void) setSubscriptionState:(NSString*) quicrNamespace transportMode:(TransportMode)transportMode;
-(SubscriptionState) getSubscriptionState:(NSString*) quicrNamespace;
@end

#endif /* QControllerGWObj_h */
