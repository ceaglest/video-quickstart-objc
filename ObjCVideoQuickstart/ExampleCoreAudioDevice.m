//
//  ExampleCoreAudioDevice.m
//  ObjCVideoQuickstart
//
//  Copyright © 2018 Twilio, Inc. All rights reserved.
//

#import "ExampleCoreAudioDevice.h"

// We want to get as close to 10 msec buffers as possible because this is what the media engine prefers.
static double kPreferredIOBufferDuration = 0.01;
// We will use stereo playback where available. Some audio routes may be restricted to mono only.
static size_t const kNumberOfChannels = 2;

#if TARGET_IPHONE_SIMULATOR
static uint32_t kPreferredSampleRate = 44100;
#else
static uint32_t kPreferredSampleRate = 48000;
#endif

typedef struct ExampleCoreAudioContext {
    TVIAudioDeviceContext deviceContext;
    size_t framesPerBuffer;
} ExampleCoreAudioContext;

// The RemoteIO audio unit uses bus 0 for ouptut, and bus 1 for input.
static int kOutputBus = 0;
static int kInputBus = 1;

@interface ExampleCoreAudioDevice()

@property (nonatomic, assign, getter=isInterrupted) BOOL interrupted;
@property (nonatomic, assign) AudioUnit audioUnit;

@property (nonatomic, strong, nullable) TVIAudioFormat *renderingFormat;
@property (nonatomic, assign) ExampleCoreAudioContext *renderingContext;
@property (nonatomic, weak) NSThread *renderingContextThread;

@end

@implementation ExampleCoreAudioDevice

#pragma mark - Init & Dealloc

- (id)init {
    self = [super init];
    if (self) {
        // Setup the AVAudioSession early to workaround lack of dynamic format change support in 2.0.0-preview10 RCs.
        [self setupAVAudioSession];
    }
    return self;
}

- (void)dealloc {
    [self unregisterAVAudioSessionObservers];
}

#pragma mark - TVIAudioDeviceRenderer

- (nullable TVIAudioFormat *)renderFormat {
    if (!_renderingFormat) {
        /*
         * Assume that the AVAudioSession has already been configured and started and that the values
         * for sampleRate and IOBufferDuration are final.
         */
        _renderingFormat = [[self class] activeRenderingFormat];
    }

    return _renderingFormat;
}

- (BOOL)initializeRenderer {
    /*
     * TVIAudioDeviceRenderer methods are called on the media engine's worker thread. You may wish to synchronize
     * outside control logic like handling of AVAudioSession notifications with this thread.
     */
    self.renderingContextThread = [NSThread currentThread];
    NSAssert(self.renderingContextThread != NULL, @"We need an NSThread to synchronize AVAudioSession notifications with!");

    /*
     * In this example we don't need any fixed size buffers or other pre-allocated resources. We will simply write
     * directly to the AudioBufferList provided in the AudioUnit's rendering callback.
     */
    return YES;
}

- (BOOL)startRendering:(nonnull TVIAudioDeviceContext)context {
    NSAssert(self.renderingContext == NULL, @"Should not have any rendering context.");
    self.renderingContext = malloc(sizeof(ExampleCoreAudioContext));
    self.renderingContext->deviceContext = context;
    self.renderingContext->framesPerBuffer = _renderingFormat.framesPerBuffer;

    NSAssert(self.audioUnit == NULL, @"The audio unit should not be created yet.");
    if (![self setupAudioUnit]) {
        return NO;
    }
    return [self startAudioUnit];
}

- (BOOL)stopRendering {
    [self stopAudioUnit];
    [self teardownAudioUnit];

    NSAssert(self.renderingContext != NULL, @"Should have a rendering context.");
    free(self.renderingContext);
    self.renderingContext = NULL;
    self.renderingContextThread = nil;

    return YES;
}

#pragma mark - TVIAudioDeviceCapturer

- (nullable TVIAudioFormat *)captureFormat {
    // We don't support capturing, and return a nil format to indicate this. The other TVIAudioDeviceCapturer methods
    // are simply stubs.
    return nil;
}

- (BOOL)initializeCapturer {
    return NO;
}

- (BOOL)startCapturing:(nonnull TVIAudioDeviceContext)context {
    return NO;
}

- (BOOL)stopCapturing {
    return NO;
}

#pragma mark - Private (AudioUnit callbacks)

