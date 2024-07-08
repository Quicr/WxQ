//
//  QMediaI.m
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#include <stdlib.h>
#import <Foundation/Foundation.h>
#import "QControllerGWObjC.h"
#include "QControllerGW.h"
#include "QMediaDelegates.h"
#include "QDelegatesObjC.h"

// objective c

@implementation PublicationReport
-(id)initWithReport:(qmedia::QController::PublicationReport) report
{
    self = [super init];
    if (self) {
        self.state = static_cast<PublicationState>(static_cast<uint8_t>(report.state));
        NSString* convertedNamespace = [NSString stringWithCString:std::string(report.quicrNamespace).c_str() encoding:[NSString defaultCStringEncoding]];
        self.quicrNamespace = convertedNamespace;
    }
    return self;
}
@end

@implementation QControllerGWObjC

#import "QDelegatesObjC.h"

@synthesize subscriberDelegate;
@synthesize publisherDelegate;


- (id)initCallback:(CantinaLogCallback)callback
{
    self = [super init];
    self->qControllerGW.logger = std::make_shared<cantina::CustomLogger>([=](auto level, const std::string& msg, bool b) {
        NSString* m = [NSString stringWithCString:msg.c_str() encoding:[NSString defaultCStringEncoding]];
        callback(static_cast<uint8_t>(level), m, b);
    });

#ifdef DEBUG
    self->qControllerGW.logger->SetLogLevel(cantina::LogLevel::Debug);
#else
    self->qControllerGW.logger->SetLogLevel(cantina::LogLevel::Info);
#endif

    return self;
}

- (void)dealloc
{
    qControllerGW.logger->debug << "QControllerGW - dealloc" << std::flush;
}

-(int) connect: (NSString *) endpointID relay:(NSString *)remoteAddress port:(UInt16)remotePort protocol:(UInt8)protocol chunk_size:(UInt32)chunkSize config:(TransportConfig)config useParentLogger:(bool)useParentLogger encrypt:(bool)encrypt
{
    try {
        qtransport::TransportConfig tconfig;
        static_assert(std::is_trivially_copyable<qtransport::TransportConfig>() &&
                      std::is_trivially_copyable<TransportConfig>() &&
                      sizeof(tconfig) == sizeof(config));
        
        memcpy(&tconfig, &config, sizeof(tconfig));
        
        
        std::string qlog_path;
        
        if (config.quic_qlog_path != nullptr) {
            qlog_path = config.quic_qlog_path;
            tconfig.quic_qlog_path = const_cast<char *>(qlog_path.c_str());
        } else {
            tconfig.quic_qlog_path = nullptr;
        }
            
        return qControllerGW.connect(std::string([endpointID UTF8String]), std::string([remoteAddress UTF8String]), remotePort, protocol, chunkSize, tconfig, useParentLogger, encrypt);
    } catch(const std::exception& e) {
        qControllerGW.logger->error << "Failed to connect: " << e.what() << std::flush;
        return -1;
    } catch(...) {
        qControllerGW.logger->error << "Failed to connect due to unknown error" << std::flush;
        return -1;
    }
}

-(bool)connected
{
    return qControllerGW.connected();
}

-(void)disconnect
{
    @try
    {
        qControllerGW.disconnect();
    }
    @catch(...)
    {
        @throw;
    }
}

-(void)updateManifest:(NSString*)manifest
{
    qControllerGW.updateManifest(std::string([manifest UTF8String]));
}

-(void)setSubscriberDelegate:(id<QSubscriberDelegateObjC>)delegate
{
    subscriberDelegate = delegate;
    qControllerGW.setSubscriberDelegate(delegate);
}

-(void)setPublisherDelegate:(id<QPublisherDelegateObjC>)delegate
{
    publisherDelegate = delegate;
    qControllerGW.setPublisherDelegate(delegate);
}

- (id<QSubscriptionDelegateObjC>)allocateSubBySourceId:(NSString *)sourceId profileSet:(QClientProfileSet)profileSet {
    if (!subscriberDelegate) return nil;
    return  [subscriberDelegate allocateSubBySourceId:sourceId profileSet:profileSet];
}

