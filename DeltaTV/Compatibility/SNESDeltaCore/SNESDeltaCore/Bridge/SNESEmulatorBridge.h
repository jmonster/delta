#ifndef DELTATV_SNESEMULATORBRIDGE_H
#define DELTATV_SNESEMULATORBRIDGE_H
//
//  SNESEmulatorBridge.h
//  SNESDeltaCore
//
//  Created by Riley Testut on 9/12/15.
//  Copyright © 2015 Riley Testut. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol DLTAEmulatorBridging;

NS_ASSUME_NONNULL_BEGIN

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface SNESEmulatorBridge : NSObject <DLTAEmulatorBridging>
#pragma clang diagnostic pop

@property (class, nonatomic, readonly) SNESEmulatorBridge *sharedBridge;

@property (nonatomic, readonly) BOOL lastLoadResult;
@property (nonatomic, readonly) BOOL lastBatterySaveResult;
@property (nonatomic, readonly) BOOL lastSaveStateResult;
@property (nonatomic, readonly) BOOL lastLoadStateResult;
@end

NS_ASSUME_NONNULL_END

#endif
