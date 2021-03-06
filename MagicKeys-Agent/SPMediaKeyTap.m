// Copyright (c) 2010 Spotify AB, (c) 2012 Treasure Box
#import "SPMediaKeyTap.h"
#import "NSObject+SPInvocationGrabbing.h" // https://gist.github.com/511181, in submodule

@interface SPMediaKeyTap ()
-(BOOL)shouldInterceptMediaKeyEvents;
-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
-(void)startWatchingAppSwitching;
-(void)stopWatchingAppSwitching;
-(void)eventTapThread;
@end
static SPMediaKeyTap *singleton = nil;

static pascal OSStatus appSwitched (EventHandlerCallRef nextHandler, EventRef evt, void* userData);
static pascal OSStatus appTerminated (EventHandlerCallRef nextHandler, EventRef evt, void* userData);
static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon);


// Inspired by http://gist.github.com/546311

@implementation SPMediaKeyTap

static NSString *kKeySerialNumber = @"SerialNumber";
static NSString *kKeyIsApple = @"isApple";
static NSString *kKeyProcessSpecificTap = @"ProcessTap";
static NSString *kKeyProcessSpecificRunloopSource = @"ProcessSource";

#pragma mark -
#pragma mark Setup and teardown
-(id)initWithDelegate:(id)delegate;
{
	_delegate = delegate;
	[self startWatchingAppSwitching];
	singleton = self;
	_mediaKeyAppList = [NSMutableArray new];
    _tapThreadRL=nil;
    _eventPort=nil;
    _eventPortSource=nil;
	return self;
}
-(void)dealloc;
{
	[self stopWatchingMediaKeys];
	[self stopWatchingAppSwitching];
	[_mediaKeyAppList release];
	[super dealloc];
}

-(void)startWatchingAppSwitching;
{
	// Listen to "app switched" event, so that we don't intercept media keys if we
	// weren't the last "media key listening" app to be active
	EventTypeSpec eventType = { kEventClassApplication, kEventAppFrontSwitched };
    OSStatus err = InstallApplicationEventHandler(NewEventHandlerUPP(appSwitched), 1, &eventType, self, &_app_switching_ref);
	assert(err == noErr);
	
	eventType.eventKind = kEventAppTerminated;
    err = InstallApplicationEventHandler(NewEventHandlerUPP(appTerminated), 1, &eventType, self, &_app_terminating_ref);
	assert(err == noErr);
}
-(void)stopWatchingAppSwitching;
{
	if(!_app_switching_ref) return;
	RemoveEventHandler(_app_switching_ref);
	_app_switching_ref = NULL;
}

-(void)startWatchingMediaKeys;{
    // Prevent having multiple mediaKeys threads
    [self stopWatchingMediaKeys];
    
	[self setShouldInterceptMediaKeyEvents:YES];
	
	// Add an event tap to intercept the system defined media key events
	_eventPort = CGEventTapCreate(kCGSessionEventTap,
								  kCGHeadInsertEventTap,
								  kCGEventTapOptionDefault,
								  CGEventMaskBit(NX_SYSDEFINED),
								  tapEventCallback,
								  self);
	assert(_eventPort != NULL);
	
    _eventPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, _eventPort, 0);
	assert(_eventPortSource != NULL);
	
	// Let's do this in a separate thread so that a slow app doesn't lag the event tap
	[NSThread detachNewThreadSelector:@selector(eventTapThread) toTarget:self withObject:nil];
}
-(void)stopWatchingMediaKeys;
{
	// TODO<nevyn>: Shut down thread, remove event tap port and source
    
    if(_tapThreadRL){
        CFRunLoopStop(_tapThreadRL);
        _tapThreadRL=nil;
    }
    
    if(_eventPort){
        CFMachPortInvalidate(_eventPort);
        CFRelease(_eventPort);
        _eventPort=nil;
    }
    
    if(_eventPortSource){
        CFRelease(_eventPortSource);
        _eventPortSource=nil;
    }
}

#pragma mark -
#pragma mark Accessors

+(BOOL)usesGlobalMediaKeyTap
{
#ifdef _DEBUG
	// breaking in gdb with a key tap inserted sometimes locks up all mouse and keyboard input forever, forcing reboot
	return YES;
#else
	// XXX(nevyn): MediaKey event tap doesn't work on 10.4, feel free to figure out why if you have the energy.
	return 
		![[NSUserDefaults standardUserDefaults] boolForKey:kIgnoreMediaKeysDefaultsKey]
		&& floor(NSAppKitVersionNumber) >= 949/*NSAppKitVersionNumber10_5*/;
#endif
}

