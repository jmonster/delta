#ifndef DELTATV_GBAEMULATORBRIDGE_H
#define DELTATV_GBAEMULATORBRIDGE_H
//
//  GBAEmulatorBridge.h
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol DLTAEmulatorBridging;

NS_ASSUME_NONNULL_BEGIN

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface GBAEmulatorBridge : NSObject <DLTAEmulatorBridging>
#pragma clang diagnostic pop

@property (class, nonatomic, readonly) GBAEmulatorBridge *sharedBridge;

@property (nonatomic, readonly) BOOL lastLoadResult;
@property (nonatomic, readonly) BOOL lastBatterySaveResult;
@property (nonatomic, readonly) BOOL lastSaveStateResult;
@property (nonatomic, readonly) BOOL lastLoadStateResult;
@end

NS_ASSUME_NONNULL_END

#endif
