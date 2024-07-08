#import <Foundation/Foundation.h>
#import "QJitterBuffer.h"

#import <Foundation/Foundation.h>

#include <stdlib.h>

#include "Packet.h"
#include "JitterBuffer.hh"

@implementation QJitterBuffer
-(id)initElementSize: (size_t)elementSize
            packetElements:(size_t)packet_elements
            clockRate:(unsigned long)clock_rate
            maxLengthMs:(unsigned long)max_length_ms
            minLengthMs:(unsigned long)min_length_ms
            logCallback:(CantinaLogCallback)logCallback
{
    self = [super init];
    if (self)
    {
        jitterBuffer = std::make_unique<JitterBuffer>(
            elementSize,
            packet_elements,
            clock_rate,
            std::chrono::milliseconds{max_length_ms},
            std::chrono::milliseconds{min_length_ms},
            std::make_shared<cantina::CustomLogger>([=](auto level, const std::string& msg, bool b) {
              NSString* m = [NSString stringWithCString:msg.c_str() encoding:[NSString defaultCStringEncoding]];
              logCallback(static_cast<uint8_t>(level), m, b);
            })
        );
    }
    return self;
}

-(size_t)prepare:(const unsigned long)sequence_number
                 concealmentCallback:(PacketCallback)concealment_callback
                 userData: (void*)user_data
{
    if (!jitterBuffer) return 0;
    try
    {
        return jitterBuffer->Prepare((const std::uint32_t)sequence_number,
                                     [&](std::vector<Packet>& p) { return concealment_callback(p.data(), p.size(), user_data); });
    }
    catch(...)
    {
        return 0;
    }
}

-(size_t)enqueuePacket:(Packet)packet
                concealmentCallback:(PacketCallback)concealment_callback
                userData:(void*)user_data
{
    if (!jitterBuffer) return 0;

    try
    {
        return jitterBuffer->Enqueue({1, packet},
                                     [&](std::vector<Packet>& p) { return concealment_callback(p.data(), p.size(), user_data); });
    }
    catch(...)
    {
        return 0;
    }
}

-(size_t)enqueuePackets:(Packet[])packets
                size:(size_t)size
                concealmentCallback:(PacketCallback)concealment_callback
                userData:(void*)user_data
{
    if (!jitterBuffer) return 0;

    try
    {
        return jitterBuffer->Enqueue({packets, packets + size},
                                     [&](std::vector<Packet>& p) { return concealment_callback(p.data(), p.size(), user_data); });
    }
    catch(...)
    {
        return 0;
    }
}

-(size_t)dequeue:(uint8_t*)destination
                destinationLength:(size_t)destination_length
                elements:(size_t)elements
{
    if (!jitterBuffer) return 0;

    try
    {
        return jitterBuffer->Dequeue(destination, destination_length, elements);
    }
    catch(...)
    {
        return 0;
    }
}

-(Metrics)getMetrics
{
    // if (!jitterBuffer) return 0;
    return jitterBuffer->GetMetrics();
}

-(size_t)getCurrentDepth
{
    return jitterBuffer->GetCurrentDepth().count();
}
@end
