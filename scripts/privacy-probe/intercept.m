#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Only loaded into the isolated unsigned probe copy; never into a distributed app.
static id probeUpdater;

static void record(NSDictionary *entry) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    FILE *file = fopen(getenv("BEEPBAR_PROBE_TRACE"), "a");
    if (file && data) { fwrite(data.bytes, 1, data.length, file); fputc('\n', file); }
    if (file) fclose(file);
}

@interface PrivacyProbeProtocol : NSURLProtocol
@end
@implementation PrivacyProbeProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [@[@"https", @"http"] containsObject:request.URL.scheme];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSMutableData *payload = [NSMutableData dataWithData:self.request.HTTPBody ?: [NSData data]];
    if (!payload.length && self.request.HTTPBodyStream) {
        NSInputStream *stream = self.request.HTTPBodyStream;
        [stream open];
        uint8_t buffer[4096]; NSInteger count;
        while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [payload appendBytes:buffer length:(NSUInteger)count];
        [stream close];
    }
    NSString *body = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"";
    record(@{@"kind":@"request", @"url":self.request.URL.absoluteString ?: @"", @"method":self.request.HTTPMethod ?: @"", @"body":body});
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)stopLoading {}
@end

@interface NSURLSession (PrivacyProbe)
+ (NSURLSession *)privacyProbeSessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue;
@end
@implementation NSURLSession (PrivacyProbe)
+ (NSURLSession *)privacyProbeSessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue {
    configuration.protocolClasses = @[PrivacyProbeProtocol.class];
    return [self privacyProbeSessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}
@end

@interface NSAlert (PrivacyProbe)
- (NSModalResponse)privacyProbeRunModal;
@end
@implementation NSAlert (PrivacyProbe)
- (NSModalResponse)privacyProbeRunModal {
    NSMutableArray *texts = [NSMutableArray array];
    NSMutableArray<NSView *> *pending = [NSMutableArray array];
    if (self.accessoryView) [pending addObject:self.accessoryView];
    while (pending.count) {
        NSView *view = pending.lastObject; [pending removeLastObject];
        if ([view isKindOfClass:NSTextView.class]) [texts addObject:((NSTextView *)view).string];
        [pending addObjectsFromArray:view.subviews];
    }
    record(@{@"kind":@"alert", @"title":self.messageText, @"summary":self.informativeText, @"details":texts, @"buttons":[self.buttons valueForKey:@"title"]});
    return strcmp(getenv("BEEPBAR_PROBE_CHOICE") ?: "disable", "continue") == 0 ? NSAlertFirstButtonReturn : NSAlertSecondButtonReturn;
}
@end

@interface NSObject (PrivacyProbeUpdater)
- (id)privacyProbeInitWithHostBundle:(NSBundle *)host applicationBundle:(NSBundle *)application userDriver:(id)driver delegate:(id)delegate;
@end
@implementation NSObject (PrivacyProbeUpdater)
- (id)privacyProbeInitWithHostBundle:(NSBundle *)host applicationBundle:(NSBundle *)application userDriver:(id)driver delegate:(id)delegate {
    id updater = [self privacyProbeInitWithHostBundle:host applicationBundle:application userDriver:driver delegate:delegate];
    probeUpdater = updater;
    return updater;
}
@end

@interface PrivacyProbe : NSObject
@end
@implementation PrivacyProbe
+ (void)load {
    Class updater = NSClassFromString(@"SPUUpdater");
    SEL original = NSSelectorFromString(@"initWithHostBundle:applicationBundle:userDriver:delegate:");
    SEL replacement = @selector(privacyProbeInitWithHostBundle:applicationBundle:userDriver:delegate:);
    Method method = class_getInstanceMethod(NSObject.class, replacement);
    if (updater && class_getInstanceMethod(updater, original)) {
        class_addMethod(updater, replacement, method_getImplementation(method), method_getTypeEncoding(method));
        method_exchangeImplementations(class_getInstanceMethod(updater, original), class_getInstanceMethod(updater, replacement));
    }
    method_exchangeImplementations(class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:delegate:delegateQueue:)), class_getClassMethod(NSURLSession.class, @selector(privacyProbeSessionWithConfiguration:delegate:delegateQueue:)));
    method_exchangeImplementations(class_getInstanceMethod(NSAlert.class,@selector(runModal)),class_getInstanceMethod(NSAlert.class,@selector(privacyProbeRunModal)));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (probeUpdater) {
            record(@{@"kind":@"updater", @"feedURL":[[probeUpdater valueForKey:@"feedURL"] absoluteString] ?: @"",
                     @"sendsSystemProfile":[probeUpdater valueForKey:@"sendsSystemProfile"] ?: @YES,
                     @"automaticallyChecksForUpdates":[probeUpdater valueForKey:@"automaticallyChecksForUpdates"] ?: @NO,
                     @"httpHeaders":[probeUpdater valueForKey:@"httpHeaders"] ?: @{},
                     @"hasDelegate":@((BOOL)([probeUpdater valueForKey:@"delegate"] != nil))});
        }
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:@{@"kind":@"state"}];
        for (NSString *key in @[@"dailyTelemetryEnabled", @"dailyTelemetryDisclosureVersion", @"dailyTelemetryMonthlyID", @"dailyTelemetryInstallationID", @"dailyTelemetryMonth", @"dailyTelemetryCountedMonth", @"dailyTelemetryLastAttempt"]) {
            id value = [defaults objectForKey:key];
            if (value) state[key] = [value isKindOfClass:NSDate.class] ? [value description] : value;
        }
        state[@"effectiveTelemetryEnabled"] = [defaults objectForKey:@"dailyTelemetryEnabled"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"BeepBarTelemetryDefaultEnabled"] ?: @NO;
        record(state);
        [defaults synchronize];
        exit(0);
    });
}
@end
