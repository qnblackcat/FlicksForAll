// Other Settings: small tweaks that ride along with FlicksForAll but share
// none of its code. Each one has its own switch; the hooks are always
// installed and check their flag on each call, so toggling them in Settings
// takes effect without a respring.

#import <UIKit/UIKit.h>
#include <objc/runtime.h>
#include <notify.h>
#include "NFPPrefs.h"
#include "ShiftDelete.h"

static bool noPasteAlertsEnabled = NO;
static bool noPastedFromEnabled = NO;
static bool noKeyboardSettingsEnabled = NO;
static bool dictationHidesKeyboardEnabled = NO;

@interface SBUserNotificationAlert : NSObject
- (void)_setActivated:(BOOL)activated;
- (void)_sendResponseAndCleanUp:(BOOL)cleanup;
@end

// based on NoPasteAlerts16 by 0xkuj
// iOS 16's "Allow Paste" prompt is a user notification posted by pasted
%group NoPasteAlerts
%hook SBAlertItem
+ (void)activateAlertItem:(id)alertItem {
	if (noPasteAlertsEnabled && [alertItem isKindOfClass:%c(SBUserNotificationAlert)]
	    && class_getInstanceVariable([alertItem class], "_alertSource")) {
		NSString *source = MSHookIvar<NSString *>(alertItem, "_alertSource");
		if ([source isEqualToString:@"pasted"]) {
			[alertItem _setActivated:NO];
			if ([alertItem respondsToSelector:@selector(_sendResponseAndCleanUp:)])
				[alertItem _sendResponseAndCleanUp:YES];
			return;
		}
	}
	%orig;
}
%end
%end

// based on NoPastedFrom by Brend0n
// druid shows the "X pasted from Y" banner; iOS 17+ uses
// DRRemotePasteAnnouncer instead of DRPasteAnnouncer behind a feature flag
%group DRPasteAnnouncer
%hook DRPasteAnnouncer
- (void)announcePaste:(id)paste {
	if (!noPastedFromEnabled)
		%orig;
}
%end
%end

%group DRRemotePasteAnnouncer
%hook DRRemotePasteAnnouncer
- (void)announcePaste:(id)paste {
	if (!noPastedFromEnabled)
		%orig;
}
%end
%end

@interface UIInputSwitcherItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@end

@interface UIInputSwitcherView : UIView
@end

// based on NoKeyboardSettings by Brend0n
// drops Keyboard Settings, Dictation Settings and the one-handed keyboard
// buttons from the menu you get by holding the globe key
%group NoKeyboardSettings
%hook UIInputSwitcherView
- (void)_reloadInputSwitcherItems {
	%orig;
	if (!noKeyboardSettingsEnabled || !class_getInstanceVariable([self class], "m_inputSwitcherItems"))
		return;

	NSSet *hidden = [NSSet setWithObjects:@"launchkeyboardsettings", @"launchdictationsettings", @"handbiasswitch", nil];
	NSArray *items = MSHookIvar<NSArray *>(self, "m_inputSwitcherItems");
	NSIndexSet *keep = [items indexesOfObjectsPassingTest:^BOOL(UIInputSwitcherItem *item, NSUInteger idx, BOOL *stop) {
		return ![item respondsToSelector:@selector(identifier)] || ![hidden containsObject:item.identifier];
	}];
	if (keep.count != items.count)
		MSHookIvar<NSArray *>(self, "m_inputSwitcherItems") = [items objectsAtIndexes:keep];
}
%end
%end

@interface UIKeyboardImpl : UIView
+ (instancetype)activeInstance;
- (void)dismissKeyboard;
@end

@interface UIKeyboardDockItem : NSObject
@property (nonatomic) bool enabled;
- (void)setImageName:(NSString *)name; // iOS 16 and earlier
- (NSString *)title; // iOS 17+
- (void)setTitle:(NSString *)title image:(UIImage *)image; // iOS 17+
@end

@interface UIKeyboardDockView : UIView
@property (nonatomic, retain) UIKeyboardDockItem *rightDockItem;
@end

@interface UIDictationController : NSObject
+ (bool)isRunning;
@end

@interface UISystemKeyboardDockController : UIViewController
@property (nonatomic, retain) UIKeyboardDockView *dockView;
- (UIImage *)configuredGlyphWithName:(NSString *)name; // iOS 17+
@end

#define HIDE_KEYBOARD_GLYPH @"keyboard.chevron.compact.down"
// a hold this long still goes to dictation
#define DICTATION_HOLD_DURATION 0.5

// whether iOS itself would have shown the mic, before we force the item on
static bool dictationAvailable = NO;
static NSTimeInterval dictationTouchBegan = 0;
// decided when the finger lands: false while the mic is a stop button for
// running dictation (English keeps the keyboard up), so that tap stops it
static bool dictationTapHidesKeyboard = NO;

