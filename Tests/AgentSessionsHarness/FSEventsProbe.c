#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <stdio.h>

static void callback(ConstFSEventStreamRef stream, void *context, size_t count,
                     void *paths, const FSEventStreamEventFlags flags[],
                     const FSEventStreamEventId ids[]) {
    (void)stream; (void)context; (void)count; (void)paths; (void)flags; (void)ids;
}

int main(int argc, const char *argv[]) {
    if (argc != 2) return 2;
    CFStringRef path = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);
    CFArrayRef paths = CFArrayCreate(NULL, (const void **)&path, 1, &kCFTypeArrayCallBacks);
    FSEventStreamContext context = {0, NULL, NULL, NULL, NULL};
    FSEventStreamRef stream = FSEventStreamCreate(NULL, callback, &context, paths,
        kFSEventStreamEventIdSinceNow, 10, kFSEventStreamCreateFlagFileEvents);
    printf("stream_created=%d\n", stream != NULL);
    if (stream) {
        FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
        Boolean started = FSEventStreamStart(stream);
        printf("stream_started=%d\n", started);
        if (started) FSEventStreamStop(stream);
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
    }
    CFRelease(paths); CFRelease(path);
    return 0;
}
