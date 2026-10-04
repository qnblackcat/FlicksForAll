#include "h/UIKBTree.h"
#include "h/UIKeyboardCache.h"
#include "h/UIKBTouchState.h"
#include "h/UIKeyboardTaskExecutionContext.h"
#include "h/UIKeyboardTouchInfo.h"
#include "h/UIKeyboardLayout.h"
#include "h/UIKeyboardLayoutStar.h"
#include "h/UIKBTextStyle.h"
#include "h/UIKBRenderTraits.h"
#include "h/UIKBRenderConfig.h"
#include "h/UIKBRenderFactory.h"
#include "h/UIKBRenderFactoryiPhone.h"
#include "h/UIKBKeyView.h"
#include "h/UIKBKeyViewAnimator.h"
#include <dlfcn.h>

#include "Utils.h"
#include <Cephei/HBPreferences.h>

static HBPreferences *preferences;
static NSMutableDictionary *kbPropCache;
static NSString *lightSymbolsColour, *darkSymbolsColour;
static bool hapticFeedbackEnabled = YES;
// -1 means UISelectionFeedbackGenerator, anything else is a UIImpactFeedbackStyle
static NSInteger hapticStyle = -1;
static bool hapticCancelEnabled = NO;
static double symbolFontScale = 0.7;
static double flickBias = 1.0;

static id kbFetchProp(NSString *key) {
	id value = kbPropCache[key];
	if (value == nil) {
		value = [preferences objectForKey:key];
		kbPropCache[key] = value;
	}
	return value;
}



static bool lieAboutGestureKeys = false;
static bool doingDragOnKey = false;
static UIFeedbackGenerator *clickFeedback = nil;
static UINotificationFeedbackGenerator *cancelFeedback = nil;
// true while a flick symbol is selected, so we know there's a flick to cancel
static bool flickArmed = false;

static UIFeedbackGenerator *makeClickFeedback() {
	if (hapticStyle < 0)
		return [UISelectionFeedbackGenerator new];
	return [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyle)hapticStyle];
}

static void playClickFeedback() {
	if ([clickFeedback isKindOfClass:[UIImpactFeedbackGenerator class]])
		[(UIImpactFeedbackGenerator *)clickFeedback impactOccurred];
	else
		[(UISelectionFeedbackGenerator *)clickFeedback selectionChanged];
}

%hook UIKeyboardTouchInfo
%property (nonatomic, assign) bool fpAllow;
%property (nonatomic, retain) UIKBTree *fpFlickKey;
- (id)init {
	self.fpAllow = false;
	return %orig;
}
%end

// Flicks only ever go downwards, so instead of a single radius we check where
// the finger has gone relative to the size of the key it landed on.
// delta is measured from the touch-down point; positive y is downwards.
static bool movementRulesOutFlick(UIKBTree *key, CGPoint delta) {
	CGSize size = key.frame.size;
	double keyWidth = MIN(MAX(size.width, 20.0), 80.0);
	double keyHeight = MIN(MAX(size.height, 30.0), 60.0);
	double sideways = fabs(delta.x), down = delta.y;

	// moving up can never be a flick
	if (down < -0.35 * keyHeight * flickBias)
		return true;

	// a flick doesn't travel much further than a row
	if (down > 1.75 * keyHeight * flickBias)
		return true;

	// flicks stay within a cone below the key (~40 degrees either side);
	// dual keys get a wider one as they're flicked down-left or down-right
	double coneSlope = ([key.secondaryRepresentedStrings count] > 1) ? 1.73 : 0.84;
	if (sideways > 0.5 * keyWidth * flickBias && sideways > coneSlope * flickBias * MAX(down, 0.0))
		return true;

	return false;
}