- (id<QPublicationDelegateObjC>)allocatePubByNamespace:(NSString *)quicrNamepace sourceID:(NSString*)sourceID qualityProfile:(NSString*)qualityProfile appTag:(NSString*)appTag {
    if (!publisherDelegate) return nil;
    return  [publisherDelegate allocatePubByNamespace:quicrNamepace sourceID:sourceID qualityProfile:qualityProfile];
}

- (int)removeByNamespace:(NSString *)quicrNamepace {
    // pass on to delegate...
    // fixme - which one?
    return 0;
}

- (void)publishObject:(NSString *)quicrNamespace data:(NSData *)data group:(bool) groupFlag {
    qControllerGW.publishNamedObject(std::string([quicrNamespace UTF8String]), (std::uint8_t *)data.bytes, (int)data.length, groupFlag);
}

- (void) publishObject: (NSString*) quicrNamespace data: (const void *) dataPtr length: (size_t) dataLen group: (bool) groupFlag
{
    qControllerGW.publishNamedObject(std::string([quicrNamespace UTF8String]), (std::uint8_t *)dataPtr, (int)dataLen, groupFlag);
}

- (void) setSubscriptionSingleOrdered:(bool)new_value {
    qControllerGW.setSubscriptionSingleOrdered(new_value);
}

- (void) setPublicationSingleOrdered:(bool)new_value {
    qControllerGW.setPublicationSingleOrdered(new_value);
}

- (void)stopSubscription:(NSString *)quicrNamespace { 
    qControllerGW.stopSubscription(std::string([quicrNamespace UTF8String]));
}

- (NSMutableArray*)getSwitchingSets {
    const auto& switchingSets = qControllerGW.getSwitchingSets();
    NSMutableArray *array = [[NSMutableArray alloc]init];
    for (const auto& sourceId : switchingSets) {
        NSString* converted = [NSString stringWithCString:sourceId.c_str() encoding:[NSString defaultCStringEncoding]];
        [array addObject: converted];
    }
    return array;
}

- (NSMutableArray*)getSubscriptions: (NSString *)sourceId {
    const auto& subscriptions = qControllerGW.getSubscriptions(std::string(sourceId.UTF8String));
    NSMutableArray *array = [[NSMutableArray alloc]init];
    for (const auto& quicrNamespace: subscriptions) {
        NSString* converted = [NSString stringWithCString:std::string(quicrNamespace).c_str() encoding:[NSString defaultCStringEncoding]];
        [array addObject: converted];
    }
    return array;
}

- (NSMutableArray*)getPublications {
    const auto& publications = qControllerGW.getPublications();
    NSMutableArray *array = [[NSMutableArray alloc]init];
    for (const auto& report : publications) {
        const PublicationReport* converted = [[PublicationReport alloc] initWithReport:report];
        [array addObject: converted];
    }
    return array;
}

- (void)setPublicationState:(NSString *)quicrNamespace publicationState:(PublicationState)publicationState {
    const quicr::Namespace convertedNs = std::string_view([quicrNamespace UTF8String]);
    const qmedia::QController::PublicationState convertedState = static_cast<qmedia::QController::PublicationState>(publicationState);
    qControllerGW.setPublicationState(convertedNs, convertedState);
}

- (void)setSubscriptionState:(NSString*)quicrNamespace transportMode:(TransportMode)transportMode {
    const quicr::Namespace convertedNs = std::string_view([quicrNamespace UTF8String]);
    const quicr::TransportMode converted = static_cast<quicr::TransportMode>(static_cast<uint8_t>(transportMode));
    qControllerGW.setSubscriptionState(convertedNs, converted);
}

- (SubscriptionState)getSubscriptionState:(NSString*)quicrNamespace {
    const quicr::Namespace convertedNs = std::string_view([quicrNamespace UTF8String]);
    const quicr::SubscriptionState converted = qControllerGW.getSubscriptionState(convertedNs);
    return static_cast<SubscriptionState>(static_cast<std::uint8_t>(converted));
}

