#import <Preferences/PSListController.h>

// Stores every specifier with defaults = org.wuffs.flickplus in NFPPrefs
// rather than letting PSListController write it through cfprefsd.
@interface NFPListController : PSListController
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end