%hook UIKeyboardLayoutStar
- (void)touchDragged:(UIKBTouchState *)state executionContext:(UIKeyboardTaskExecutionContext *)ctx {
	UIKeyboardTouchInfo *touchInfo = [self infoForTouch:state];

	// are we gonna let this one become a continuous path?
	// once we've said yes, it stays that way for the rest of the touch
	if (!touchInfo.fpAllow && touchInfo.fpFlickKey == nil) {
		// only a touch that lands on a flick key can turn into a flick
		UIKBTree *key = touchInfo.key;
		if (key.displayTypeHint == 10)
			touchInfo.fpFlickKey = key;
		else
			touchInfo.fpAllow = true;
	}

	if (!touchInfo.fpAllow) {
		CGPoint initial = touchInfo.initialPoint;
		CGPoint now = [state respondsToSelector:@selector(locationInView:)] ? [state locationInView:self] : touchInfo.initialDragPoint;
		if (movementRulesOutFlick(touchInfo.fpFlickKey, CGPointMake(now.x - initial.x, now.y - initial.y)))
			touchInfo.fpAllow = true;
	}

	if (touchInfo.fpAllow) {
		// this lets a continuous path happen
		if (flickArmed && cancelFeedback != nil) {
			// a flick symbol was selected, signal that the flick is now off-limits
			[cancelFeedback notificationOccurred:UINotificationFeedbackTypeWarning];
		}
		flickArmed = false;

		// cancel any pending haptic generators
		clickFeedback = nil;
		cancelFeedback = nil;

		lieAboutGestureKeys = true;
		%orig;
		lieAboutGestureKeys = false;
	} else {
		%orig;
	}
}

-(void)updatePanAlternativesForTouchInfo:(UIKeyboardTouchInfo *)touchInfo {
	if (clickFeedback == nil && hapticFeedbackEnabled) {
		// feedback while sliding through variants, at the chosen strength
		clickFeedback = makeClickFeedback();
		[clickFeedback prepare];
	}
	if (cancelFeedback == nil && hapticCancelEnabled) {
		cancelFeedback = [UINotificationFeedbackGenerator new];
		[cancelFeedback prepare];
	}

	doingDragOnKey = true;
	%orig;
	doingDragOnKey = false;
}

- (void)resetPanAlternativesForEndedTouch:(id)touch {
	clickFeedback = nil;
	cancelFeedback = nil;
	flickArmed = false;
}
%end

%hook UIKBTree
- (void)setSelectedVariantIndex:(long long)index {
	if (doingDragOnKey && self.selectedVariantIndex != index) {
		// 0 and 1 are the flick symbols, anything else means none is selected
		flickArmed = (index == 0 || index == 1);

		if (clickFeedback != nil) {
			// tick while sliding through variants
			playClickFeedback();
			[clickFeedback prepare];
		}
	}
	%orig;
}
%end

