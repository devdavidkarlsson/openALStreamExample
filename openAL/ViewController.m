//
//  ViewController.m
//  openAL
//  http://benbritten.com/2008/11/06/openal-sound-on-the-iphone/
//  http://benbritten.com/2010/05/04/streaming-in-openal/
//
//  Created by David Karlsson on 2015-03-01.
//  Copyright (c) 2015 davidkarlsson. All rights reserved.
//

#import "ViewController.h"
#import <OpenAL/al.h>
#import <OpenAL/alc.h>
#import <AudioToolbox/AudioToolbox.h>
#define MAX_SOURCES  3
#define kBufferRefreshDelay 3
#define kNumberOfBuffers 7

@implementation ViewController

int active, interrupted;
NSMutableDictionary * soundLibrary;
NSMutableArray* sources;
NSUInteger bufferID;
ALCcontext* mContext;
ALCdevice* mDevice;


- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self initOpenAL];
    [self preloadSources];
    soundLibrary = [[NSMutableDictionary alloc] init];
    
    [soundLibrary setObject:[self initializeStreamFromFile:@"1" format:AL_FORMAT_STEREO16 freq:44100] forKey:@"bubbles"];
    active=1;
    //[self initializeStreamFromFile:@"sound_bubbles" format:AL_FORMAT_MONO8 freq:22050];
    [self playStream:@"bubbles" gain:1 pitch:1 loops:YES];


    // Do any additional setup after loading the view.
}

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}

-(void)_error:(ALenum)err note:(NSString*)note{
    NSLog(@"%@",note);
}

// note: MAX_SOURCES is how many source you want
// to preload.  should keep it below 32
-(void)preloadSources
{
    // lazy init of my data structure
    if (sources == nil) sources = [[NSMutableArray alloc] init];
    
    // we want to allocate all the sources we will need up front
    NSUInteger sourceCount = MAX_SOURCES;
    NSInteger sourceIndex;
    NSUInteger sourceID;
    // build a bunch of sources and load them into our array.
    for (sourceIndex = 0; sourceIndex < sourceCount; sourceIndex++) {
        alGenSources(1, &sourceID);
        [sources addObject:[NSNumber numberWithUnsignedInt:sourceID]];
    }	
}

-(NSUInteger)nextAvailableSource
{
    NSInteger sourceState; // a holder for the state of the current source
    
    // first check: find a source that is not being used at the moment.
    for (NSNumber * sourceNumber in sources) {
        alGetSourcei([sourceNumber unsignedIntValue], AL_SOURCE_STATE, &sourceState);
        // great! we found one! return it and shunt
        if (sourceState != AL_PLAYING) return [sourceNumber unsignedIntValue];
    }
    
    // in the case that all our sources are being used, we will find the first non-looping source
    // and return that.
    // first kick out an error
    NSLog(@"available source overrun, increase MAX_SOURCES");
    
    NSInteger looping;
    for (NSNumber * sourceNumber in sources) {
        alGetSourcei([sourceNumber unsignedIntValue], AL_LOOPING, &looping);
        if (!looping) {
            // we found one that is not looping, cut it short and return it
            NSUInteger sourceID = [sourceNumber unsignedIntValue];
            alSourceStop(sourceID);
            return sourceID;
        }
    }
    
    // what if they are all loops? arbitrarily grab the first one and cut it short
    // kick out another error
    NSLog(@"available source overrun, all used sources looping");
    
    NSUInteger sourceID = [[sources objectAtIndex:0] unsignedIntegerValue];
    alSourceStop(sourceID);
    return sourceID;
}




// start up openAL
-(void)initOpenAL
{
    // Initialization
    
    const char * devicename = alcGetString(NULL, ALC_DEFAULT_DEVICE_SPECIFIER);
    
    NSLog(@"Output to: %s", devicename);
    mDevice = alcOpenDevice(NULL); // select the "preferred device"
    if (mDevice) {
        // use the device to make a context
        mContext=alcCreateContext(mDevice,NULL);
        // set my context to the currently active one
        alcMakeContextCurrent(mContext);
    } 
}