+ (NSArray*)defaultMediaKeyUserBundleIdentifiers;
{
	return [NSArray arrayWithObjects:
		[[NSBundle mainBundle] bundleIdentifier], // your app
		@"com.spotify.client",
		@"com.apple.iTunes",
		@"com.apple.QuickTimePlayerX",
		@"com.apple.quicktimeplayer",
		@"com.apple.iWork.Keynote",
		@"com.apple.iPhoto",
		@"org.videolan.vlc",
		@"com.apple.Aperture",
		@"com.plexsquared.Plex",
		@"com.soundcloud.desktop",
		@"org.niltsh.MPlayerX",
		@"com.ilabs.PandorasHelper",
		@"com.mahasoftware.pandabar",
		@"com.bitcartel.pandorajam",
		@"org.clementine-player.clementine",
		@"fm.last.Last.fm",
		@"com.beatport.BeatportPro",
		@"com.Timenut.SongKey",
		@"com.macromedia.fireworks", // the tap messes up their mouse input
        @"com.treasurebox.gear",
		nil
	];
}


-(BOOL)shouldInterceptMediaKeyEvents;
{
	BOOL shouldIntercept = NO;
	@synchronized(self) {
		shouldIntercept = _shouldInterceptMediaKeyEvents;
	}
	return shouldIntercept;
}

-(void)pauseTapOnTapThread:(BOOL)yeahno;
{
	CGEventTapEnable(self->_eventPort, yeahno);
}
-(void)setShouldInterceptMediaKeyEvents:(BOOL)newSetting;
{
	BOOL oldSetting;
	@synchronized(self) {
		oldSetting = _shouldInterceptMediaKeyEvents;
		_shouldInterceptMediaKeyEvents = newSetting;
	}
	if(_tapThreadRL && oldSetting != newSetting) {
		id grab = [self grab];
		[grab pauseTapOnTapThread:newSetting];
		NSTimer *timer = [NSTimer timerWithTimeInterval:0 invocation:[grab invocation] repeats:NO];
		CFRunLoopAddTimer(_tapThreadRL, (CFRunLoopTimerRef)timer, kCFRunLoopCommonModes);
	}
}

#pragma mark 
#pragma mark -
#pragma mark Event tap callbacks

- (BOOL)isMediaEvent:(CGEventRef)event type:(CGEventType)type
{
    if(type == kCGEventTapDisabledByTimeout) {
		NSLog(@"Media key event tap was disabled by timeout");
		CGEventTapEnable(self->_eventPort, TRUE);
		return NO;
	} else if(type == kCGEventTapDisabledByUserInput) {
		// Was disabled manually by -[pauseTapOnTapThread]
		return NO;
	}
	NSEvent *nsEvent = nil;
	@try {
		nsEvent = [NSEvent eventWithCGEvent:event];
	}
	@catch (NSException * e) {
		NSLog(@"Strange CGEventType: %d: %@", type, e);
		assert(0);
		return NO;
	}
    
	if (type != NX_SYSDEFINED || [nsEvent subtype] != SPSystemDefinedEventMediaKeys) {
		return NO;
    }
    
	int keyCode = (([nsEvent data1] & 0xFFFF0000) >> 16);
    if (keyCode != NX_KEYTYPE_PLAY && keyCode != NX_KEYTYPE_FAST && keyCode != NX_KEYTYPE_REWIND && keyCode != NX_KEYTYPE_PREVIOUS && keyCode != NX_KEYTYPE_NEXT) {
        
        return NO;
    }
    
	if (![self shouldInterceptMediaKeyEvents])
		return NO;
    
    return YES;
}


// event will have been retained in the other thread
- (BOOL)handleAndReleaseMediaKeyEvent:(CGEventRef)cgEvent {
    
    if ([_mediaKeyAppList count] == 0) {
        return NO;
    }
    
    NSDictionary *entry = [_mediaKeyAppList objectAtIndex:0];
    if ([[entry objectForKey:kKeyIsApple] boolValue]) {
        return NO;
    }
    
    ProcessSerialNumber targetSerial;
    [[entry objectForKey:kKeySerialNumber] getValue:&targetSerial];
    CGEventPostToPSN(&targetSerial, cgEvent);
    
    return YES;
}

- (BOOL)isFirstApple
{
    
    if ([_mediaKeyAppList count] == 0) {
        return NO;
    }
    
    NSDictionary *entry = [_mediaKeyAppList objectAtIndex:0];
    return [[entry objectForKey:kKeyIsApple] boolValue];
}

// Note: method called on background thread

static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    SPMediaKeyTap *self = refcon;
    
    @autoreleasepool {
        
        if (![self isMediaEvent:event type:type]) {
            return event;
        }
        
        if ([self handleAndReleaseMediaKeyEvent:event]) {
            
            // handled
            return NULL;
        }
        
        // normal flow, for now (see you at tapEventCallbackForProcess)
        return event;

    }
}

static CGEventRef tapEventCallbackForProcess(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    SPMediaKeyTap *self = refcon;

    @autoreleasepool {
        if (![self isMediaEvent:event type:type]) {
            return event;
        }
        
        if ([self isFirstApple]) {
            return NULL;
        } else {
            return event;
        }
    }
}



