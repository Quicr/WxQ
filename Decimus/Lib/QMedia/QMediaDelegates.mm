//
//  QDelegatesObjCImpl.m
//  Decimus
//
//  Created by Scott Henning on 5/26/23.
//
#import <Foundation/Foundation.h>

#include <string>
#include <iostream>
#include "qmedia/QDelegates.hpp"
#include "quicr/quicr_common.h"
#include "QMediaDelegates.h"
#import "QControllerGWObjC.h"


#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

namespace qclient
{

// SUBSCRIPTION
QMediaSubscriptionDelegate::QMediaSubscriptionDelegate(id<QSubscriptionDelegateObjC> delegate, const quicr::Namespace& quicrNamespace) :
    delegate(delegate), quicrNamespace(quicrNamespace)
{
}

int QMediaSubscriptionDelegate::prepare(const std::string& sourceId,  const std::string& label, const std::string& qualityProfile, bool& reliable) {
    return [delegate prepare: @(sourceId.c_str()) label:@(label.c_str()) qualityProfile:@(qualityProfile.c_str()) reliable:&reliable];
}

int  QMediaSubscriptionDelegate::update(const std::string& sourceId,  const std::string& label, const std::string& qualityProfile)  {
    return [delegate update:@(sourceId.c_str()) label:@(label.c_str()) qualityProfile:@(qualityProfile.c_str())];
}
/*
quicr::Namespace QMediaSubscriptionDelegate::getNamespace() {
    return quicrNamespace;
}*/

int QMediaSubscriptionDelegate::subscribedObject(quicr::bytes&& data, std::uint32_t group, std::uint16_t object) {
    NSData * nsdata= [NSData dataWithBytes:data.data() length:data.size()];
    return [delegate subscribedObject:nsdata groupId:group objectId:object];
}


// PUBLICATION
QMediaPublicationDelegate::QMediaPublicationDelegate(id<QPublicationDelegateObjC> delegate, const quicr::Namespace& quicrNamespace) :
    qmedia::QPublicationDelegate(quicrNamespace),
    delegate(delegate), quicrNamespace(quicrNamespace)
{
}

int QMediaPublicationDelegate::prepare(const std::string& sourceId,  const std::string& qualityProfile, bool& reliable)  {
    return [delegate prepare:@(sourceId.c_str()) qualityProfile:@(qualityProfile.c_str()) reliable:&reliable];
}
int QMediaPublicationDelegate::update(const std::string& sourceId, const std::string& qualityProfile) {
    return [delegate update:@(sourceId.c_str()) qualityProfile:@(qualityProfile.c_str())];
}
/*
quicr::Namespace QMediaPublicationDelegate::getNamespace()  {
    return;
}*/

void QMediaPublicationDelegate::publish(bool pubFlag) {
    return [delegate publish: pubFlag];
}

// SUBSCRIBER
QMediaSubsciberDelegate::QMediaSubsciberDelegate(id<QSubscriberDelegateObjC> delegate) : delegate(delegate)
{
}

std::shared_ptr<qmedia::QSubscriptionDelegate> QMediaSubsciberDelegate::allocateSubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& qualityProfile)
{
    NSString *quicrNamespaceNSString = [NSString stringWithCString:std::string(quicrNamespace).c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *qualityProfileNSString = [NSString stringWithCString:qualityProfile.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    id<QSubscriptionDelegateObjC> subscription = [delegate allocateSubByNamespace:quicrNamespaceNSString qualityProfile:qualityProfileNSString];
    return std::make_shared<qclient::QMediaSubscriptionDelegate>(subscription, quicrNamespace);
}

int QMediaSubsciberDelegate::removeSubByNamespace(const quicr::Namespace& quicrNamespace)
{
   return 0;
}

// PUBLISHER

QMediaPublisherDelegate::QMediaPublisherDelegate(id<QPublisherDelegateObjC> delegate) : delegate(delegate)
{
}

std::shared_ptr<qmedia::QPublicationDelegate> QMediaPublisherDelegate::allocatePubByNamespace(const quicr::Namespace& quicrNamespace, const std::string& sourceID, const std::string& qualityProfile)
{
    NSString *quicrNamespaceNSString = [NSString stringWithCString:std::string(quicrNamespace).c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *quicrSourceIdNSString = [NSString stringWithCString:sourceID.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    NSString *qualityProfileNSString = [NSString stringWithCString:qualityProfile.c_str()
                                       encoding:[NSString defaultCStringEncoding]];
    id<QPublicationDelegateObjC> publication = [delegate allocatePubByNamespace:quicrNamespaceNSString sourceID:quicrSourceIdNSString qualityProfile:qualityProfileNSString];
    return std::make_shared<qclient::QMediaPublicationDelegate>(publication, quicrNamespace);
}

int QMediaPublisherDelegate::removePubByNamespace(const quicr::Namespace& quicrNamespace)
{
   return 0;
}

};