// open the audio file
// returns a big audio ID struct
-(AudioFileID)openAudioFile:(NSString*)filename
{
    AudioFileID outAFID;
    // use the NSURl instead of a cfurlref cuz it is easier
    
    NSString* path = [[NSBundle mainBundle] pathForResource:filename ofType:@"caf"];
    NSURL * afUrl = [NSURL fileURLWithPath:path];
    
    // do some platform specific stuff..
#if TARGET_OS_IPHONE
    OSStatus result = AudioFileOpenURL((CFURLRef)afUrl, kAudioFileReadPermission, 0, &outAFID);
#else
    OSStatus result = AudioFileOpenURL((__bridge CFURLRef)afUrl, fsRdPerm, 0, &outAFID);
#endif
    if (result != 0) NSLog(@"cannot openf file: %@",path);
    return outAFID;
}

// find the audio portion of the file
// return the size in bytes
-(UInt32)audioFileSize:(AudioFileID)fileDescriptor
{
    UInt64 outDataSize = 0;
    UInt32 thePropSize = sizeof(UInt64);
    OSStatus result = AudioFileGetProperty(fileDescriptor, kAudioFilePropertyAudioDataByteCount, &thePropSize, &outDataSize);
    if(result != 0) NSLog(@"cannot find file size");
    NSLog(@"Filesize: %llu", outDataSize);
    
    return (UInt32)outDataSize;
}


// this queues up the specified file for streaming
-(NSMutableDictionary*)initializeStreamFromFile:(NSString*)fileName format:(ALenum)format freq:(ALsizei)freq
{
    // first, open the file
    AudioFileID fileID = [self openAudioFile:fileName];
    
    // find out how big the actual audio data is
    UInt32 fileSize = [self audioFileSize:fileID];
    
    UInt32 bufferSize = 48000; //OPENAL_STREAMING_BUFFER_SIZE;
    UInt32 bufferIndex = 0;
    
    // ok, now we build a data record for this streaming file
    // before, with straight sounds this is just a soundID
    // but with the streaming sound, we need more info
    NSMutableDictionary * record = [NSMutableDictionary dictionary];
    [record setObject:fileName forKey:@"fileName"];
    [record setObject:[NSNumber numberWithUnsignedInteger:fileSize] forKey:@"fileSize"];
    [record setObject:[NSNumber numberWithUnsignedInteger:bufferSize] forKey:@"bufferSize"];
    [record setObject:[NSNumber numberWithUnsignedInteger:bufferIndex] forKey:@"bufferIndex"];
    [record setObject:[NSNumber numberWithInteger:format] forKey:@"format"];
    [record setObject:[NSNumber numberWithInteger:freq] forKey:@"freq"];
    [record setObject:[NSNumber numberWithBool:NO] forKey:@"isPlaying"];

    
    // this will hold our buffer IDs
    NSMutableArray * bufferList = [NSMutableArray array];
    int i;
    for (i = 0; i < kNumberOfBuffers; i++) {
        NSUInteger bufferID;
        // grab a buffer ID from openAL
        alGenBuffers(1, &bufferID);
        
        [bufferList addObject:[NSNumber numberWithUnsignedInteger:bufferID]];
    }
    
    [record setObject:bufferList forKey:@"bufferList"];

    // close the file
    AudioFileClose(fileID);
    
    NSLog(@"File opened: %@", [record objectForKey:@"fileName"]);
    return record;

}


