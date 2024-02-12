//
//  QMediaI.h
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#ifndef QControllerGWObc_h
#define QControllerGWObc_h

#import <Foundation/Foundation.h>
#import <os/log.h>

#ifdef __cplusplus
#include "QControllerGW.h"
#include <cantina/logger.h>
#endif

#import "QDelegatesObjC.h"
#import "TransportConfig.h"

typedef void(*QControllerLogCallback)(os_log_type_t, const char*);

@interface QControllerGWObjC<PubDelegate: id<QPublisherDelegateObjC>,
                             SubDelegate: id<QSubscriberDelegateObjC>> : NSObject<QPublishObjectDelegateObjC> {
#ifdef __cplusplus
    QControllerGW qControllerGW;
#endif
}

@property (nonatomic, strong) PubDelegate publisherDelegate;
@property (nonatomic, strong) SubDelegate subscriberDelegate;

-(instancetype) initCallback:(QControllerLogCallback)callback;
-(int) connect: (NSString*)remoteAddress
                port:(UInt16)remotePort
                protocol:(UInt8)protocol
                config:(TransportConfig)config;
-(void) disconnect;
-(bool) connected;
-(void) updateManifest: (NSString*)manifest;
-(void) setSubscriptionSingleOrdered:(bool) new_value;
-(void) setPublicationSingleOrdered:(bool) new_value;
-(void) stopSubscription: (NSString*) quicrNamespace;
-(NSMutableArray*) getSwitchingSets;
-(NSMutableArray*) getSubscriptions: (NSString*) sourceId;
@end

#endif /* QControllerGWObj_h */