static OSStatus playout_cb(void *refCon,
                           AudioUnitRenderActionFlags *actionFlags,
                           const AudioTimeStamp *timestamp,
                           UInt32 busNumber,
                           UInt32 numFrames,
                           AudioBufferList *bufferList) {
    assert(bufferList->mNumberBuffers == 1);
    assert(bufferList->mBuffers[0].mNumberChannels <= 2);
    assert(bufferList->mBuffers[0].mNumberChannels > 0);

    ExampleCoreAudioContext *context = (ExampleCoreAudioContext *)refCon;
    int8_t *audioBuffer = (int8_t *)bufferList->mBuffers[0].mData;
    UInt32 audioBufferSizeInBytes = bufferList->mBuffers[0].mDataByteSize;

    // Render silence if there are temporary mismatches.
    // TODO: Will there ever be a case where stopping the AudioUnit from audioContextThread is non blocking?
    if (numFrames != context->framesPerBuffer) {
        NSLog(@"Expected %u frames but got %u.", (unsigned int)context->framesPerBuffer, (unsigned int)numFrames);
        *actionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        memset(audioBuffer, 0, audioBufferSizeInBytes);
        return noErr;
    }

    readRenderData(context->deviceContext, audioBuffer, audioBufferSizeInBytes);
    return noErr;
}

#pragma mark - Private (AVAudioSession and CoreAudio)

+ (nullable TVIAudioFormat *)activeRenderingFormat {
    const NSTimeInterval sessionBufferDuration = [AVAudioSession sharedInstance].IOBufferDuration;
    const double sessionSampleRate = [AVAudioSession sharedInstance].sampleRate;
    const NSInteger sessionOutputChannels = [AVAudioSession sharedInstance].outputNumberOfChannels;
    size_t rendererChannels = sessionOutputChannels >= TVIAudioChannelsStereo ? TVIAudioChannelsStereo : TVIAudioChannelsMono;
    const size_t sessionFramesPerBuffer = (size_t)(sessionSampleRate * sessionBufferDuration + .5);

    return [[TVIAudioFormat alloc] initWithChannels:(size_t)rendererChannels
                                         sampleRate:sessionSampleRate
                                    framesPerBuffer:sessionFramesPerBuffer];
}

- (void)setupAVAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    if (![session setPreferredSampleRate:kPreferredSampleRate error:&error]) {
        NSLog(@"Error setting sample rate: %@", error);
    }

    if (![session setPreferredOutputNumberOfChannels:kNumberOfChannels error:&error]) {
        NSLog(@"Error setting number of output channels: %@", error);
    }

    // We want to be as close as possible to the 10 millisecond buffer size that the media engine needs. If there is
    // a mismatch then TwilioVideo will ensure that appropriately sized audio buffers are delivered.
    if (![session setPreferredIOBufferDuration:kPreferredIOBufferDuration error:&error]) {
        NSLog(@"Error setting IOBuffer duration: %@", error);
    }

    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        NSLog(@"Error setting session category: %@", error);
    }

    [self registerAVAudioSessionObservers];

    if (![session setActive:YES error:&error]) {
        NSLog(@"Error activating AVAudioSession: %@", error);
    }

    if (![session setPreferredInputNumberOfChannels:TVIAudioChannelsMono error:&error]) {
        NSLog(@"Error setting number of input channels: %@", error);
    }
}

- (BOOL)setupAudioUnit {
    // Find and instantiate the RemoteIO audio unit.
    AudioComponentDescription audioUnitDescription;
    audioUnitDescription.componentType = kAudioUnitType_Output;
    audioUnitDescription.componentSubType = kAudioUnitSubType_RemoteIO;
    audioUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    audioUnitDescription.componentFlags = 0;
    audioUnitDescription.componentFlagsMask = 0;

    AudioComponent audioComponent = AudioComponentFindNext(NULL, &audioUnitDescription);

    OSStatus status = AudioComponentInstanceNew(audioComponent, &_audioUnit);
    if (status != 0) {
        NSLog(@"Could not find RemoteIO AudioComponent instance!");
        return NO;
    }

    // Configure the RemoteIO audio unit.
    AudioStreamBasicDescription streamDescription = self.renderingFormat.streamDescription;

    UInt32 enableOutput = 1;
    status = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output, kOutputBus,
                                  &enableOutput, sizeof(enableOutput));
    if (status != 0) {
        NSLog(@"Could not enable output bus!");
        return NO;
    }

    status = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, kOutputBus,
                                  &streamDescription, sizeof(streamDescription));
    if (status != 0) {
        NSLog(@"Could not enable output bus!");
        return NO;
    }

    // Disable input, we don't want it.
    UInt32 enableInput = 0;
    status = AudioUnitSetProperty(_audioUnit, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input, kInputBus, &enableInput,
                                  sizeof(enableInput));

    if (status != 0) {
        NSLog(@"Could not disable input bus!");
        return NO;
    }

    // Setup the rendering callback.
    AURenderCallbackStruct renderCallback;
    renderCallback.inputProc = playout_cb;
    renderCallback.inputProcRefCon = (void *)(self.renderingContext);
    status = AudioUnitSetProperty(_audioUnit, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Output, kOutputBus, &renderCallback,
                                  sizeof(renderCallback));
    if (status != 0) {
        NSLog(@"Could not set rendering callback!");
        return NO;
    }

    // Finally, initialize and start the RemoteIO audio unit.
    status = AudioUnitInitialize(_audioUnit);
    if (status != 0) {
        NSLog(@"Could not initialize the audio unit!");
        return NO;
    }

    return YES;
}