@implementation UIKBTree (FlickPlus)
- (NSDictionary *)nfpGenerateKeylayoutConfigBasedOffKeylayout:(UIKBTree *)subLayout inKeyplane:(UIKBTree *)keyplane rewriteCapitalToSmall:(BOOL)capsToSmall {
	// context: keylayout (NOT keyplane!)
	if (subLayout == nil) {
		NSLog(@"nfpGenerateKeylayoutConfigBasedOffKeylayout passed null sublayout!");
		return [NSDictionary dictionary];
	}

	// mostly same as pre-0.0.6 versions of the tweak
	NSMutableDictionary *result = [NSMutableDictionary dictionary];

	UIKBTree *thisKeyset = self.keySet, *subKeyset = subLayout.keySet;

	UIKBTree *thisTopRow = thisKeyset.subtrees[0];
	UIKBTree *thisMiddleRow = thisKeyset.subtrees[1];
	UIKBTree *thisBottomRow = thisKeyset.subtrees[2];
	UIKBTree *subTopRow = subKeyset.subtrees[0];
	UIKBTree *subMiddleRow = subKeyset.subtrees[1];
	UIKBTree *subBottomRow = subKeyset.subtrees[2];

	// top row is mapped as-is
	int count = MIN(thisTopRow.subtrees.count, subTopRow.subtrees.count);
	for (int i = 0; i < count; i++) {
		UIKBTree *thisKey = thisTopRow.subtrees[i], *subKey = subTopRow.subtrees[i];
		NSString *cleanName = [thisKey.name stringByReplacingOccurrencesOfString:@"-Small-Display" withString:@""];
		if (capsToSmall) cleanName = [cleanName stringByReplacingOccurrencesOfString:@"-Capital-Letter" withString:@"-Small-Letter"];
		result[cleanName] = @[subKey.representedString, subKey.displayString];
	}

	// middle row is mapped as-is
	count = MIN(thisMiddleRow.subtrees.count, subMiddleRow.subtrees.count);
	for (int i = 0; i < count; i++) {
		UIKBTree *thisKey = thisMiddleRow.subtrees[i], *subKey = subMiddleRow.subtrees[i];
		NSString *cleanName = [thisKey.name stringByReplacingOccurrencesOfString:@"-Small-Display" withString:@""];
		if (capsToSmall) cleanName = [cleanName stringByReplacingOccurrencesOfString:@"-Capital-Letter" withString:@"-Small-Letter"];
		result[cleanName] = @[subKey.representedString, subKey.displayString];
	}

	// bottom row requires a bit more work
	NSMutableArray *bottomKeys = [NSMutableArray array];
	if (thisMiddleRow.subtrees.count == (subMiddleRow.subtrees.count - 1)) {
		// carry the last key over if it's been left behind
		UIKBTree *subKey = subMiddleRow.subtrees.lastObject;
		[bottomKeys addObject:@[subKey.representedString, subKey.displayString]];
	}

	for (UIKBTree *subKey in subBottomRow.subtrees) {
		[bottomKeys addObject:@[subKey.representedString, subKey.displayString]];
	}

	// add the ellipsis because it's cool
	if ([keyplane.name containsString:@"-Letters"] && bottomKeys.count < thisBottomRow.subtrees.count) {
		[bottomKeys insertObject:@[@"…", @"…"] atIndex:2];
	}

	// now shove all those in
	count = MIN(thisBottomRow.subtrees.count, bottomKeys.count);
	for (int i = 0; i < count; i++) {
		UIKBTree *thisKey = thisBottomRow.subtrees[i];
		NSString *cleanName = [thisKey.name stringByReplacingOccurrencesOfString:@"-Small-Display" withString:@""];
		if (capsToSmall) cleanName = [cleanName stringByReplacingOccurrencesOfString:@"-Capital-Letter" withString:@"-Small-Letter"];
		if (![thisKey.representedString isEqualToString:bottomKeys[i][0]])
			result[cleanName] = bottomKeys[i];
	}

	return [NSDictionary dictionaryWithDictionary:result];
}
@end



extern "C" {
NSString *UIKeyboardGetCurrentInputMode();
NSString *UIKeyboardLocalizedString(NSString *key, NSString *language, NSString *unk, NSString *def);
id UIKeyboardLocalizedObject(NSString *key, NSString *language, NSString *unk, id def, BOOL unk2);
};

@interface NSLocale (MissingStuff)
+ (NSLocale *)preferredLocale;
@end

static NSString *currencyFix(NSString *str) {
	// based heavily off the logic in -[UIKeyboardLayoutStar setCurrencyKeysForCurrentLocaleOnKeyplane:]
	NSString *localObjName = nil, *defChar = nil;
	if ([str isEqualToString:@"¤1"]) {
		localObjName = @"UI-PrimaryCurrencySign";
		defChar = @"$";
	} else if ([str isEqualToString:@"¤2"]) {
		localObjName = @"UI-AlternateCurrencySign-1";
		defChar = @"€";
	} else if ([str isEqualToString:@"¤3"]) {
		localObjName = @"UI-AlternateCurrencySign-2";
		defChar = @"@";
	} else if ([str isEqualToString:@"¤4"]) {
		localObjName = @"UI-AlternateCurrencySign-3";
		defChar = @"¥";
	} else if ([str isEqualToString:@"¤5"]) {
		localObjName = @"UI-AlternateCurrencySign-4";
		defChar = @"₩";
	} else {
		return str;
	}

	// could probably optimise things by caching some of these calls...?
	str = UIKeyboardLocalizedObject(localObjName, [[NSLocale preferredLocale] localeIdentifier], 0, 0, NO);
	if (!str)
		str = UIKeyboardLocalizedString(localObjName, UIKeyboardGetCurrentInputMode(), 0, defChar);
	return str;
}

