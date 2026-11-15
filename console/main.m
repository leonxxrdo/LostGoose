// SPDX-License-Identifier: GPL-3.0-only
#import "ILLFixedLocationEngine.h"
#import "ILLTiming.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static BOOL Emit(NSDictionary *value, FILE *stream) {
    NSMutableDictionary *timestamped = [value mutableCopy];
    timestamped[@"emitted_unix_seconds"] = @(NSDate.date.timeIntervalSince1970);
    timestamped[@"emitted_monotonic_seconds"] = @(ILLMonotonicSeconds());
    value = timestamped;
#ifdef ILL_CONSOLE_FAKE_BACKEND
    NSMutableDictionary *tagged = [value mutableCopy];
    tagged[@"backend"] = @"fake_only";
    value = tagged;
#endif
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (!data || fwrite(data.bytes, 1, data.length, stream) != data.length) return NO;
    fputc('\n', stream);
    fflush(stream);
    return YES;
}

static int Fail(NSString *message) {
    Emit(@{@"state": @"error", @"error": message}, stderr);
    return 1;
}

static BOOL ParseNumber(const char *text, double *value) {
    if (!text || !text[0]) return NO;
    char *end = NULL;
    errno = 0;
    double parsed = strtod(text, &end);
    if (errno || !end || *end || !isfinite(parsed)) return NO;
    *value = parsed;
    return YES;
}

static BOOL SocketAddress(NSString *path, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    const char *p = path.fileSystemRepresentation;
    if (strlen(p) >= sizeof(address->sun_path)) return NO;
    strlcpy(address->sun_path, p, sizeof(address->sun_path));
    address->sun_len = sizeof(*address);
    return YES;
}

static int StopOwner(NSString *serverPath, NSString *directory) {
    // Delegate stop to the process that owns the serial worker. Do not run a
    // second manager concurrently with that owner's pending activation.
    NSString *clientPath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"stop-%d.sock", getpid()]];
    struct sockaddr_un server, client;
    if (!SocketAddress(serverPath, &server) || !SocketAddress(clientPath, &client))
        return Fail(@"Control socket path too long");
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return Fail(@"Cannot create stop control socket");
    if (bind(fd, (struct sockaddr *)&client, sizeof(client)) != 0) {
        close(fd);
        return Fail(@"Cannot bind stop control socket");
    }
    struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    ssize_t sent = sendto(fd, "STOP", 4, 0, (struct sockaddr *)&server, sizeof(server));
    char buffer[8192];
    ssize_t size = sent == 4 ? recv(fd, buffer, sizeof(buffer), 0) : -1;
    close(fd);
    unlink(clientPath.fileSystemRepresentation);
    if (size <= 0) return Fail(@"Owner did not confirm stop request; retry; restoration is unconfirmed");
    NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)size];
    NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![report isKindOfClass:NSDictionary.class]) return Fail(@"Invalid owner stop report");
    Emit(report, stdout);
    return [report[@"request_sent"] boolValue] ? 0 : 1;
}

