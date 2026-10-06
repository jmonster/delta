//
//  GBAEmulatorBridge.m
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

#import "GBAEmulatorBridge.h"
#import "GBASoundDriver.h"

#import <TargetConditionals.h>
#if !TARGET_OS_TV
#import <CoreMotion/CoreMotion.h>
#endif

// VBA-M
#include "System.h"
#include "gba/Sound.h"
#include "gba/GBA.h"
#include "gba/Globals.h"
#include "gba/Cheats.h"
#include "gba/RTC.h"
#include "gba/EEprom.h"
#include "gba/Flash.h"
#include <zlib.h>
#include "Util.h"

#include <sys/time.h>

// Pinned VBA-M's remembered save type, also used by its battery writer.
extern int gbaSaveType;

static bool CompleteGzip(const void *bytes, unsigned length)
{
    z_stream stream = {};
    stream.next_in = (Bytef *)bytes;
    stream.avail_in = length;
    if (inflateInit2(&stream, 15 + 16) != Z_OK) return false;
    unsigned char output[65536];
    int result;
    do {
        stream.next_out = output;
        stream.avail_out = sizeof(output);
        result = inflate(&stream, Z_NO_FLUSH);
    } while (result == Z_OK && stream.total_out < 16 * 1024 * 1024);
    bool complete = result == Z_STREAM_END && stream.avail_in == 0;
    inflateEnd(&stream);
    return complete;
}

// DeltaCore
#import <GBADeltaCore/GBADeltaCore.h>
#import <DeltaCore/DeltaCore.h>
#import <DeltaCore/DeltaCore-Swift.h>

#if STATIC_LIBRARY
#import "GBADeltaCore-Swift.h"
#import "GBATypes.h"
#else
#import <GBADeltaCore/GBADeltaCore-Swift.h>
#endif

// Required vars, used by the emulator core
//
int  systemRedShift = 19;
int  systemGreenShift = 11;
int  systemBlueShift = 3;
int  systemColorDepth = 32;
int  systemVerbose;
int  systemSaveUpdateCounter = 0;
int  systemFrameSkip;
uint32_t  systemColorMap32[0x10000];
uint16_t  systemColorMap16[0x10000];
uint16_t  systemGbPalette[24];

int  emulating;
int  RGB_LOW_BITS_MASK;

@interface GBAEmulatorBridge ()

@property (nonatomic, copy, nullable, readwrite) NSURL *gameURL;

@property (assign, nonatomic, getter=isFrameReady) BOOL frameReady;

@property (nonatomic) uint32_t activatedInputs;

#if !TARGET_OS_TV
@property (strong, nonatomic, readonly) CMMotionManager *motionManager;
#endif

@end

@implementation GBAEmulatorBridge
@synthesize lastLoadResult = _lastLoadResult;
@synthesize lastBatterySaveResult = _lastBatterySaveResult;
@synthesize lastSaveStateResult = _lastSaveStateResult;
@synthesize lastLoadStateResult = _lastLoadStateResult;

@synthesize audioRenderer = _audioRenderer;
@synthesize videoRenderer = _videoRenderer;
@synthesize saveUpdateHandler = _saveUpdateHandler;

+ (instancetype)sharedBridge
{
    static GBAEmulatorBridge *_emulatorBridge = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _emulatorBridge = [[self alloc] init];
    });

    return _emulatorBridge;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
#if !TARGET_OS_TV
        _motionManager = [[CMMotionManager alloc] init];
#endif
    }

    return self;
}

#pragma mark - Emulation -

- (void)startWithGameURL:(NSURL *)URL
{
    self.gameURL = URL;
    _lastLoadResult = NO;

    NSData *data = [NSData dataWithContentsOfURL:URL];

    if (!CPULoadRomData((const char *)data.bytes, (int)data.length))
    {
        return;
    }

    utilUpdateSystemColorMaps(NO);
    utilGBAFindSave((int)data.length);

    // Update per-game settings after utilGBAFindSave determines defaults.
    [self updateGameSettings];

    soundInit();
    soundSetSampleRate(32768); // 44100 chirps

    soundReset();

    CPUInit(0, false);

    GBASystem.emuReset();

    emulating = 1;
    _lastLoadResult = YES;
}

- (void)stop
{
    GBASystem.emuCleanUp();
    soundShutdown();

    emulating = 0;

    [self deactivateGyroscope];
}

- (void)pause
{
    emulating = 0;

    [self deactivateGyroscope];
}