%hook UIKBTree
- (int)displayTypeHint {
	int type = %orig;
	if (lieAboutGestureKeys && type == 10)
		return 0;
	else
		return type;
}

- (void)updateFlickKeycapOnKeys {
	// it's Keyboard Fun Time!
	// we are in a keyplane, we need to know what keyboard we are

	// two cases:
	//    altflag is capsAreSeparate
	//    true  -> two planes, one Capital, one Small
	//    false -> one Small plane, used for both
	//    in which case we need to do special work on Capital plane
	BOOL replaceCapitalBySmall = NO;

	NSString *kbName = [self stringForProperty:@"fp-kb-name"];
	if (kbName == nil)
		return;

	if ([self.name hasSuffix:@"Capital-Letters"]) {
		// we might need to fallback
		NSString *propName = [self stringForProperty:@"fp-kb-altflag"];
		id flag = kbFetchProp(propName);
		if (![flag boolValue]) {
			// user is not using separate caps
			// so, use the Small plane, and pretend every key is Small
			kbName = [self stringForProperty:@"fp-kb-altname"];
			replaceCapitalBySmall = YES;
			if (flag == nil)
				kbPropCache[propName] = @NO;
		}
	}

	NSDictionary *config = kbFetchProp(kbName);
	if (config == nil) {
		NSLog(@"Can't find config %@!! Using a default...", kbName);
		UIKBTree *keylayout = self.subtrees[0];
		UIKBTree *subKeylayout = keylayout.cachedGestureLayout;
		config = [keylayout nfpGenerateKeylayoutConfigBasedOffKeylayout:subKeylayout inKeyplane:self rewriteCapitalToSmall:replaceCapitalBySmall];
		// we store this in the propcache but not to preferences
		kbPropCache[kbName] = config;
	}

	for (UIKBTree *keylayout in self.subtrees) {
		if (keylayout.type != 3)
			continue;

		UIKBTree *keySet = [keylayout keySet];

		for (UIKBTree *list in keySet.subtrees) {
			for (UIKBTree *key in list.subtrees) {
				if (key.displayType == 0 || key.displayType == 8) {
					NSString *checkName = [key.name stringByReplacingOccurrencesOfString:@"-Small-Display" withString:@""];
					if (replaceCapitalBySmall)
						checkName = [checkName stringByReplacingOccurrencesOfString:@"-Capital" withString:@"-Small"];

					NSArray *cfgKey = config[checkName];
					if (cfgKey == nil) {
						if (key.displayTypeHint == 10) {
							// clear existing gesture keys just in case
							key.displayTypeHint = 0;
						}
					} else if (cfgKey.count == 2) {
						// text key
						key.displayTypeHint = 10;
						NSString *rep = cfgKey[0], *disp = cfgKey[1];
						if ([rep hasPrefix:@"¤"]) rep = currencyFix(rep);
						if ([disp hasPrefix:@"¤"]) disp = currencyFix(disp);
						key.secondaryRepresentedStrings = @[rep];
						key.secondaryDisplayStrings = @[
							(disp && disp.length) ? disp : rep
						];
					} else if (cfgKey.count == 4) {
						// dual key
						key.displayTypeHint = 10;
						NSString *repA = cfgKey[0], *dispA = cfgKey[1];
						NSString *repB = cfgKey[2], *dispB = cfgKey[3];
						if ([repA hasPrefix:@"¤"]) repA = currencyFix(repA);
						if ([repB hasPrefix:@"¤"]) repB = currencyFix(repB);
						if ([dispA hasPrefix:@"¤"]) dispA = currencyFix(dispA);
						if ([dispB hasPrefix:@"¤"]) dispB = currencyFix(dispB);
						key.secondaryRepresentedStrings = @[repA, repB];
						key.secondaryDisplayStrings = @[
							(dispA && dispA.length) ? dispA : repA,
							(dispB && dispB.length) ? dispB : repB
						];
					}
				}
			}
		}
	}
}
%end

