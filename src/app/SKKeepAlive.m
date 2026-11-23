//
//  SKKeepAlive.m
//  AppDump
//

#import "SKKeepAlive.h"
#import "SKLog.h"

#import <AVFoundation/AVFoundation.h>

static AVAudioPlayer *gPlayer = nil;
static BOOL gOn = NO;

static NSString *sk_ka_wav_path(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return docs.length ? [docs stringByAppendingPathComponent:@"silent.wav"] : nil;
}

// 44 字节头 + 1 秒 16bit 单声道 44.1kHz 的静音。
static BOOL sk_ka_write_wav(NSString *path) {
    const uint32_t samplerate = 44100;
    const uint32_t datasize = samplerate * 2;

    NSMutableData *d = [NSMutableData dataWithCapacity:44 + datasize];

    uint32_t u32;
    uint16_t u16;

    [d appendData:[@"RIFF" dataUsingEncoding:NSASCIIStringEncoding]];
    u32 = 36 + datasize; [d appendBytes:&u32 length:4];
    [d appendData:[@"WAVE" dataUsingEncoding:NSASCIIStringEncoding]];
    [d appendData:[@"fmt " dataUsingEncoding:NSASCIIStringEncoding]];
    u32 = 16; [d appendBytes:&u32 length:4];
    u16 = 1;  [d appendBytes:&u16 length:2];   // PCM
    u16 = 1;  [d appendBytes:&u16 length:2];   // mono
    u32 = samplerate; [d appendBytes:&u32 length:4];
    u32 = samplerate * 2; [d appendBytes:&u32 length:4];  // byte rate
    u16 = 2;  [d appendBytes:&u16 length:2];               // block align
    u16 = 16; [d appendBytes:&u16 length:2];               // bits
    [d appendData:[@"data" dataUsingEncoding:NSASCIIStringEncoding]];
    u32 = datasize; [d appendBytes:&u32 length:4];
    [d appendData:[NSMutableData dataWithLength:datasize]];

    return [d writeToFile:path atomically:YES];
}

BOOL SKKeepAliveIsOn(void) { return gOn; }

BOOL SKKeepAliveSetOn(BOOL on) {
    if (on == gOn) return gOn;

    if (!on) {
        [gPlayer stop];
        gPlayer = nil;
        gOn = NO;
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:NULL];
        SKLog(@"[ka] keep alive off");
        return gOn;
    }

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err) {
        SKLog(@"[ka] audio session failed: %@", err.localizedDescription);
        return gOn;
    }
    [session setActive:YES error:&err];
    if (err) {
        SKLog(@"[ka] audio session activate failed: %@", err.localizedDescription);
        return gOn;
    }

    NSString *wav = sk_ka_wav_path();
    if (!wav) return gOn;
    if (![[NSFileManager defaultManager] fileExistsAtPath:wav]) {
        if (!sk_ka_write_wav(wav)) {
            SKLog(@"[ka] cannot write silent.wav");
            return gOn;
        }
    }

    NSError *perr = nil;
    gPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:wav]
                                                     error:&perr];
    if (!gPlayer) {
        SKLog(@"[ka] player failed: %@", perr.localizedDescription);
        return gOn;
    }
    gPlayer.numberOfLoops = -1;
    gPlayer.volume = 0.0;
    [gPlayer prepareToPlay];
    if (![gPlayer play]) {
        SKLog(@"[ka] play failed");
        gPlayer = nil;
        return gOn;
    }

    gOn = YES;
    SKLog(@"[ka] keep alive on");
    return gOn;
}

void SKKeepAliveApplyFromDefaults(void) {
    BOOL want = [NSUserDefaults.standardUserDefaults boolForKey:@"ad.keepalive"];
    if (want) SKKeepAliveSetOn(YES);
}
