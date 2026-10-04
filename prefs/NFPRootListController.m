#include "NFPRootListController.h"
#import "NFPKeyboardController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "../h/UIKeyboardInputMode.h"
#import "../h/UIKeyboardInputModeController.h"
#import "../h/UIKeyboardCache.h"
#import "../NFPPrefs.h"
#include <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation NFPRootListController

// settings used to go through cfprefsd, carry them over to NFPPrefs once
+ (void)migrateOldPreferences {
	if ([[NSFileManager defaultManager] fileExistsAtPath:[NFPPrefs path]])
		return;
	NSDictionary *old = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, CFSTR("org.wuffs.flickplus"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
	if (old.count > 0)
		[NFPPrefs replaceAll:old];
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		[NFPRootListController migrateOldPreferences];

		NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];

		NSArray *inputModeIDs = [[UIKeyboardInputModeController sharedInputModeController] activeInputModeIdentifiers];
		NSSet *layouts = [[objc_getClass("UIKeyboardCache") sharedInstance] uniqueLayoutsFromInputModes:inputModeIDs];
		// layouts go right after the "Active Layouts" group header
		NSUInteger listIndex = [specs indexOfObjectPassingTest:^BOOL(PSSpecifier *spec, NSUInteger idx, BOOL *stop) {
			return [spec.identifier isEqualToString:@"activeLayouts"];
		}] + 1;

		// this can maybe be made nicer by using PSListController methods
		for (NSString *layout in layouts) {
			if ([layout isEqualToString:@"Emoji"])
				continue;

			PSSpecifier *spec = [PSSpecifier
				preferenceSpecifierNamed:layout
				target:self
				set:NULL
				get:NULL
				detail:[NFPKeyboardController class]
				cell:PSLinkCell
				edit:Nil];
			[spec setProperty:@YES forKey:@"enabled"];
			[spec setProperty:layout forKey:@"fp-keyboard-layout"];
			[specs insertObject:spec atIndex:listIndex++];
		}

		_specifiers = specs;

		// dim the strength picker if haptics start off
		PSSpecifier *hapticSwitch = [self specifierForKey:@"hapticFeedback"];
		id hapticOn = hapticSwitch ? [self readPreferenceValue:hapticSwitch] : nil;
		[self setHapticStrengthEnabled:(hapticOn == nil || [hapticOn boolValue]) reload:NO];
	}

	return _specifiers;
}

- (PSSpecifier *)specifierForKey:(NSString *)key {
	for (PSSpecifier *specifier in _specifiers) {
		if ([specifier.properties[@"key"] isEqualToString:key])
			return specifier;
	}
	return nil;
}

- (void)setHapticStrengthEnabled:(BOOL)enabled reload:(BOOL)reload {
	PSSpecifier *strength = [self specifierForID:@"hapticStrength"];
	[strength setProperty:@(enabled) forKey:@"enabled"];
	if (reload)
		[self reloadSpecifier:strength animated:YES];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];

	if ([specifier.properties[@"key"] isEqualToString:@"hapticFeedback"])
		[self setHapticStrengthEnabled:[value boolValue] reload:YES];
}


- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

// presets are a plist wrapping every stored preference, custom flick
// symbols included, plus a marker so we don't import random plists
- (void)exportPresetTapped:(PSSpecifier *)specifier {
	NSDictionary *preset = @{
		@"FlicksForAllPreset": @1,
		@"preferences": [NFPPrefs load]
	};

	NSError *error = nil;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:preset format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
	NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"FlicksForAll Preset.plist"]];
	if (data == nil || ![data writeToURL:url options:NSDataWritingAtomic error:&error]) {
		[self showAlertWithTitle:@"Export Failed" message:error.localizedDescription];
		return;
	}

	UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
	share.popoverPresentationController.sourceView = self.view;
	share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
	[self presentViewController:share animated:YES completion:nil];
}

- (void)importPresetTapped:(PSSpecifier *)specifier {
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePropertyList] asCopy:YES];
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSData *data = [NSData dataWithContentsOfURL:urls.firstObject];
	id preset = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
	NSDictionary *values = [preset isKindOfClass:[NSDictionary class]] ? preset[@"preferences"] : nil;
	if (preset[@"FlicksForAllPreset"] == nil || ![values isKindOfClass:[NSDictionary class]]) {
		[self showAlertWithTitle:@"Import Failed" message:@"This file isn't a FlicksForAll preset."];
		return;
	}

	UIAlertController *confirm = [UIAlertController
		alertControllerWithTitle:@"Import Preset"
		message:@"All of your current FlicksForAll settings will be replaced by this preset. Are you sure?"
		preferredStyle:UIAlertControllerStyleAlert];
	[confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[confirm addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		[NFPPrefs replaceAll:values];
		[self reloadSpecifiers];
	}]];
	// the picker may still be dismissing, so present once it's gone
	dispatch_async(dispatch_get_main_queue(), ^{
		[self presentViewController:confirm animated:YES completion:nil];
	});
}


- (void)resetSettingsTapped:(PSSpecifier *)specifier {
	[NFPPrefs replaceAll:@{}];
	[self reloadSpecifiers];
}


- (void)openURL:(PSSpecifier *)specifier {
	NSURL *url = [NSURL URLWithString:specifier.properties[@"url"]];
	[[UIApplication sharedApplication] openURL:url];
}

@end
