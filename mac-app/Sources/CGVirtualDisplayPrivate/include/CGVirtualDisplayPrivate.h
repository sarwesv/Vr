#ifndef CGVirtualDisplayPrivate_h
#define CGVirtualDisplayPrivate_h

// Forward declarations for Apple's *private*, undocumented virtual-display
// classes that live inside the public CoreGraphics.framework binary. These
// symbols are not exposed in any public header, but the classes themselves
// ship on-disk in every macOS 13+ install and are what tools such as
// BetterDisplay/BetterDummy (MIT-licensed, open source) use to create a
// genuine extra "monitor" macOS will let you drag windows onto.
//
// This is unsupported by Apple: the class/selector names below can change
// or disappear in a future macOS release without notice. Treat "extend"
// mode as experimental; "mirror" mode (ScreenCaptureSource on the real
// display) always works via public APIs and should be the safe fallback.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                        height:(NSUInteger)height
                   refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) NSUInteger hiDPI;
@property(nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t serialNum;
@property(nonatomic, nullable) dispatch_queue_t queue;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

NS_ASSUME_NONNULL_END

#endif /* CGVirtualDisplayPrivate_h */