- (NSUInteger)playStream:(NSString*)soundKey gain:(ALfloat)gain pitch:(ALfloat)pitch loops:(BOOL)loops
{
    // if we are not active, then dont do anything
    if (!active) return 0;

    ALenum err = alGetError(); // clear error code
    
    // generally the 'play sound method' whoudl be called for all sounds
    // however if someone did call this one in error, it is nice to be able to handle it
    /*if ([[soundLibrary objectForKey:soundKey] isKindOfClass:[NSNumber class]]) {
        return [self playSound:soundKey gain:1.0 pitch:1.0 loops:loops];
    }*/
    
    // get our keyed sound record
    NSMutableDictionary * record = [soundLibrary objectForKey:soundKey];

    // first off, check to see if this sound is already playing
    if ([[record objectForKey:@"isPlaying"] boolValue]) return 0;
    
    // first, find the buffer we want to play
    NSArray * bufferList = [record objectForKey:@"bufferList"];
    
    // now find an available source
    NSUInteger sourceID = [self nextAvailableSource];
    alSourcei(sourceID, AL_BUFFER, 0);
    
    // reset the buffer index to 0
    [record setObject:[NSNumber numberWithUnsignedInteger:0] forKey:@"bufferIndex"];

    // queue up the first 3 buffers on the source
    for (NSNumber * bufferNumber in bufferList) {
        NSUInteger bufferID = [bufferNumber unsignedIntegerValue];
        [self loadNextStreamingBufferForSound:soundKey intoBuffer:bufferID];
        alSourceQueueBuffers(sourceID, 1, &bufferID);
        err = alGetError();
        if (err != 0) [self _error:err note:@"Error alSourceQueueBuffers!"];
    }
    
    alSourceQueueBuffers(sourceID, 1, &bufferID);
    
    // set the pitch and gain of the source
    alSourcef(sourceID, AL_PITCH, pitch);
    err = alGetError();
    if (err != 0) [self _error:err note:@"Error AL_PITCH!"];
    alSourcef(sourceID, AL_GAIN, gain);
    err = alGetError();
    if (err != 0) [self _error:err note:@"Error AL_GAIN!"];
    // streams should not be looping
    // we will handle that in the buffer refill code
    alSourcei(sourceID, AL_LOOPING, AL_FALSE);
    err = alGetError();
    if (err != 0) [self _error:err note:@"Error AL_LOOPING!"];
    
    // everything is queued, start the buffer playing
    alSourcePlay(sourceID);
    
    NSLog(@"Heartbeat should sound");

    // check to see if there are any errors
    err = alGetError();
    if (err != 0) {
        [self _error:err note:@"Error Playing Stream!"];
        return 0;
    }

    // set up some state
    [record setObject:[NSNumber numberWithBool:YES] forKey:@"isPlaying"];
    [record setObject:[NSNumber numberWithBool:loops] forKey:@"loops"];
    [record setObject:[NSNumber numberWithUnsignedInteger:sourceID] forKey:@"sourceID"];

    
    // kick off the refill methods
    [NSThread detachNewThreadSelector:@selector(rotateBufferThread:) toTarget:self withObject:soundKey];
    return sourceID;
}

// this takes the stream record, figures out where we are in the file
// and loads the next chunk into the specified buffer
-(BOOL)loadNextStreamingBufferForSound:(NSString*)key intoBuffer:(NSUInteger)bufferID
{

    // check some escape conditions
    if ([soundLibrary objectForKey:key] == nil) return NO;
    if (![[soundLibrary objectForKey:key] isKindOfClass:[NSDictionary class]]) return NO;
    
    // get the record
    NSMutableDictionary * record = [soundLibrary objectForKey:key];
    
    // open the file
    AudioFileID fileID = [self openAudioFile:[record objectForKey:@"fileName"]];
    NSLog(@"Heartbeat %@", [record objectForKey:@"fileName"]);

    // now we need to calculate where we are in the file
    UInt32 fileSize = [[record objectForKey:@"fileSize"] unsignedIntegerValue];
    UInt32 bufferSize = [[record objectForKey:@"bufferSize"] unsignedIntegerValue];
    UInt32 bufferIndex = [[record objectForKey:@"bufferIndex"] unsignedIntegerValue];;
    
    
    // how many chunks does the file have total?
    NSInteger totalChunks = fileSize/bufferSize;
    
    // are we past the end? if so get out
    if (bufferIndex > totalChunks) return NO;
    
    // this is where we need to start reading from the file
    NSUInteger startOffset = bufferIndex * bufferSize;
    
    // are we in the last chunk? it might not be the same size as all the others
    if (bufferIndex == totalChunks) {
        NSInteger leftOverBytes = fileSize - (bufferSize * totalChunks);
        bufferSize = leftOverBytes;
    }
    
    // this is where the audio data will live for the moment
    unsigned char * outData = malloc(bufferSize);
    
    // this where we actually get the bytes from the file and put them
    // into the data buffer
    UInt32 bytesToRead = bufferSize;
    OSStatus result = noErr;
    result = AudioFileReadBytes(fileID, false, startOffset, &bytesToRead, outData);
    if (result != 0) NSLog(@"cannot load stream: %@",[record objectForKey:@"fileName"]);
    
    // if we are past the end, and no bytes were read, then no need to Q a buffer
    // this should not happen if the math above is correct, but to be sae we will add it
    if (bytesToRead == 0) {
        free(outData);
        return NO; // no more file!
    }
    
    ALsizei freq = [[record objectForKey:@"freq"] intValue];
    ALenum format = [[record objectForKey:@"format"] intValue];
    
    // jam the audio data into the supplied buffer
    alBufferData(bufferID,format,outData,bytesToRead,freq);
    
    // clean up the buffer
    if (outData)
    {
        free(outData);
        outData = NULL;
    }
    
    AudioFileClose(fileID);
    
    // increment the index so that next time we get the next chunk
    bufferIndex ++;
    // are we looping? if so then flip back to 0

    NSLog(@"LOOP? %@",[[record objectForKey:@"loops"] boolValue] ? @"YES" : @"NO"  );
    NSLog(@"BufferIndex: %d TotalChunks: %d", bufferIndex, totalChunks);
    if ((bufferIndex > totalChunks) /*&& ([[record objectForKey:@"loops"] boolValue]) */) {
        NSLog(@"Looped");
        bufferIndex = 0;
    }
    [record setObject:[NSNumber numberWithUnsignedInteger:bufferIndex] forKey:@"bufferIndex"];
    return YES;
}