- (void)resume
{
    emulating = 1;
}

- (void)runFrameAndProcessVideo:(BOOL)processVideo
{
    if (!_lastLoadResult) return;
    self.frameReady = NO;

    int iterations = 0;
    while (![self isFrameReady] && iterations++ < 64)
    {
        GBASystem.emuMain(GBASystem.emuCount);
    }
    if (![self isFrameReady]) _lastLoadResult = NO;
}

- (nullable NSData *)readMemoryAtAddress:(NSInteger)address size:(NSInteger)size
{
    if (workRAM == NULL)
    {
        return nil;
    }

    void *bytes = NULL;
    if (address >= 0x8000)
    {
        bytes = (void *)(workRAM + address - 0x8000);
    }
    else
    {
        bytes = (void *)(internalRAM + address);
    }

    NSData *data = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:NO];
    return data;
}

#pragma mark - Settings -

- (void)updateGameSettings
{
    NSString *gameID = [NSString stringWithFormat:@"%c%c%c%c", rom[0xac], rom[0xad], rom[0xae], rom[0xaf]];

    NSLog(@"VBA-M: GameID in ROM is: %@", gameID);

    // Set defaults
    // Use underscores to prevent shadowing of global variables
    BOOL _enableRTC       = NO;
    BOOL _enableMirroring = NO;
    BOOL _useBIOS         = NO;
    int  _cpuSaveType     = 0;
    int  _flashSize       = 0x10000;

    // Read in vba-over.ini and break it into an array of strings
    NSString *iniPath = [GBAEmulatorBridge.gbaResources pathForResource:@"vba-over" ofType:@"ini"];
    NSString *iniString = [NSString stringWithContentsOfFile:iniPath encoding:NSUTF8StringEncoding error:NULL];
    NSArray *settings = [iniString componentsSeparatedByString:@"\n"];

    BOOL matchFound = NO;
    NSMutableDictionary *overridesFound = [[NSMutableDictionary alloc] init];
    NSString *temp;

    // Check if vba-over.ini has per-game settings for our gameID
    for (NSString *s in settings)
    {
        temp = nil;

        if ([s hasPrefix:@"["])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"[" intoString:nil];
            [scanner scanUpToString:@"]" intoString:&temp];

            if ([temp caseInsensitiveCompare:gameID] == NSOrderedSame)
            {
                matchFound = YES;
            }

            continue;
        }

        else if (matchFound && [s hasPrefix:@"saveType="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"saveType=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _cpuSaveType = [temp intValue];
            [overridesFound setObject:temp forKey:@"CPU saveType"];

            continue;
        }

        else if (matchFound && [s hasPrefix:@"rtcEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"rtcEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableRTC = [temp boolValue];
            [overridesFound setObject:temp forKey:@"rtcEnabled"];

            continue;
        }

        else if (matchFound && [s hasPrefix:@"flashSize="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"flashSize=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _flashSize = [temp intValue];
            [overridesFound setObject:temp forKey:@"flashSize"];

            continue;
        }

        else if (matchFound && [s hasPrefix:@"mirroringEnabled="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"mirroringEnabled=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _enableMirroring = [temp boolValue];
            [overridesFound setObject:temp forKey:@"mirroringEnabled"];

            continue;
        }

        else if (matchFound && [s hasPrefix:@"useBios="])
        {
            NSScanner *scanner = [NSScanner scannerWithString:s];
            [scanner scanString:@"useBios=" intoString:nil];
            [scanner scanUpToString:@"\n" intoString:&temp];
            _useBIOS = [temp boolValue];
            [overridesFound setObject:temp forKey:@"useBios"];

            continue;
        }

        else if (matchFound)
            break;
    }

    // Some hacked games use the RealTimeClock even when the game they're based off of doesn't (ex: Pokemon Liquid Crystal), so we always have it enabled.
    rtcEnable(true);

    if (!matchFound)
    {
        // Only update remaining settings if we found a match.
        return;
    }

    NSLog(@"VBA: overrides found: %@", overridesFound);

    // Apply settings
    mirroringEnable = _enableMirroring;
    doMirroring(mirroringEnable);
    cpuSaveType = _cpuSaveType;

    // Delta doesn't use BIOS files.
    // useBios = _useBIOS;

    if (_flashSize == 0x10000 || _flashSize == 0x20000)
    {
        flashSetSize(_flashSize);
    }

}

#pragma mark - Inputs -

- (void)activateInput:(NSInteger)gameInput value:(double)value playerIndex:(NSInteger)playerIndex
{
    self.activatedInputs |= (uint32_t)gameInput;
}

- (void)deactivateInput:(NSInteger)gameInput playerIndex:(NSInteger)playerIndex
{
    self.activatedInputs &= ~((uint32_t)gameInput);
}

- (void)resetInputs
{
    self.activatedInputs = 0;
}

#pragma mark - Game Saves -

- (void)saveGameSaveToURL:(NSURL *)URL
{
    _lastBatterySaveResult = NO;
    if (!_lastLoadResult) return;
    if (gbaSaveType == 0) {
        if (eepromInUse) gbaSaveType = 3;
        else if (saveType == 1 || saveType == 2) gbaSaveType = saveType;
    }
    if (gbaSaveType == 0 || gbaSaveType == 5) { _lastBatterySaveResult = YES; return; }
    int size = gbaSaveType == 3 ? eepromSize : (gbaSaveType == 2 ? flashSize : 32768);
    if (size <= 0 || size > (gbaSaveType == 3 ? sizeof(eepromData) : sizeof(flashSaveMemory))) return;
    NSData *data = [NSData dataWithBytes:(gbaSaveType == 3 ? eepromData : flashSaveMemory) length:size];
    _lastBatterySaveResult = [data writeToURL:URL options:NSDataWritingAtomic error:nil];
}

- (void)loadGameSaveFromURL:(NSURL *)URL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:URL.path]) return;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:URL.path error:nil];
    NSUInteger size = [attributes[NSFileSize] unsignedIntegerValue];
    if (![@[@512, @8192, @32768, @65536, @131072] containsObject:@(size)] || !GBASystem.emuReadBattery(URL.fileSystemRepresentation))
    { _lastLoadResult = NO; return; }
    // The pinned VBA-M reader loads EEPROM bytes but leaves the default 512-byte
    // size until game autodetection. An immediate checkpoint must retain all 8 KB.
    if (size == 512 || size == 8192) {
        eepromSize = (int)size;
        eepromInUse = true;
    } else {
        eepromInUse = false;
    }
}

