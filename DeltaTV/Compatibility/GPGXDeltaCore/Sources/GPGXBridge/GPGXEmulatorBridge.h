#ifndef DELTATV_GPGXEMULATORBRIDGE_H
#define DELTATV_GPGXEMULATORBRIDGE_H
//
//  GPGXEmulatorBridge.h
//  GPGXBridge
//
//  Created by Riley Testut on 1/21/21.
//  Copyright © 2021 Riley Testut. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol DLTAEmulatorBridging;

NS_ASSUME_NONNULL_BEGIN

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface GPGXEmulatorBridge : NSObject <DLTAEmulatorBridging>
#pragma clang diagnostic pop

@property (class, nonatomic, readonly) GPGXEmulatorBridge *sharedBridge;

@property (nonatomic, readonly) BOOL lastLoadResult;
@property (nonatomic, readonly) BOOL lastBatterySaveResult;
@property (nonatomic, readonly) BOOL lastSaveStateResult;
@property (nonatomic, readonly) BOOL lastLoadStateResult;
@end

NS_ASSUME_NONNULL_END

#endif
