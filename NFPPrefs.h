#import <Foundation/Foundation.h>

#define NFP_PREFS_CHANGED "org.wuffs.flickplus/ReloadPrefs"

// All settings live in one plist inside jbroot instead of going through
// cfprefsd. Sandboxed processes (Messages, Music, every App Store app...) are
// denied our domain by cfprefsd, but they can read files inside jbroot, which
// is where the tweak itself gets loaded from.
@interface NFPPrefs : NSObject
+ (NSString *)path;
+ (NSDictionary *)load;
// these post NFP_PREFS_CHANGED after writing; a nil value removes the key
+ (void)setObject:(id)value forKey:(NSString *)key;
+ (void)replaceAll:(NSDictionary *)prefs;
@end