// a quick tap hides the keyboard, a hold runs the original tapAction
static id wrapDictationTap(UIEvent *event, id tapAction) {
	UITouch *touch = [[event allTouches] anyObject];
	if (touch.phase == UITouchPhaseBegan)
		dictationTouchBegan = touch.timestamp;

	void (^startDictation)(void) = tapAction;
	return ^{
		NSTimeInterval held = [[NSProcessInfo processInfo] systemUptime] - dictationTouchBegan;
		if (dictationAvailable && held >= DICTATION_HOLD_DURATION && startDictation)
			startDictation();
		else
			[[objc_getClass("UIKeyboardImpl") activeInstance] dismissKeyboard];
	};
}

// Face ID iPhones only: the mic in the bottom right corner of the dock turns
// into a hide keyboard button. Home button iPhones have no dock, so this
// does nothing there
%group DictationHidesKeyboard
%hook UISystemKeyboardDockController
// runs whenever iOS refreshes the dock, putting the mic icon back each time,
// so turning the setting off restores the mic on its own
- (void)updateDockItemsVisibility {
	%orig;
	if (!dictationHidesKeyboardEnabled || !class_getInstanceVariable([self class], "_dictationDockItem"))
		return;

	// the right item is a different one while dictation is running or the
	// dictation layout is up, leave those alone
	UIKeyboardDockItem *item = MSHookIvar<UIKeyboardDockItem *>(self, "_dictationDockItem");
	if (item == nil || self.dockView.rightDockItem != item)
		return;

	dictationAvailable = item.enabled;
	if ([self respondsToSelector:@selector(configuredGlyphWithName:)] && [item respondsToSelector:@selector(setTitle:image:)]) {
		UIImage *glyph = [self configuredGlyphWithName:HIDE_KEYBOARD_GLYPH];
		if (glyph)
			[item setTitle:item.title image:glyph];
	} else if ([item respondsToSelector:@selector(setImageName:)]) {
		[item setImageName:HIDE_KEYBOARD_GLYPH];
	}
	item.enabled = YES;
}

// runs before the dock stops a running dictation and calls buttonPressed:,
// so this still sees whether dictation was running when the finger landed
- (void)dictationItemButtonWasPressed:(id)button withEvent:(UIEvent *)event isRunningButton:(bool)isRunningButton {
	if ([[event allTouches] anyObject].phase == UITouchPhaseBegan)
		dictationTapHidesKeyboard = !isRunningButton && ![%c(UIDictationController) isRunning];
	%orig;
}
%end

%hook UIInputSwitcherView
// the dock hands every touch on the mic to this, and tapAction is what
// actually starts dictation
- (id)buttonPressed:(id)button withEvent:(UIEvent *)event location:(CGPoint)location isForDictation:(bool)isForDictation tapAction:(id)tapAction {
	if (!dictationHidesKeyboardEnabled || !isForDictation || !dictationTapHidesKeyboard)
		return %orig;
	return %orig(button, event, location, isForDictation, wrapDictationTap(event, tapAction));
}

// iOS 17+
- (id)buttonPressed:(id)button withEvent:(UIEvent *)event location:(CGPoint)location isLocationInsideViewHitArea:(bool)insideHitArea isForDictation:(bool)isForDictation tapAction:(id)tapAction {
	if (!dictationHidesKeyboardEnabled || !isForDictation || !dictationTapHidesKeyboard)
		return %orig;
	return %orig(button, event, location, insideHitArea, isForDictation, wrapDictationTap(event, tapAction));
}
%end
%end

static void syncPreferences() {
	NSDictionary *prefs = [NFPPrefs load];
	noPasteAlertsEnabled = [prefs[@"noPasteAlerts"] boolValue];
	noPastedFromEnabled = [prefs[@"noPastedFrom"] boolValue];
	noKeyboardSettingsEnabled = [prefs[@"noKeyboardSettings"] boolValue];
	dictationHidesKeyboardEnabled = [prefs[@"dictationHidesKeyboard"] boolValue];
	NFPShiftDeleteSync(prefs);
}

%ctor {
	syncPreferences();
	int token;
	notify_register_dispatch(NFP_PREFS_CHANGED, &token, dispatch_get_main_queue(), ^(int t) {
		syncPreferences();
	});

	// druid only gets the "pasted from" banner hook
	if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"druid"]) {
		if (objc_getClass("DRPasteAnnouncer")) %init(DRPasteAnnouncer);
		if (objc_getClass("DRRemotePasteAnnouncer")) %init(DRRemotePasteAnnouncer);
		return;
	}

	if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
		if (@available(iOS 16.0, *))
			%init(NoPasteAlerts);
	}

	%init(NoKeyboardSettings);
	%init(DictationHidesKeyboard);
	// without that dock method there's nothing to tell us dictation is running
	if (![%c(UISystemKeyboardDockController) instancesRespondToSelector:@selector(dictationItemButtonWasPressed:withEvent:isRunningButton:)])
		dictationTapHidesKeyboard = YES;

	NFPShiftDeleteInit();
}
