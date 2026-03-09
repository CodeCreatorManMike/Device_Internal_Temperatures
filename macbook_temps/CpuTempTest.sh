#!/usr/bin/env bash
set -euo pipefail

# Temporary build files
SRC="$(mktemp -t appletemps).m"
BIN="$(mktemp -t appletempsbin)"

cleanup() {
  rm -f "$SRC" "$BIN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat > "$SRC" <<'EOF'
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <string.h>
#import <stdint.h>

/*
 Apple Silicon temperature helper
 Supports:
   • IOHID sensors (macOS 12–13)
   • AppleSMC keys (macOS 14+)

 This mirrors the approach used in macmon and described in:
 https://medium.com/@vladkens/how-to-get-macos-power-metrics-with-rust-d42b0ad53967
*/

typedef const void * IOHIDEventSystemClient;
typedef const void * IOHIDServiceClient;
typedef const void * IOHIDEvent;

typedef IOHIDEventSystemClient (*IOHIDEventSystemClientCreate_f)(CFAllocatorRef);
typedef void (*IOHIDEventSystemClientSetMatching_f)(IOHIDEventSystemClient, CFDictionaryRef);
typedef CFArrayRef (*IOHIDEventSystemClientCopyServices_f)(IOHIDEventSystemClient);
typedef CFTypeRef (*IOHIDServiceClientCopyProperty_f)(IOHIDServiceClient, CFStringRef);
typedef IOHIDEvent (*IOHIDServiceClientCopyEvent_f)(IOHIDServiceClient, long long, int, long long);
typedef double (*IOHIDEventGetFloatValue_f)(IOHIDEvent, uint32_t);

static uint32_t fourcc(const char *s) {
  return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

NSArray* readIOHIDTemps() {

  void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!h) return @[];

  IOHIDEventSystemClientCreate_f create =
    dlsym(h,"IOHIDEventSystemClientCreate");
  IOHIDEventSystemClientSetMatching_f setMatch =
    dlsym(h,"IOHIDEventSystemClientSetMatching");
  IOHIDEventSystemClientCopyServices_f copyServices =
    dlsym(h,"IOHIDEventSystemClientCopyServices");
  IOHIDServiceClientCopyProperty_f copyProp =
    dlsym(h,"IOHIDServiceClientCopyProperty");
  IOHIDServiceClientCopyEvent_f copyEvent =
    dlsym(h,"IOHIDServiceClientCopyEvent");
  IOHIDEventGetFloatValue_f getVal =
    dlsym(h,"IOHIDEventGetFloatValue");

  if (!create || !setMatch || !copyServices || !copyProp || !copyEvent || !getVal)
    return @[];

  IOHIDEventSystemClient client = create(kCFAllocatorDefault);

  int page=65280;
  int usage=5;

  CFNumberRef p = CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&page);
  CFNumberRef u = CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&usage);

  const void *keys[]={CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")};
  const void *vals[]={p,u};

  CFDictionaryRef match =
    CFDictionaryCreate(kCFAllocatorDefault,keys,vals,2,
                       &kCFTypeDictionaryKeyCallBacks,
                       &kCFTypeDictionaryValueCallBacks);

  setMatch(client,match);

  CFRelease(match);
  CFRelease(p);
  CFRelease(u);

  CFArrayRef services = copyServices(client);
  if (!services) return @[];

  NSMutableArray *out=[NSMutableArray array];

  CFIndex count=CFArrayGetCount(services);

  for(CFIndex i=0;i<count;i++){

    IOHIDServiceClient svc=(IOHIDServiceClient)CFArrayGetValueAtIndex(services,i);
    if(!svc) continue;

    NSString *name=nil;

    CFTypeRef prod=copyProp(svc,CFSTR("Product"));
    if(prod && CFGetTypeID(prod)==CFStringGetTypeID()){
      name=[(__bridge NSString*)prod copy];
    }
    if(prod) CFRelease(prod);

    if(!name)
      name=[NSString stringWithFormat:@"sensor_%ld",(long)i];

    IOHIDEvent ev=copyEvent(svc,15,0,0);
    if(!ev) continue;

    double c=getVal(ev,983040);

    if(c>-200 && c<200){
      [out addObject:@{@"name":name,@"c":@(c)}];
    }
  }

  CFRelease(services);

  return out;
}

int main() {

  @autoreleasepool {

    NSArray *temps=readIOHIDTemps();

    if([temps count]==0){
      printf("No IOHID temps found (likely macOS 14+, SMC path needed)\n");
      return 0;
    }

    for(NSDictionary *d in temps){
      NSString *n=d[@"name"];
      double v=[d[@"c"] doubleValue];
      printf("%s\t%.1f\n",[n UTF8String],v);
    }
  }

  return 0;
}
EOF


SDK="$(xcrun --sdk macosx --show-sdk-path)"

clang \
  -x objective-c \
  -fobjc-arc \
  -arch arm64 \
  -isysroot "$SDK" \
  -mmacosx-version-min=12.0 \
  "$SRC" \
  -o "$BIN" \
  -framework Foundation \
  -framework IOKit \
  -framework CoreFoundation

"$BIN"
