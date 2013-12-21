//
//  AERecorder.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 23/04/2012.
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "AERecorder.h"
#import "AEMixerBuffer.h"
#import "AEAudioFileWriter.h"

#define kProcessChunkSize 8192

NSString * AERecorderDidEncounterErrorNotification = @"AERecorderDidEncounterErrorNotification";
NSString * kAERecorderErrorKey = @"error";

@interface AERecorder () {
    BOOL _recording;
    BOOL _paused;
    AudioBufferList *_buffer;
}
@property (nonatomic, retain) AEMixerBuffer *mixer;
@property (nonatomic, retain) AEAudioFileWriter *writer;
@end

@implementation AERecorder
@synthesize mixer = _mixer, writer = _writer, currentTime = _currentTime;
@synthesize recording = _recording;
@synthesize paused = _paused;
@synthesize audioController;

@dynamic path;

+ (BOOL)AACEncodingAvailable {
    return [AEAudioFileWriter AACEncodingAvailable];
}

- (id)initWithAudioController:(AEAudioController*)audiocontroller {
    if ( !(self = [super init]) ) return nil;
    self.mixer = [[[AEMixerBuffer alloc] initWithClientFormat:audiocontroller.audioDescription] autorelease];
    self.writer = [[[AEAudioFileWriter alloc] initWithAudioDescription:audiocontroller.audioDescription] autorelease];
    if ( audiocontroller.audioInputAvailable && audioController.inputAudioDescription.mChannelsPerFrame != audiocontroller.audioDescription.mChannelsPerFrame ) {
        [_mixer setAudioDescription:*AEAudioControllerInputAudioDescription(audiocontroller) forSource:AEAudioSourceInput];
    }
    _buffer = AEAllocateAndInitAudioBufferList(audiocontroller.audioDescription, 0);
    
    audioController = audiocontroller;
    
    return self;
}

-(void)dealloc {
    free(_buffer);
    self.mixer = nil;
    self.writer = nil;
    [super dealloc];
}

-(BOOL)beginRecordingToFileAtPath:(NSString *)path fileType:(AudioFileTypeID)fileType error:(NSError **)error {
    BOOL result = [self prepareRecordingToFileAtPath:path fileType:fileType error:error];
    _recording = YES;
    _paused = NO;
    return result;
}

- (BOOL)prepareRecordingToFileAtPath:(NSString*)path fileType:(AudioFileTypeID)fileType error:(NSError**)error {
    _currentTime = 0.0;
    BOOL result = [_writer beginWritingToFileAtPath:path fileType:fileType error:error];
    return result;
}

void AERecorderStartRecording(AERecorder* THIS) {
    THIS->_recording = YES;
}

- (void)finishRecording {
    _recording = NO;
    [_writer finishWriting];
}

- (void)discardRecording
{
    /* Insert mode code to discard recording */
    
    _recording = NO;
    [_writer finishWriting];
    NSError *error;
    BOOL success = [[NSFileManager defaultManager] removeItemAtPath:[self path] error: &error];

    if (!success)
    {
        NSLog(@"Error in discarding recording:%@| with Error:%@",[self path],error);
    }
    else
    {
        NSLog(@"Succesfully discarded recording:%@",[self path]);
    }
}

- (void)resumeRecording
{
    if (!_recording && _paused)
    {
        _recording = YES;
        _paused = NO;
    }
}

- (void)pauseRecording
{
    if (_recording)
    {
        _recording = NO;
        _paused = YES;
    }
}

-(NSString *)path {
    return _writer.path;
}

struct reportError_t { AERecorder *THIS; OSStatus result; };
static void reportError(AEAudioController *audioController, void *userInfo, int length) {
    struct reportError_t *arg = userInfo;
    NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain 
                                         code:arg->result
                                     userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:NSLocalizedString(@"Error while saving audio: Code %d", @""), arg->result]
                                                                          forKey:NSLocalizedDescriptionKey]];
    [[NSNotificationCenter defaultCenter] postNotificationName:AERecorderDidEncounterErrorNotification
                                                        object:arg->THIS
                                                      userInfo:[NSDictionary dictionaryWithObject:error forKey:kAERecorderErrorKey]];
}

static void audioCallback(id                        receiver,
                          AEAudioController        *audioController,
                          void                     *source,
                          const AudioTimeStamp     *time,
                          UInt32                    frames,
                          AudioBufferList          *audio) {
    AERecorder *THIS = receiver;
    if ( !THIS->_recording ) return;
    if ( THIS->_paused ) return;

    AEMixerBufferEnqueue(THIS->_mixer, source, audio, frames, time);
    
    // Let the mixer buffer provide the audio buffer
    UInt32 bufferLength = kProcessChunkSize;
    for ( int i=0; i<THIS->_buffer->mNumberBuffers; i++ ) {
        THIS->_buffer->mBuffers[i].mData = NULL;
        THIS->_buffer->mBuffers[i].mDataByteSize = 0;
    }
    
    THIS->_currentTime += AEConvertFramesToSeconds(audioController, frames);
    
    AEMixerBufferDequeue(THIS->_mixer, THIS->_buffer, &bufferLength, NULL);
    
    if ( bufferLength > 0 ) {
        OSStatus status = AEAudioFileWriterAddAudio(THIS->_writer, THIS->_buffer, bufferLength);
        if ( status != noErr ) {
            AEAudioControllerSendAsynchronousMessageToMainThread(audioController, 
                                                                 reportError, 
                                                                 &(struct reportError_t) { .THIS = THIS, .result = status }, 
                                                                 sizeof(struct reportError_t));
        }
    }
}

-(AEAudioControllerAudioCallback)receiverCallback {
    return audioCallback;
}

@end