-(void)eventTapThread;
{
	_tapThreadRL = CFRunLoopGetCurrent();
	CFRunLoopAddSource(_tapThreadRL, _eventPortSource, kCFRunLoopCommonModes);
	CFRunLoopRun();
}

#pragma mark Task switching callbacks

NSString *kMediaKeyUsingBundleIdentifiersDefaultsKey = @"SPApplicationsNeedingMediaKeys";
NSString *kIgnoreMediaKeysDefaultsKey = @"SPIgnoreMediaKeys";



-(void)mediaKeyAppListChanged;
{
	if([_mediaKeyAppList count] == 0) return;
	
	/*NSLog(@"--");
	int i = 0;
	for (NSValue *psnv in _mediaKeyAppList) {
		ProcessSerialNumber psn; [psnv getValue:&psn];
		NSDictionary *processInfo = [(id)ProcessInformationCopyDictionary(
			&psn,
			kProcessDictionaryIncludeAllInformationMask
		) autorelease];
		NSString *bundleIdentifier = [processInfo objectForKey:(id)kCFBundleIdentifierKey];
		NSLog(@"%d: %@", i++, bundleIdentifier);
	}*/
	
	[self setShouldInterceptMediaKeyEvents:([_mediaKeyAppList count] > 0)];
}

- (void)removeSerialFromAppList:(NSValue *)psnv
{
    if (_mediaKeyAppList == nil) {
        return;
    }
    [_mediaKeyAppList filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary *bindings) {
        
        return ![[evaluatedObject objectForKey:kKeySerialNumber] isEqualTo:psnv];
    }]];
}

-(void)appIsNowFrontmost:(ProcessSerialNumber)psn
{
	NSValue *psnv = [NSValue valueWithBytes:&psn objCType:@encode(ProcessSerialNumber)];
	
	NSDictionary *processInfo = CFMakeCollectable(ProcessInformationCopyDictionary(
		&psn,
		kProcessDictionaryIncludeAllInformationMask
	));
    [processInfo autorelease];
	NSString *bundleIdentifier = [processInfo objectForKey:(NSString *)kCFBundleIdentifierKey];

	NSArray *whitelistIdentifiers = [[NSUserDefaults standardUserDefaults] arrayForKey:kMediaKeyUsingBundleIdentifiersDefaultsKey];
	if(![whitelistIdentifiers containsObject:bundleIdentifier]) return;

    
	[self removeSerialFromAppList:psnv];
    BOOL isApple = [bundleIdentifier hasPrefix:@"com.apple."];
    NSMutableDictionary *appEntry = [NSMutableDictionary dictionaryWithDictionary:@{ kKeySerialNumber : psnv, kKeyIsApple : @(isApple)}];
	if (!isApple) {
        CFMachPortRef port = CGEventTapCreateForPSN(&psn, kCGHeadInsertEventTap,
                               kCGEventTapOptionDefault,
                               CGEventMaskBit(NX_SYSDEFINED),
                               tapEventCallbackForProcess,
                               self);
        if (port == NULL) {
            NSLog(@"error listening tapping to process %@", bundleIdentifier);
        } else {
            // TODO: leaks!
            CFRunLoopSourceRef sourceForProcessTap = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, port, 0);
            if (sourceForProcessTap == NULL) {
                NSLog(@"error creating source for process %@", bundleIdentifier);
            } else {
                CFRunLoopAddSource(_tapThreadRL, sourceForProcessTap, kCFRunLoopCommonModes);
                [appEntry setObject:(id)port forKey:kKeyProcessSpecificTap];
                [appEntry setObject:(id)sourceForProcessTap forKey:kKeyProcessSpecificRunloopSource];
                CFRelease(sourceForProcessTap);
            }
            CFRelease(port);
        }
    }
    [_mediaKeyAppList insertObject:appEntry atIndex:0];
	[self mediaKeyAppListChanged];
}

-(void)appTerminated:(ProcessSerialNumber)psn;
{
	NSValue *psnv = [NSValue valueWithBytes:&psn objCType:@encode(ProcessSerialNumber)];
	[self removeSerialFromAppList:psnv];
	[self mediaKeyAppListChanged];
}

static pascal OSStatus appSwitched (EventHandlerCallRef nextHandler, EventRef evt, void* userData)
{
	SPMediaKeyTap *self = (id)userData;

    ProcessSerialNumber newSerial;
    GetFrontProcess(&newSerial);
	
	[self appIsNowFrontmost:newSerial];
		
    return CallNextEventHandler(nextHandler, evt);
}

static pascal OSStatus appTerminated (EventHandlerCallRef nextHandler, EventRef evt, void* userData)
{
	SPMediaKeyTap *self = (id)userData;
	
	ProcessSerialNumber deadPSN;

	GetEventParameter(
		evt, 
		kEventParamProcessID, 
		typeProcessSerialNumber, 
		NULL, 
		sizeof(deadPSN), 
		NULL, 
		&deadPSN
	);

	
	[self appTerminated:deadPSN];
    return CallNextEventHandler(nextHandler, evt);
}

@end