static int RunSession(ILLFixedLocationEngine *engine, double latitude, double longitude,
                      double duration, NSString *socketPath) {
    double sessionBegan = ILLMonotonicSeconds();
    struct sockaddr_un address;
    if (!SocketAddress(socketPath, &address)) return Fail(@"Control socket path too long");
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) return Fail(@"Cannot create session control socket");
    unlink(socketPath.fileSystemRepresentation); // Caller holds exclusive session lock.
    if (bind(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return Fail(@"Cannot bind session control socket");
    }
    dispatch_queue_t control = dispatch_queue_create("org.ios-location-lab.console", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL stopping = NO;
    __block int exitCode = 0;
    __block NSMutableArray<NSData *> *stopClients = [NSMutableArray array];
    __block double stopRequested = 0;
    __block double leaseArmed = 0;
    void (^stop)(NSString *) = ^(NSString *reason) {
        if (stopping) return;
        stopping = YES;
        stopRequested = ILLMonotonicSeconds();
        [engine stopWithCompletion:^(NSDictionary *report) {
            dispatch_async(control, ^{
                NSMutableDictionary *event = [report mutableCopy];
                event[@"stop_reason"] = reason;
                event[@"session_started_monotonic_seconds"] = @(sessionBegan);
                event[@"lease_armed_monotonic_seconds"] = @(leaseArmed);
                event[@"lease_deadline_monotonic_seconds"] = @(leaseArmed + duration);
                event[@"stop_requested_monotonic_seconds"] = @(stopRequested);
                Emit(event, stdout);
                if (![event[@"request_sent"] boolValue]) exitCode = 1;
                NSData *reply = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
                for (NSData *client in stopClients)
                    sendto(socketFD, reply.bytes, reply.length, 0, client.bytes, (socklen_t)client.length);
                dispatch_semaphore_signal(done);
            });
        }];
    };
    // Timers/signals use a different queue from private API calls. A blocked
    // private call cannot be interrupted, but its subsequent steps get canceled.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, control);
    leaseArmed = ILLMonotonicSeconds();
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timer, ^{ stop(@"lease_expired"); });
    NSMutableArray *signals = [NSMutableArray array];
    for (NSNumber *number in @[@(SIGINT), @(SIGTERM), @(SIGHUP)]) {
        int signum = number.intValue;
        signal(signum, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signum, 0, control);
        dispatch_source_set_event_handler(source, ^{ stop(@"signal"); });
        [signals addObject:source];
        dispatch_resume(source);
    }
    dispatch_source_t requests = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socketFD, 0, control);
    dispatch_source_set_event_handler(requests, ^{
        char message[16];
        struct sockaddr_un client;
        socklen_t size = sizeof(client);
        ssize_t received = recvfrom(socketFD, message, sizeof(message), 0, (struct sockaddr *)&client, &size);
        if (received == 4 && memcmp(message, "STOP", 4) == 0 && size <= sizeof(client)) {
            [stopClients addObject:[NSData dataWithBytes:&client length:size]];
            stop(@"control_command");
        }
    });
    dispatch_resume(requests);
    dispatch_resume(timer);
    dispatch_async(control, ^{
        // A very early stop may already have been processed by this queue.
        if (stopping) return;
        [engine startAtLatitude:latitude longitude:longitude completion:^(NSDictionary *report) {
            dispatch_async(control, ^{
                Emit(report, stdout);
                if (![report[@"state"] isEqual:@"activation_requested_unverified"] && !stopping) {
                    exitCode = 1;
                    stop(@"start_failed");
                }
            });
        }];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_sync(control, ^{
        dispatch_source_cancel(timer);
        dispatch_source_cancel(requests);
        for (dispatch_source_t source in signals) dispatch_source_cancel(source);
    });
    close(socketFD);
    unlink(socketPath.fileSystemRepresentation);
    return exitCode;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "inspect") == 0) {
            Emit(ILLInspectSimulationAPI(), stdout);
            return 0;
        }
        BOOL plan = argc == 6 && strcmp(argv[1], "plan") == 0;
        BOOL run = argc == 6 && strcmp(argv[1], "run") == 0;
        BOOL stop = argc == 2 && strcmp(argv[1], "stop") == 0;
        double latitude = 0, longitude = 0, seconds = 0;
        if (plan || run) {
            if (strcmp(argv[4], "--seconds") != 0 || !ParseNumber(argv[2], &latitude)
                || !ParseNumber(argv[3], &longitude) || !ParseNumber(argv[5], &seconds)
                || latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180
                || seconds < 5 || seconds > 300)
                return Fail(@"Use finite coordinates in range and a duration of 5..300 seconds");
        } else if (!stop) {
            fprintf(stderr, "Usage: location-lab inspect | plan LAT LON --seconds N | run LAT LON --seconds N | stop\n");
            return 2;
        }
        if (plan) {
            Emit(@{@"state": @"plan_only", @"selected": @{@"latitude": @(latitude), @"longitude": @(longitude)},
                   @"maximum_duration_seconds": @(seconds), @"manager_instantiated": @NO,
                   @"simulation_requested": @NO, @"automatic_stop": @"best_effort",
                   @"repeat_mode": @1, @"delivery_mode": @0,
                   @"location_observed": NSNull.null, @"restoration_confirmed": NSNull.null}, stdout);
            return 0;
        }
        if (geteuid() != 501) return Fail(@"This experimental console is restricted to mobile (uid 501)");
        NSDictionary *inspection = ILLInspectSimulationAPI();
        // Stop must remain available even if injection is detected.
        if (run && [inspection[@"injection_related_images"] count])
            return Fail(@"Injection-related images detected; isolate this process before activating");
        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/ios-location-lab"];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
              attributes:@{NSFilePosixPermissions: @0700} error:&error]) return Fail(error.localizedDescription);
        umask(0077);
#ifdef ILL_CONSOLE_FAKE_BACKEND
        NSString *lockPath = [directory stringByAppendingPathComponent:@"engine-test.lock"];
        NSString *socketPath = [directory stringByAppendingPathComponent:@"engine-test.sock"];
#else
        NSString *lockPath = [directory stringByAppendingPathComponent:@"engine.lock"];
        NSString *socketPath = [directory stringByAppendingPathComponent:@"engine.sock"];
#endif
        int lockFD = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (lockFD < 0) return Fail(@"Cannot open session lock");
        if (flock(lockFD, LOCK_EX | LOCK_NB) != 0) {
            close(lockFD);
            return stop ? StopOwner(socketPath, directory) : Fail(@"Another session owns the engine");
        }
#ifdef ILL_CONSOLE_FAKE_BACKEND
        extern ILLFixedLocationEngine *ILLCreateFakeConsoleEngine(void);
        ILLFixedLocationEngine *engine = ILLCreateFakeConsoleEngine();
#else
        ILLFixedLocationEngine *engine = [ILLFixedLocationEngine new];
#endif
        int result;
        if (run) result = RunSession(engine, latitude, longitude, seconds, socketPath);
        else {
            dispatch_semaphore_t completed = dispatch_semaphore_create(0);
            __block BOOL submitted = NO;
            [engine stopWithCompletion:^(NSDictionary *report) {
                submitted = [report[@"request_sent"] boolValue];
                Emit(report, stdout);
                dispatch_semaphore_signal(completed);
            }];
            dispatch_semaphore_wait(completed, DISPATCH_TIME_FOREVER);
            result = submitted ? 0 : 1;
        }
        flock(lockFD, LOCK_UN);
        close(lockFD);
        return result;
    }
}
