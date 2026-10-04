#import "NFPPrefs.h"
#include <roothide.h>
#include <notify.h>

@implementation NFPPrefs

+ (NSString *)path {
	return jbroot(@"/var/mobile/Library/Preferences/org.wuffs.flickplus.plist");
}

+ (NSDictionary *)load {
	return [NSDictionary dictionaryWithContentsOfFile:[self path]] ?: @{};
}

+ (void)setObject:(id)value forKey:(NSString *)key {
	NSMutableDictionary *prefs = [[self load] mutableCopy];
	prefs[key] = value;
	[self replaceAll:prefs];
}

+ (void)replaceAll:(NSDictionary *)prefs {
	NSString *path = [self path];
	[[NSFileManager defaultManager]
		createDirectoryAtPath:[path stringByDeletingLastPathComponent]
		withIntermediateDirectories:YES
		attributes:nil
		error:NULL];
	if (![prefs writeToFile:path atomically:YES])
		NSLog(@"[FlicksForAll] couldn't write preferences to %@", path);
	notify_post(NFP_PREFS_CHANGED);
}

@end
