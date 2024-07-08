//
//  QControllerGW.h
//  Decimus
//
//  Created by Scott Henning on 2/13/23.
//
#ifndef QControllerGW_h
#define QControllerGW_h

#include "qmedia/QController.hpp"
#include "qmedia/QDelegates.hpp"
#include "transport/transport.h"
#include "QDelegatesObjC.h"
#import "QControllerGWObjC.h"



class QControllerGW {
public:
    QControllerGW() = default;
    ~QControllerGW() = default;

    int connect(const std::string endpoint_id,
                const std::string remote_address,
                std::uint16_t remote_port,
                std::uint16_t protocol,
                size_t chunk_size,
                qtransport::TransportConfig config,
                bool useParentLogger,
                bool encrypt);

    void disconnect();
    bool connected();
    
    void updateManifest(const std::string manifest);
       
    void setSubscriberDelegate(id<QSubscriberDelegateObjC>);
    void setPublisherDelegate(id<QPublisherDelegateObjC>);

    void setSubscriptionSingleOrdered(bool new_value);
    void setPublicationSingleOrdered(bool new_value);

    void publishNamedObject(std::string quicrNamespace, std::uint8_t *data, int len, bool groupFlag);

    void stopSubscription(const std::string& quicrNamespace);
    std::vector<std::string> getSwitchingSets();
    std::vector<quicr::Namespace> getSubscriptions(const std::string& sourceId);
    std::vector<qmedia::QController::PublicationReport> getPublications();
    void setPublicationState(const quicr::Namespace& quicrNamespace, const qmedia::QController::PublicationState);
    void setSubscriptionState(const quicr::Namespace& quicrNamespace, const quicr::TransportMode);
    quicr::SubscriptionState getSubscriptionState(const quicr::Namespace& quicrNamespace);

public:
    std::shared_ptr<cantina::Logger> logger;

private:
    std::unique_ptr<qmedia::QController> qController;
    std::shared_ptr<qmedia::QSubscriberDelegate> subscriberDelegate;
    std::shared_ptr<qmedia::QPublisherDelegate> publisherDelegate;
};

#endif /* QMediaClient */