#pragma mark - Save States -

- (void)saveSaveStateToURL:(NSURL *)URL
{
    _lastSaveStateResult = NO;
    if (!_lastLoadResult) return;
    NSMutableData *memory = [NSMutableData dataWithLength:4 * 1024 * 1024];
    long reserved = 0;
    if (!GBASystem.emuWriteMemState((char *)memory.mutableBytes, (int)memory.length, reserved)) return;
    // memgz adds an eight-byte wrapper. Its final length includes the gzip trailer.
    unsigned length = 0;
    memcpy(&length, (const char *)memory.bytes + 4, sizeof(length));
    if (!length || length > memory.length - 8 || !CompleteGzip((const char *)memory.bytes + 8, length)) return;
    NSData *data = [NSData dataWithBytes:(const char *)memory.bytes + 8 length:length];
    _lastSaveStateResult = [data writeToURL:URL options:NSDataWritingAtomic error:nil];
}

- (void)loadSaveStateFromURL:(NSURL *)URL
{
    _lastLoadStateResult = _lastLoadResult && GBASystem.emuReadState(URL.fileSystemRepresentation);
}

#pragma mark - Cheats -

- (BOOL)addCheatCode:(NSString *)cheatCode type:(NSString *)type
{
    NSArray<NSString *> *codes = [cheatCode componentsSeparatedByString:@"\n"];
    for (NSString *code in codes)
    {
        NSMutableCharacterSet *legalCharactersSet = [NSMutableCharacterSet hexadecimalCharacterSet];
        [legalCharactersSet addCharactersInString:@" "];

        if ([code rangeOfCharacterFromSet:[legalCharactersSet invertedSet]].location != NSNotFound)
        {
            return NO;
        }

        if ([type isEqualToString:CheatTypeActionReplay] || [type isEqualToString:CheatTypeGameShark])
        {
            NSString *sanitizedCode = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

            if (sanitizedCode.length != 16)
            {
                return NO;
            }

            cheatsAddGSACode([sanitizedCode UTF8String], "code", true);
        }
        else if ([type isEqualToString:CheatTypeCodeBreaker])
        {
            if (code.length != 13)
            {
                return NO;
            }

            cheatsAddCBACode([code UTF8String], "code");
        }
    }

    return YES;
}

- (void)resetCheats
{
    cheatsDeleteAll(true);
}

- (void)updateCheats
{

}