%hook TUIKBGraphSerialization

- (UIKBTree *)keyboardForName:(NSString *)name {
	// TODO: do not patch the same keyboard multiple times!
	UIKBTree *tree = %orig;

	NSString *cleanName = name;

	// for now, we exclude certain ones...
	if ([cleanName hasSuffix:@"-URL"]) return tree;
	if ([cleanName hasSuffix:@"-NumberPad"]) return tree;
	if ([cleanName hasSuffix:@"-PhonePad"]) return tree;
	if ([cleanName hasSuffix:@"-NamePhonePad"]) return tree;
	if ([cleanName hasSuffix:@"-Email"]) return tree;
	if ([cleanName hasSuffix:@"-DecimalPad"]) return tree;
	if ([cleanName hasSuffix:@"-AlphaWithURL"]) return tree;
	if ([cleanName containsString:@"Emoji"]) return tree;

	// Twitter keyboard just uses standard stuff
	if ([cleanName hasSuffix:@"-Twitter"])
		cleanName = [cleanName substringToIndex:(cleanName.length - 8)];

	// take out iPhone-{variant}-
	if ([cleanName hasPrefix:@"iPhone-"]) {
		NSRange searchRange = NSMakeRange(7, cleanName.length - 7);
		NSUInteger secondHyphen = [cleanName rangeOfString:@"-" options:0 range:searchRange].location;
		if (secondHyphen != NSNotFound)
			cleanName = [cleanName substringFromIndex:secondHyphen + 1];
	}

	for (UIKBTree *keyplane in tree.subtrees) {
		NSString *cleanPlaneName = [keyplane.name sliceAfterLastUnderscore];
		cleanPlaneName = [cleanPlaneName stringByReplacingOccurrencesOfString:@"-Small-Display" withString:@""];

		NSString *mainName = [NSString stringWithFormat:@"kb-%@--%@--flicks", cleanName, cleanPlaneName];
		[keyplane setObject:mainName forProperty:@"fp-kb-name"];
		if ([cleanPlaneName isEqualToString:@"Capital-Letters"]) {
			NSString *flagName = [NSString stringWithFormat:@"kb-%@-capsAreSeparate", cleanName];
			[keyplane setObject:flagName forProperty:@"fp-kb-altflag"];
			NSString *altName = [NSString stringWithFormat:@"kb-%@--Small-Letters--flicks", cleanName];
			[keyplane setObject:altName forProperty:@"fp-kb-altname"];
		}

		// this is necessary so that cachedGestureLayout will be set
		// which we need when calling nfpGenerateKeylayoutConfigBasedOffKeylayout
		// to generate a default config
		if ([cleanPlaneName hasSuffix:@"Letters"])
			[keyplane setObject:[keyplane alternateKeyplaneName] forProperty:@"gesture-keyplane"];
		else if ([cleanPlaneName isEqualToString:@"Numbers-And-Punctuation"])
			[keyplane setObject:[keyplane shiftAlternateKeyplaneName] forProperty:@"gesture-keyplane"];
	}

	return tree;
}

%end

%hook TIPreferencesController
- (bool)boolForPreferenceKey:(NSString *)key {
	if ([key isEqualToString:@"GesturesEnabled"]) {
		return YES;
	} else {
		return %orig;
	}
}
%end

%group SpringBoard
%hook SpringBoard
// clear the KB cache on respring
- (void)applicationDidFinishLaunching:(id)application {
	[[%c(UIKeyboardCache) sharedInstance] purge];
	%orig;
}
%end
%end


// recolour the symbols
%hook UIKBRenderFactoryiPhone
- (UIKBRenderTraits *)_traitsForKey:(UIKBTree *)key onKeyplane:(UIKBTree *)plane {
	UIKBRenderTraits *traits = %orig;

	NSArray *styles = traits.secondarySymbolStyles;
	if (styles != nil) {
		NSString *which = self.renderConfig.lightKeyboard ? lightSymbolsColour : darkSymbolsColour;

		for (UIKBTextStyle *style in styles) {
			style.textColor = which;
			style.textOpacity = 1.0;
			style.fontSize *= symbolFontScale;
		}

		// force the blurred background to be applied to light KB
		// stops the label from showing through and making things weird
		if (!self.allowsPaddles)
			traits.blurBlending = YES;
	}

	return traits;
}
%end