@end

// C++

int QControllerGW::connect(const std::string endpoint_id,
                           const std::string remote_address,
                           std::uint16_t remote_port,
                           std::uint16_t protocol,
                           size_t chunk_size,
                           qtransport::TransportConfig config,
                           bool useParentLogger,
                           bool encrypt)
{
    qController = std::make_unique<qmedia::QController>(subscriberDelegate, publisherDelegate, useParentLogger ? logger : nullptr, false, encrypt ? std::optional<sframe::CipherSuite>(qmedia::Default_Cipher_Suite) : std::nullopt);
    if (qController == nullptr)
        return -1;

    quicr::RelayInfo::Protocol proto = quicr::RelayInfo::Protocol(protocol);
    std::string address = remote_address;
    return qController->connect(endpoint_id, address, remote_port, proto, chunk_size, config);
}

bool QControllerGW::connected()
{
    if (!qController)
    {
        logger->error << "QControllerGW::connected - qController nil" << std::flush;
        return false;
    }

    return qController->connected();
}

void QControllerGW::disconnect()
{
    if (!qController)
    {
        logger->error << "QControllerGW::disconnect - qController nil" << std::flush;
        return;
    }

    qController->disconnect();
 }

void QControllerGW::updateManifest(const std::string manifest)
{
    if (qController)
    {
        qController->updateManifest(json::parse(manifest).get<qmedia::manifest::Manifest>());
    }
    else
    {
        logger->error << "QControllerGW::updateManifest - qController nil" << std::flush;
    }
}

void QControllerGW::setSubscriberDelegate(id<QSubscriberDelegateObjC> delegate)
{
    subscriberDelegate = std::make_shared<qclient::QMediaSubsciberDelegate>(delegate);
}

void QControllerGW::setPublisherDelegate(id<QPublisherDelegateObjC> delegate)
{
    publisherDelegate = std::make_shared<qclient::QMediaPublisherDelegate>(delegate) ;
}

// QPublishObject Delegate Method
void QControllerGW::publishNamedObject(const std::string quicrNamespaceString, std::uint8_t *data, int len, bool groupFlag)
{
    if (qController)
    {
        qController->publishNamedObject(std::string_view(quicrNamespaceString), data, len, groupFlag);
    }
    else
    {
        logger->error << "QControllerGW::publishNamedObject - qController nil" << std::flush;
    }
}

void QControllerGW::setSubscriptionSingleOrdered(bool new_value) {
    qController->setSubscriptionSingleOrdered(new_value);
}

void QControllerGW::setPublicationSingleOrdered(bool new_value) {
    qController->setPublicationSingleOrdered(new_value);
}

void QControllerGW::stopSubscription(const std::string& quicrNamespaceString)
{
    if (qController)
    {
        qController->stopSubscription(std::string_view(quicrNamespaceString));
    }
    else
    {
        logger->error << "QControllerGW::stopSubscription - qController nil" << std::flush;
    }
}

std::vector<std::string> QControllerGW::getSwitchingSets()
{
    assert(qController);
    return qController->getSwitchingSets();
}

std::vector<quicr::Namespace> QControllerGW::getSubscriptions(const std::string& sourceId) {
    assert(qController);
    return qController->getSubscriptions(sourceId);
}

std::vector<qmedia::QController::PublicationReport> QControllerGW::getPublications() {
    assert(qController);
    return qController->getPublications();
}

void QControllerGW::setPublicationState(const quicr::Namespace& quicrNamespace, const qmedia::QController::PublicationState publicationState) {
    assert(qController);
    return qController->setPublicationState(quicrNamespace, publicationState);
}

void QControllerGW::setSubscriptionState(const quicr::Namespace& quicrNamespace, const quicr::TransportMode transportMode)
{
    assert(qController);
    return qController->setSubscriptionState(quicrNamespace, transportMode);
}

quicr::SubscriptionState QControllerGW::getSubscriptionState(const quicr::Namespace& quicrNamespace)
{
    assert(qController);
    return qController->getSubscriptionState(quicrNamespace);
}