#pragma mark - Gyroscope -

- (void)activateGyroscope
{
#if !TARGET_OS_TV
    if ([self.motionManager isGyroActive] || ![self.motionManager isGyroAvailable])
    {
        return;
    }

    [self.motionManager startGyroUpdates];

    [[NSNotificationCenter defaultCenter] postNotificationName:GBADidActivateGyroNotification object:self];
#endif
}

- (void)deactivateGyroscope
{
#if !TARGET_OS_TV
    if (![self.motionManager isGyroActive])
    {
        return;
    }

    [self.motionManager stopGyroUpdates];

    [[NSNotificationCenter defaultCenter] postNotificationName:GBADidDeactivateGyroNotification object:self];
#endif
}

#pragma mark - Getters/Setters -

- (NSTimeInterval)frameDuration
{
    return (1.0 / 60.0);
}

@end

#pragma mark - VBA-M -

void systemMessage(int _iId, const char * _csFormat, ...)
{
    NSLog(@"VBA-M: %s", _csFormat);
}

void systemDrawScreen()
{
    // Get rid of the first line and the last row
    for (int y = 0; y < 160; y++)
    {
        memcpy([GBAEmulatorBridge sharedBridge].videoRenderer.videoBuffer + y * 240 * 4, pix + (y + 1) * (240 + 1) * 4, 240 * 4);
    }

    [[GBAEmulatorBridge sharedBridge].videoRenderer processFrame];
    [[GBAEmulatorBridge sharedBridge] setFrameReady:YES];
}

bool systemReadJoypads()
{
    return true;
}

uint32_t systemReadJoypad(int joy)
{
    return [GBAEmulatorBridge sharedBridge].activatedInputs;
}

void systemShowSpeed(int _iSpeed)
{

}

void system10Frames(int _iRate)
{
    if (systemSaveUpdateCounter > 0)
    {
        systemSaveUpdateCounter--;

        if (systemSaveUpdateCounter <= SYSTEM_SAVE_NOT_UPDATED)
        {
            if (GBAEmulatorBridge.sharedBridge.saveUpdateHandler)
            {
                GBAEmulatorBridge.sharedBridge.saveUpdateHandler();
            }

            systemSaveUpdateCounter = SYSTEM_SAVE_NOT_UPDATED;
        }
    }
}

void systemFrame()
{

}

void systemSetTitle(const char * _csTitle)
{

}

void systemScreenCapture(int _iNum)
{

}

uint32_t systemGetClock()
{
    timeval time;

    gettimeofday(&time, NULL);

    double milliseconds = (time.tv_sec * 1000.0) + (time.tv_usec / 1000.0);
    return milliseconds;
}

SoundDriver *systemSoundInit()
{
    soundShutdown();

    auto driver = new GBASoundDriver;
    return driver;
}

void systemUpdateMotionSensor()
{
}

uint8_t systemGetSensorDarkness()
{
    return 0;
}

int systemGetSensorX()
{
    return 0;
}

int systemGetSensorY()
{
    return 0;
}

int systemGetSensorZ()
{
#if TARGET_OS_TV
    return 0;
#else
    if (![GBAEmulatorBridge.sharedBridge.motionManager isGyroActive])
    {
        [GBAEmulatorBridge.sharedBridge activateGyroscope];
    }

    CMGyroData *gyroData = GBAEmulatorBridge.sharedBridge.motionManager.gyroData;

    int sensorZ = -gyroData.rotationRate.z * 25;
    return sensorZ;
#endif
}

void systemCartridgeRumble(bool)
{
}

void systemGbPrint(uint8_t * _puiData,
                   int  _iLen,
                   int  _iPages,
                   int  _iFeed,
                   int  _iPalette,
                   int  _iContrast)
{
}

void systemScreenMessage(const char * _csMsg)
{
}

bool systemCanChangeSoundQuality()
{
    return true;
}

bool systemPauseOnFrame()
{
    return false;
}

void systemGbBorderOn()
{
}

void systemOnSoundShutdown()
{
}

void systemOnWriteDataToSoundBuffer(const uint16_t * finalWave, int length)
{
}

void debuggerMain()
{
}

void debuggerSignal(int, int)
{
}

void log(const char *defaultMsg, ...)
{
    static FILE *out = NULL;

    if(out == NULL) {
        out = fopen("trace.log","w");
    }

    va_list valist;

    va_start(valist, defaultMsg);
    vfprintf(out, defaultMsg, valist);
    va_end(valist);
}