// make animations less of a disaster
// TODO: might want to check the keyboard's interface idiom
// in case people decide to run this on an iPad
static bool inAnimHack = false;

@interface CALayer (FlickPlusPrivate)
@property(copy) id meshTransform;
@end

// Apple's keycap meshes are laid out for iPad glyph positions. On iPhone they
// shear and squash the glyphs (a pressed "h" turns into "ń", the flick
// preview warps), and no single set of rects suits every key, font and
// orientation. So while hacking we drop keycap meshes entirely and the flick
// becomes a plain opacity crossfade between the letter and the symbol.
static void stripKeyMeshes(UIKBKeyView *keyView) {
	NSMutableArray<CALayer *> *pending = [NSMutableArray arrayWithObject:keyView.layer];
	while (pending.count) {
		CALayer *layer = pending.lastObject;
		[pending removeLastObject];
		if ([layer respondsToSelector:@selector(meshTransform)])
			layer.meshTransform = nil;
		if (layer.sublayers)
			[pending addObjectsFromArray:layer.sublayers];
	}
}

%hook UIKBKeyViewAnimator
- (void)transitionKeyView:(UIKBKeyView *)keyView fromState:(int)from toState:(int)to completion:(void *)c {
	inAnimHack = true;
	%orig;
	// this is where the pressed state gets its static keycap meshes
	stripKeyMeshes(keyView);

	// force the symbol opacity to zero
	// we can't change a double constant with a simple hook, alas
	UIKBTree *key = keyView.key;
	if (to == 4 && key.displayType != 7 && key.displayTypeHint == 10) {
		CALayer *symbolLayer = [keyView layerForRenderFlags:16];
		if (symbolLayer)
			symbolLayer.opacity = 0;
	}
	inAnimHack = false;
}
- (void)updateTransitionForKeyView:(UIKBKeyView *)keyView normalizedDragSize:(CGSize)size {
	inAnimHack = true;
	%orig;
	stripKeyMeshes(keyView);
	inAnimHack = false;
}
- (void)endTransitionForKeyView:(UIKBKeyView *)keyView {
	inAnimHack = true;
	%orig;
	stripKeyMeshes(keyView);
	inAnimHack = false;
}
+ (id)normalizedAnimationWithKeyPath:(NSString *)path fromValue:(id)from toValue:(id)to {
	if (inAnimHack && [path isEqualToString:@"meshTransform"]) {
		// keep the animation (UIKit looks it up by key later) but make it a no-op
		return %orig(path, nil, nil);
	}
	// we want to force symbol opacity to 0...
	if (inAnimHack && [path isEqualToString:@"opacity"]) {
		// awful kludge alert!!
		double v = [from doubleValue];
		if (v >= 0.2 && v <= 0.35) {
			return %orig(path, @0, to);
		}
	}
	return %orig;
}
+ (id)normalizedUnwindAnimationWithKeyPath:(NSString *)path fromValue:(id)from toValue:(id)to offset:(double)offset {
	if (inAnimHack && [path isEqualToString:@"meshTransform"])
		return %orig(path, nil, nil, offset);
	return %orig;
}
+ (id)normalizedUnwindAnimationWithKeyPath:(NSString *)path originallyFromValue:(id)from toValue:(id)to offset:(double)offset {
	if (inAnimHack && [path isEqualToString:@"meshTransform"])
		return %orig(path, nil, nil, offset);
	return %orig;
}
+ (id)normalizedUnwindOpacityAnimationWithKeyPath:(NSString *)path originallyFromValue:(id)from toValue:(id)to offset:(double)offset {
	// it's a great day in UIKit, and you are a horrible goose
	if (inAnimHack && [path isEqualToString:@"opacity"]) {
		// awful kludge alert!! (part 2)
		double v = [from doubleValue];
		if (v >= 0.2 && v <= 0.35) {
			return %orig(path, @0, to, offset);
		}
	}
	return %orig;
}
%end