- (BOOL)startAudioUnit {
    OSStatus status = AudioOutputUnitStart(_audioUnit);
    if (status != 0) {
        NSLog(@"Could not start the audio unit!");
        return NO;
    }
    return YES;
}

- (BOOL)stopAudioUnit {
    OSStatus status = AudioOutputUnitStop(_audioUnit);
    if (status != 0) {
        NSLog(@"Could not stop the audio unit!");
        return NO;
    }
    return YES;
}


- (void)teardownAudioUnit {
    if (_audioUnit) {
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }
}

- (void)registerAVAudioSessionObservers {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserver:self selector:@selector(handleAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(handleMediaServiceLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
    [center addObserver:self selector:@selector(handleMediaServiceRestored:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    // TODO: Perform in a thread safe manner.
    [self handleAudioInterruptionContext:notification.userInfo[AVAudioSessionInterruptionTypeKey]];
//    [self performSelector:@selector(handleAudioInterruptionContext:)
//                 onThread:self.renderingContextThread
//               withObject:notification.userInfo[AVAudioSessionInterruptionTypeKey]
//            waitUntilDone:NO];
}

- (void)handleAudioInterruptionContext:(NSNumber *)interruptionType {
    AVAudioSessionInterruptionType type = [interruptionType unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.interrupted = YES;
        [self stopAudioUnit];
    } else {
        self.interrupted = NO;
        [self startAudioUnit];
    }
}

- (void)handleRouteChange:(NSNotification *)notification {
    // Check if the sample rate, channels or buffer duration changed. and trigger a format change if it did.
    AVAudioSessionRouteChangeReason reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];

    switch (reason) {
        case AVAudioSessionRouteChangeReasonUnknown:
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            // Each device change might cause the actual sample rate or channel configuration of the session to change.
        case AVAudioSessionRouteChangeReasonCategoryChange:
            // In iOS 9.2+ switching routes from a BT device in control center may cause a category change.
        case AVAudioSessionRouteChangeReasonOverride:
        case AVAudioSessionRouteChangeReasonWakeFromSleep:
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory:
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange:
            // With CallKit, AVAudioSession may change the sample rate during a configuration change.

            // If a valid route change occurs we may want to update our audio graph to reflect the new output device.
            // TODO: Perform in a thread safe manner.
            [self handleValidRouteChange];
//            [self performSelector:@selector(handleValidRouteChange)
//                         onThread:self.renderingContextThread
//                       withObject:nil
//                    waitUntilDone:NO];
            break;
    }
}

- (void)handleValidRouteChange {
    // Nothing to process while we are interrupted. We will interrogate the AVAudioSession once the interruption ends.
    if (self.interrupted) {
        return;
    } else if (_audioUnit == NULL) {
        return;
    }

    NSLog(@"A route change ocurred while the AudioUnit was started. Checking the active audio format.");

    // Determine if the format actually changed. We only care about sample rate and buffer sizes.
    TVIAudioFormat *activeFormat = [[self class] activeRenderingFormat];

    // TODO: Need to implement isEqual: and description: for TVIAudioFormat.
    if (activeFormat.sampleRate != _renderingFormat.sampleRate ||
        activeFormat.framesPerBuffer != _renderingFormat.framesPerBuffer ||
        activeFormat.numberOfChannels != _renderingFormat.numberOfChannels) {
        NSLog(@"Rendering format changed. Restarting with %lu channels / %u Hz / %zu bytes.",
              activeFormat.numberOfChannels, activeFormat.sampleRate, activeFormat.bufferSize);
        // Signal a change by clearing our cached format, and allowing TVIAudioDevice to drive the process.
        _renderingFormat = nil;
        renderFormatChanged(self.renderingContext->deviceContext);
    }
}

- (void)handleMediaServiceLost:(NSNotification *)notification {
    // TODO: Perform in a thread safe manner.
    [self stopAudioUnit];
//    [self performSelector:@selector(stopAudioUnit)
//                 onThread:self.renderingContextThread
//               withObject:nil
//            waitUntilDone:NO];
}

- (void)handleMediaServiceRestored:(NSNotification *)notification {
    // TODO: Perform in a thread safe manner.
    [self startAudioUnit];
//    [self performSelector:@selector(startAudioUnit)
//                 onThread:self.renderingContextThread
//               withObject:nil
//            waitUntilDone:NO];
}

- (void)unregisterAVAudioSessionObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
