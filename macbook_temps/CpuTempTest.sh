#!/usr/bin/env bash
set -euo pipefail

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

typedef const void * IOHIDEventSystemClient;
typedef const void * IOHIDServiceClient;
typedef const void * IOHIDEvent;

typedef IOHIDEventSystemClient (*IOHIDEventSystemClientCreate_f)(CFAllocatorRef);
typedef void (*IOHIDEventSystemClientSetMatching_f)(IOHIDEventSystemClient, CFDictionaryRef);
typedef CFArrayRef (*IOHIDEventSystemClientCopyServices_f)(IOHIDEventSystemClient);
typedef CFTypeRef (*IOHIDServiceClientCopyProperty_f)(IOHIDServiceClient, CFStringRef);
typedef IOHIDEvent (*IOHIDServiceClientCopyEvent_f)(IOHIDServiceClient, long long, int, long long);
typedef double (*IOHIDEventGetFloatValue_f)(IOHIDEvent, uint32_t);

static NSString *normalizeSensorName(NSString *name) {
  if (!name || [name length] == 0) return @"unknown_sensor_c";

  NSString *lower = [name lowercaseString];

  if ([lower isEqualToString:@"gas gauge battery"]) {
    return @"battery_gas_gauge_c";
  }

  if ([lower isEqualToString:@"pmu tcal"]) {
    return @"pmu_calibration_c";
  }

  if ([lower hasPrefix:@"pmu tdie"]) {
    NSString *suffix = [name substringFromIndex:[@"PMU tdie" length]];
    if ([suffix length] > 0) {
      return [NSString stringWithFormat:@"cpu_die_%@_c", suffix];
    }
    return @"cpu_die_c";
  }

  if ([lower hasPrefix:@"pmu tdev"]) {
    NSString *suffix = [name substringFromIndex:[@"PMU tdev" length]];
    if ([suffix length] > 0) {
      return [NSString stringWithFormat:@"cpu_proximity_%@_c", suffix];
    }
    return @"cpu_proximity_c";
  }

  if ([lower hasPrefix:@"nand ch"] && [lower hasSuffix:@" temp"]) {
    NSString *mid = [lower stringByReplacingOccurrencesOfString:@"nand " withString:@""];
    mid = [mid stringByReplacingOccurrencesOfString:@" temp" withString:@""];
    mid = [mid stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return [NSString stringWithFormat:@"nand_%@_c", mid];
  }

  NSString *clean = lower;
  clean = [clean stringByReplacingOccurrencesOfString:@" " withString:@"_"];
  clean = [clean stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
  clean = [clean stringByReplacingOccurrencesOfString:@"/" withString:@"_"];

  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"];
  NSMutableString *result = [NSMutableString string];
  for (NSUInteger i = 0; i < [clean length]; i++) {
    unichar ch = [clean characterAtIndex:i];
    if ([allowed characterIsMember:ch]) {
      [result appendFormat:@"%C", ch];
    }
  }

  while ([result containsString:@"__"]) {
    [result replaceOccurrencesOfString:@"__"
                            withString:@"_"
                               options:0
                                 range:NSMakeRange(0, [result length])];
  }

  if ([result hasPrefix:@"_"]) {
    [result deleteCharactersInRange:NSMakeRange(0, 1)];
  }
  if ([result hasSuffix:@"_"]) {
    [result deleteCharactersInRange:NSMakeRange([result length] - 1, 1)];
  }

  if ([result length] == 0) {
    return @"unknown_sensor_c";
  }

  return [NSString stringWithFormat:@"%@_c", result];
}

NSArray* readIOHIDTemps() {
  void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!h) return @[];

  IOHIDEventSystemClientCreate_f create =
    dlsym(h, "IOHIDEventSystemClientCreate");
  IOHIDEventSystemClientSetMatching_f setMatch =
    dlsym(h, "IOHIDEventSystemClientSetMatching");
  IOHIDEventSystemClientCopyServices_f copyServices =
    dlsym(h, "IOHIDEventSystemClientCopyServices");
  IOHIDServiceClientCopyProperty_f copyProp =
    dlsym(h, "IOHIDServiceClientCopyProperty");
  IOHIDServiceClientCopyEvent_f copyEvent =
    dlsym(h, "IOHIDServiceClientCopyEvent");
  IOHIDEventGetFloatValue_f getVal =
    dlsym(h, "IOHIDEventGetFloatValue");

  if (!create || !setMatch || !copyServices || !copyProp || !copyEvent || !getVal) {
    return @[];
  }

  IOHIDEventSystemClient client = create(kCFAllocatorDefault);

  int page = 65280;
  int usage = 5;

  CFNumberRef p = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
  CFNumberRef u = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);

  const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
  const void *vals[] = { p, u };

  CFDictionaryRef match =
    CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                       &kCFTypeDictionaryKeyCallBacks,
                       &kCFTypeDictionaryValueCallBacks);

  setMatch(client, match);

  CFRelease(match);
  CFRelease(p);
  CFRelease(u);

  CFArrayRef services = copyServices(client);
  if (!services) return @[];

  NSMutableArray *out = [NSMutableArray array];
  CFIndex count = CFArrayGetCount(services);

  for (CFIndex i = 0; i < count; i++) {
    IOHIDServiceClient svc = (IOHIDServiceClient)CFArrayGetValueAtIndex(services, i);
    if (!svc) continue;

    NSString *name = nil;

    CFTypeRef prod = copyProp(svc, CFSTR("Product"));
    if (prod && CFGetTypeID(prod) == CFStringGetTypeID()) {
      name = [(__bridge NSString*)prod copy];
    }
    if (prod) CFRelease(prod);

    if (!name) {
      name = [NSString stringWithFormat:@"sensor_%ld", (long)i];
    }

    IOHIDEvent ev = copyEvent(svc, 15, 0, 0);
    if (!ev) continue;

    double c = getVal(ev, 983040);

    if (c > -200 && c < 200) {
      [out addObject:@{
        @"name": name,
        @"normalized_name": normalizeSensorName(name),
        @"c": @(c)
      }];
    }
  }

  CFRelease(services);
  return out;
}

int main() {
  @autoreleasepool {
    NSArray *temps = readIOHIDTemps();

    if ([temps count] == 0) {
      printf("status=no_iouid_temps_found\n");
      printf("message=likely_macos_14_or_newer_smc_path_needed\n");
      return 0;
    }

    for (NSDictionary *d in temps) {
      NSString *normalized = d[@"normalized_name"];
      double v = [d[@"c"] doubleValue];
      printf("%s=%.1f\n", [normalized UTF8String], v);
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
