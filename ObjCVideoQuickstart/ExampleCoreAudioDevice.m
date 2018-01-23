//
//  ExampleCoreAudioDevice.m
//  ObjCVideoQuickstart
//
//  Copyright © 2018 Twilio, Inc. All rights reserved.
//

#import "ExampleCoreAudioDevice.h"

// We want to get as close to 10 msec buffers as possible, because this is what the media engine prefers.
static double kPreferredIOBufferDuration = 0.01;
// The RemoteIO audio unit uses bus 0 for ouptut, and bus 1 for input.
static int kOutputBus = 0;
static int kInputBus = 1;

@interface ExampleCoreAudioDevice()

@property (nonatomic, assign) AudioUnit audioUnit;
@property (nonatomic, strong, nullable) TVIAudioFormat *renderingFormat;
@property (nonatomic, assign) TVIAudioDeviceContext renderingContext;

@end

@implementation ExampleCoreAudioDevice

- (id)init {
    self = [super init];
    if (self) {
    }
    return self;
}

#pragma mark - TVIAudioDeviceRenderer.

- (nullable TVIAudioFormat *)renderFormat {
    // TODO: Use the real value from AVAudioSession here!
    if (!_renderingFormat) {
        _renderingFormat = [[TVIAudioFormat alloc] initWithChannels:TVIAudioChannelsStereo
                                                         sampleRate:TVIAudioSampleRate48000
                                                    framesPerBuffer:TVIAudioSampleRate48000 / 100];
    }

    return _renderingFormat;
}

- (BOOL)initializeRenderer {
    [self setupAVAudioSession];

    return YES;
}

- (BOOL)startRendering:(nonnull TVIAudioDeviceContext)context {
    self.renderingContext = context;

    // Setup the Core Audio graph for playback.
    NSAssert(self.audioUnit == NULL, @"The audio unit should not be created yet.");
    return [self setupAudioUnit];
}

- (BOOL)stopRendering {
    // TODO: Stop and destroy core audio graph here.
    return YES;
}

#pragma mark - TVIAudioDeviceCapturer.

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
                           AudioBufferList *bufferList)
{
    TVIAudioDeviceContext *context = (TVIAudioDeviceContext *)refCon;

    assert(bufferList->mBuffers[0].mNumberChannels == 2);
    readRenderData(context, bufferList->mBuffers[0].mData, bufferList->mBuffers[0].mDataByteSize);

    return 0;
}

#pragma mark - Private (AVAudioSession and CoreAudio)

- (void)setupAVAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    if (![session setPreferredSampleRate:self.renderingFormat.sampleRate error:&error]) {
        NSLog(@"Error setting sample rate: %@", error);
    }

    if (![session setPreferredOutputNumberOfChannels:self.renderingFormat.numberOfChannels error:&error]) {
        NSLog(@"Error setting number of output channels: %@", error);
    }

    if (![session setPreferredInputNumberOfChannels:1 error:&error]) {
        NSLog(@"Error setting number of input channels: %@", error);
    }

    // We want to be as close as possible to the 10 millisecond buffer size that the media engine needs. If there is
    // a mismatch then TwilioVideo will ensure that appropriately sized audio buffers are delivered.
    if (![session setPreferredIOBufferDuration:kPreferredIOBufferDuration error:&error]) {
        NSLog(@"Error setting IOBuffer duration: %@", error);
    }

    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionDefaultToSpeaker;

    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:options
                        error:&error]) {
        NSLog(@"Error setting session category: %@", error);
    }

    [self registerAVAudioSessionObservers];

    if (![session setActive:YES error:&error]) {
        NSLog(@"Error activating AVAudioSession: %@", error);
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

    // TODO: Should this be on the output scope?
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
                                  kAudioUnitScope_Input, kOutputBus, &renderCallback,
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

    status = AudioOutputUnitStart(_audioUnit);
    if (status != 0) {
        NSLog(@"Could not start the audio unit!");
        return NO;
    }

    return YES;
}

- (void)registerAVAudioSessionObservers {
    // TODO:
}

- (void)unregisterAVAudioSessionObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)teardownAudioUnit {
    if (_audioUnit) {
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }
}

@end
