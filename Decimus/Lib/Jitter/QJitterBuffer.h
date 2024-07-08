#ifndef QJitterBuffer_h
#define QJitterBuffer_h

#import <Foundation/Foundation.h>

#include "Packet.h"
#include "Metrics.h"
#ifdef __cplusplus
#include <memory>
#include "JitterBuffer.hh"
#endif

typedef void(*PacketCallback)(struct Packet*, size_t, void*);
typedef void(*CantinaLogCallback)(uint8_t, NSString*, bool);

@interface QJitterBuffer : NSObject {
#ifdef __cplusplus
    std::unique_ptr<JitterBuffer> jitterBuffer;
#endif
}

-(instancetype) initElementSize:(size_t)element_size
                    packetElements:(size_t)packet_elements
                    clockRate:(unsigned long)clock_rate
                    maxLengthMs:(unsigned long)max_length_ms
                    minLengthMs:(unsigned long)min_length_ms
                    logCallback:(CantinaLogCallback)logCallback;

-(size_t)prepare:(const unsigned long)sequence_number
                 concealmentCallback:(PacketCallback)concealment_callback
                 userData: (void*)user_data;

-(size_t)enqueuePacket:(struct Packet)packet
                concealmentCallback:(PacketCallback)concealment_callback
                userData: (void*)user_data;

-(size_t)enqueuePackets:(struct Packet[])packets
                size:(size_t)size
                concealmentCallback:(PacketCallback)concealment_callback
                userData: (void*)user_data;

-(size_t)dequeue:(uint8_t*)destination
                destinationLength:(size_t)destination_length
                elements:(size_t)elements;

-(struct Metrics)getMetrics;

-(size_t)getCurrentDepth;

@end

#endif
