#include "NFPListController.h"
#import <Preferences/PSSpecifier.h>
#import "../NFPPrefs.h"

@implementation NFPListController

static BOOL isOurs(PSSpecifier *specifier) {
	return [specifier.properties[@"defaults"] isEqualToString:@"org.wuffs.flickplus"]
		&& specifier.properties[@"key"] != nil;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
	if (!isOurs(specifier))
		return [super readPreferenceValue:specifier];

	return [NFPPrefs load][specifier.properties[@"key"]] ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	if (!isOurs(specifier)) {
		[super setPreferenceValue:value specifier:specifier];
		return;
	}

	[NFPPrefs setObject:value forKey:specifier.properties[@"key"]];
}

@end