-(void)rotateBufferThread:(NSString*)soundKey
{
    BOOL stillPlaying = YES;

    while (stillPlaying) {
        NSLog(@"Still playing");
        stillPlaying = [self rotateBufferForStreamingSound:soundKey];
        if (interrupted) 	{
            // slow down our thread during interruptions
            [NSThread sleepForTimeInterval:kBufferRefreshDelay * 3];
        } else {
            // normal thread delay
            [NSThread sleepForTimeInterval:kBufferRefreshDelay];
        }
    }
}

// this checks to see if there is a buffer that has been used up.
// if it finds one then it loads the next bit of the sound into that buffer
// and puts it into the back of the queue
-(BOOL)rotateBufferForStreamingSound:(NSString*)soundKey
{
    // make sure we arent trying to stream a normal sound
    if (![[soundLibrary objectForKey:soundKey] isKindOfClass:[NSDictionary class]]) return NO;
    if (interrupted) return YES; // we are still 'playing' but we arent loading new buffers
    
    // get the keyed record
    NSMutableDictionary * record = [soundLibrary objectForKey:soundKey];
    NSUInteger sourceID = [[record objectForKey:@"sourceID"] unsignedIntegerValue];
    
    // check to see if we are stopped
    NSInteger sourceState;
    alGetSourcei(sourceID, AL_SOURCE_STATE, &sourceState);
    if (sourceState != AL_PLAYING) {
        [record setObject:[NSNumber numberWithBool:NO] forKey:@"isPlaying"];
        return NO; // we are stopped, do not load any more buffers
    }
    
    // get the processed buffer count
    NSInteger buffersProcessed = 0;
    alGetSourcei(sourceID, AL_BUFFERS_PROCESSED, &buffersProcessed);
    
    // check to see if we have a buffer to deQ
    if (buffersProcessed > 0) {
        // great! deQ a buffer and re-fill it
        NSUInteger bufferID;
        // remove the buffer form the source
        alSourceUnqueueBuffers(sourceID, 1, &bufferID);
        // fill the buffer up and reQ!
        // if we cant fill it up then we are finished
        // in which case we dont need to re-Q
        // return NO if we dont have mroe buffers to Q
        if (![self loadNextStreamingBufferForSound:soundKey intoBuffer:bufferID]) return NO;
        // Q the loaded buffer
        alSourceQueueBuffers(sourceID, 1, &bufferID);
    }
    
    return YES;
}

@end