static NSString *resolveColour(NSString *name) {
	if ([name isEqualToString:@"white"]) {
		return @"UIKBColorWhite";
	} else if ([name isEqualToString:@"lgrey"]) {
		return @"UIKBColorGray_Percent68";
	} else if ([name isEqualToString:@"dgrey"]) {
		return @"UIKBColorGray_Percent31_37";
	} else if ([name isEqualToString:@"black"]) {
		return @"UIKBColorBlack";
	} else {
		return @"UIKBColorRed";
	}
}

// "Flick Sensitivity" in the prefs, still stored under the old "flickRadius"
// key so existing choices carry over. it scales every threshold in
// movementRulesOutFlick (lower = more eager to start a swipe)
static double resolveFlickBias(NSString *name) {
	if ([name isEqualToString:@"vshort"]) {
		return 0.55;
	} else if ([name isEqualToString:@"short"]) {
		return 0.7;
	} else if ([name isEqualToString:@"long"]) {
		return 1.3;
	} else if ([name isEqualToString:@"wide"]) {
		return 1.6;
	} else {
		return 1.0;
	}
}

static double resolveSymbolScale(NSString *name) {
	if ([name isEqualToString:@"small"]) {
		return 0.55;
	} else if ([name isEqualToString:@"large"]) {
		return 0.85;
	} else {
		return 0.7;
	}
}

static NSInteger resolveHapticStyle(NSString *name) {
	if ([name isEqualToString:@"soft"]) {
		return UIImpactFeedbackStyleSoft;
	} else if ([name isEqualToString:@"light"]) {
		return UIImpactFeedbackStyleLight;
	} else if ([name isEqualToString:@"medium"]) {
		return UIImpactFeedbackStyleMedium;
	} else if ([name isEqualToString:@"heavy"]) {
		return UIImpactFeedbackStyleHeavy;
	} else {
		return -1;
	}
}

static void syncPreferences() {
	lightSymbolsColour = resolveColour([preferences objectForKey:@"lightSymbols"]);
	darkSymbolsColour = resolveColour([preferences objectForKey:@"darkSymbols"]);
	hapticFeedbackEnabled = [preferences boolForKey:@"hapticFeedback"];
	hapticStyle = resolveHapticStyle([preferences objectForKey:@"hapticStrength"]);
	hapticCancelEnabled = [preferences boolForKey:@"hapticCancelFeedback"];
	symbolFontScale = resolveSymbolScale([preferences objectForKey:@"symbolSize"]);
	flickBias = resolveFlickBias([preferences objectForKey:@"flickRadius"]);
	[kbPropCache removeAllObjects];
	[[%c(UIKeyboardCache) sharedInstance] purge];
	// maybe also [UIKBRenderer clearInternalCaches] ??
}


%ctor {
	kbPropCache = [NSMutableDictionary dictionary];

	preferences = [[HBPreferences alloc] initWithIdentifier:@"org.wuffs.flickplus"];
	[preferences registerDefaults:@{
		@"lightSymbols": @"lgrey",
		@"darkSymbols": @"lgrey",
		@"hapticFeedback": @YES,
		@"hapticStrength": @"selection",
		@"hapticCancelFeedback": @NO,
		@"symbolSize": @"medium"
	}];
	[preferences registerPreferenceChangeBlock:^{
		syncPreferences();
	}];

	// trick thanks to poomsmart
	// https://github.com/PoomSmart/EmojiPort-Legacy/blob/8573de11226ac2e1c4108c044078109dbfb07a02/KBResizeLegacy.xm
	dlopen("/System/Library/PrivateFrameworks/TextInputUI.framework/TextInputUI", RTLD_LAZY);

	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
	if ([bundleID isEqualToString:@"com.apple.springboard"]) {
		%init(SpringBoard);
	}

	%init;
}
