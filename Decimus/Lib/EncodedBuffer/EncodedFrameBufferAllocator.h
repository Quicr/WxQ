// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

//
//  EncodedFrameBufferAllocator.h
//  Decimus
//
//  Created by Scott Henning on 7/25/23.
//
#ifndef EncodedFrameBufferAllocator_h
#define EncodedFrameBufferAllocator_h
#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include "ExtBufferAllocator.hh"
#endif

@interface BufferAllocator : NSObject {
    CFAllocatorContext context;
    CFAllocatorRef allocatorRef;
#ifdef __cplusplus
    ExtBufferAllocator *extBufferAllocatorPtr;
#endif
}
- (instancetype) init: (size_t) preAllocSize hdrSize: (size_t) preAllocHdrSize;
- (void) dealloc;
- (CFAllocatorRef) allocator;
- (void *) allocateBufferHeader: (size_t) length;
- (void) retrieveFullBufferPointer: (void **) fullBufferPtr len: (size_t *) length;
- (void *) iosAllocBuffer: (CFIndex) allocSize;
- (void) iosDeallocBuffer: (void *) bufferPtr;
@end

#endif /* EncodedFrameBufferAllocator_h */


