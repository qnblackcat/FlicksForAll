#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "ShiftDelete.h"

@interface UIKBTree : NSObject
- (NSString *)name;
@end

@interface UIKBKeyView : UIView
@property (nonatomic, readonly) UIKBTree *key;
- (UIImage *)_generateBackdropMaskImage;
@end

@interface TIKeyboardInput : NSObject
@property (nonatomic, copy) NSString *string;
@property (getter=isBackspace, nonatomic) BOOL backspace;
@end

@interface TIDocumentState : NSObject
- (TIDocumentState *)documentStateAfterReplacingText:(NSString *)text withText:(NSString *)replacement;
@end

@interface TIKeyboardState : NSObject
@property (nonatomic, retain) TIDocumentState *documentState;
@end

@interface UIKeyboardImpl : UIView
+ (instancetype)sharedInstance;
@property (nonatomic, readonly) TIKeyboardState *keyboardState;
- (UIResponder<UITextInput> *)delegateAsResponder;
- (BOOL)isShiftLocked;
- (BOOL)callLayoutIsShiftKeyBeingHeld;
- (void)stopAutoDelete;
@end

@interface UIKeyboardLayoutStar : UIView
- (UIKBTree *)keyHitTest:(CGPoint)point;
@end

@interface WKContentView : UIView
- (void)selectWordBackward;
- (NSString *)selectedText;
- (void)deleteBackward;
@end

typedef NS_ENUM(NSInteger, SDMode) {
	SDModeNone = 0,
	SDModeShiftHold = 1,
	SDModeShiftLock = 2,
	SDModeKanaKey = 4, // left-side keys of the Japanese flick keyboard act like Shift
};

static bool shiftHoldEnabled = NO;
static bool shiftLockEnabled = NO;

static UIColor *shiftHoldColor;
static UIColor *shiftLockColor;

static BOOL sdHidden = YES; // YES = not in delete-cut mode
static UIColor *sdColor;
static SDMode sdMode = SDModeNone;
static NSHashTable<CALayer *> *sdLayers;
static char kSDLayerKey;

// nil when the mode is switched off, so it never turns on
static UIColor *SDColorForMode(bool enabled, UIColor *color) {
	return enabled ? color : nil;
}

static void SDSetMode(BOOL hide, UIColor *color, SDMode mode) {
	sdHidden = hide || color == nil;
	sdColor = color;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for (CALayer *layer in sdLayers) {
		layer.backgroundColor = color.CGColor;
		layer.hidden = sdHidden;
	}
	[CATransaction commit];
	sdMode = sdHidden ? SDModeNone : mode;
}

@interface UITouch (ShiftDelete)
@property (nonatomic, assign, getter=isStartedFromShiftKeySD) BOOL startedFromShiftKeySD;
@end

@implementation UITouch (ShiftDelete)
- (void)setStartedFromShiftKeySD:(BOOL)value {
	objc_setAssociatedObject(self, @selector(isStartedFromShiftKeySD), @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)isStartedFromShiftKeySD {
	return [objc_getAssociatedObject(self, @selector(isStartedFromShiftKeySD)) boolValue];
}
@end

static UIKeyboardImpl *SDImpl(void) {
	return [%c(UIKeyboardImpl) sharedInstance];
}

static BOOL SDIsWebContent(id responder) {
	Class cls = objc_getClass("WKContentView");
	return cls && [responder isKindOfClass:cls];
}

// keep the keyboard's document state (autocorrect / predictions) in sync
// after removing text ourselves
static void SDSyncDocumentState(NSString *deletedText) {
	if (deletedText.length == 0) return;
	TIKeyboardState *state = SDImpl().keyboardState;
	TIDocumentState *documentState = state.documentState;
	if (documentState)
		state.documentState = [documentState documentStateAfterReplacingText:deletedText withText:@""];
}

static UITextRange *SDWordBeforeCaret(id<UITextInput> input) {
	UITextPosition *start = input.selectedTextRange.start;
	if (!start || [input comparePosition:input.beginningOfDocument toPosition:start] == NSOrderedSame)
		return nil;

	id<UITextInputTokenizer> tokenizer = input.tokenizer;
	UITextPosition *end = [tokenizer positionFromPosition:start toBoundary:UITextGranularityWord inDirection:(UITextDirection)UITextStorageDirectionBackward];
	if (!end)
		end = [tokenizer positionFromPosition:start toBoundary:UITextGranularityWord inDirection:(UITextDirection)UITextLayoutDirectionLeft];
	if (!end)
		return nil;

	UITextRange *range = [input textRangeFromPosition:start toPosition:end];
	// a lone space between the caret and the word boundary: take the word before it too
	if ([[input textInRange:range] isEqualToString:@" "]) {
		UITextPosition *further = [tokenizer positionFromPosition:end toBoundary:UITextGranularityWord inDirection:(UITextDirection)UITextStorageDirectionBackward];
		if (further) {
			end = further;
			range = [input textRangeFromPosition:start toPosition:end];
		}
	}
	if ([input comparePosition:start toPosition:end] == NSOrderedDescending)
		range = [input textRangeFromPosition:end toPosition:start];
	return range;
}

static void SDDeleteBackwardWord(void) {
	id responder = [SDImpl() delegateAsResponder];
	if (SDIsWebContent(responder)) {
		// select with WebKit, then delete the selection
		WKContentView *view = responder;
		[view selectWordBackward];
		SDSyncDocumentState([view selectedText]);
		[view deleteBackward];
		return;
	}

	id<UITextInput> input = responder;
	UITextRange *range = SDWordBeforeCaret(input);
	if (!range || range.isEmpty)
		return;
	NSString *text = [input textInRange:range];
	[input replaceRange:range withText:@""];
	SDSyncDocumentState(text);
}

static void SDCancelSwipeSelection(void) {
	Class panClass = objc_getClass("SSPanGestureRecognizer");
	if (!panClass) return;
	for (UIGestureRecognizer *recognizer in SDImpl().gestureRecognizers) {
		if ([recognizer isMemberOfClass:panClass])
			recognizer.state = UIGestureRecognizerStateCancelled;
	}
}

%group ShiftDelete

%hook UIKBKeyView
- (void)layoutSubviews {
	%orig;
	if (![[self.key name] hasPrefix:@"Delete"]) return;

	CALayer *layer = objc_getAssociatedObject(self, &kSDLayerKey);
	if (!layer) {
		layer = [CALayer layer];
		layer.name = @"ShiftDelete";
		objc_setAssociatedObject(self, &kSDLayerKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[sdLayers addObject:layer];
	}

	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	layer.frame = self.bounds;
	layer.backgroundColor = sdColor.CGColor;
	layer.hidden = sdHidden;

	// put the colour under the key's symbol layer, like the original did
	// on iOS 13/14 (_keyLayers[@6])
	NSDictionary *keyLayers = nil;
	Ivar ivar = class_getInstanceVariable(object_getClass(self), "_keyLayers");
	if (ivar) keyLayers = object_getIvar(self, ivar);
	CALayer *symbolLayer = [keyLayers isKindOfClass:[NSDictionary class]] ? keyLayers[@6] : nil;
	if (symbolLayer && symbolLayer.superlayer == self.layer) {
		if (layer.superlayer != self.layer || [self.layer.sublayers indexOfObject:layer] > [self.layer.sublayers indexOfObject:symbolLayer])
			[self.layer insertSublayer:layer below:symbolLayer];
		layer.opacity = 1.0;
	} else if (layer.superlayer != self.layer) {
		// fallback: overlay on top, translucent so the ⌫ glyph stays visible
		[self.layer addSublayer:layer];
		layer.opacity = 0.6;
	}

	CALayer *mask = [CALayer layer];
	mask.frame = layer.bounds;
	mask.contents = (__bridge id)[self _generateBackdropMaskImage].CGImage;
	layer.mask = mask;
	[CATransaction commit];
}
%end

%hook UIKeyboardImpl
- (void)callLayoutSetShift:(BOOL)shift {
	%orig;
	if (shift && [self isShiftLocked])
		SDSetMode(NO, SDColorForMode(shiftLockEnabled, shiftLockColor), SDModeShiftLock);
}

- (void)finishSetInputMode:(id)mode didChangeDirection:(BOOL)changed {
	%orig;
	SDSetMode(YES, nil, SDModeNone);
}

- (void)finishSetKeyboardInputMode:(id)mode previousInputMode:(id)previous didChangeDirection:(BOOL)changed {
	%orig;
	SDSetMode(YES, nil, SDModeNone);
}

- (void)handleKeyboardInput:(TIKeyboardInput *)input executionContext:(id)context {
	if (sdHidden || ![input isBackspace]) {
		%orig;
		return;
	}
	UIResponder<UITextInput> *responder = [self delegateAsResponder];
	UITextRange *selection = [responder respondsToSelector:@selector(selectedTextRange)] ? responder.selectedTextRange : nil;
	if (!selection.isEmpty) {
		// no caret (or a real selection): let the normal delete run
		%orig;
		return;
	}

	bool shiftLocked = [self isShiftLocked];
	bool deleteWord = shiftLocked
		? shiftLockEnabled
		: ([self callLayoutIsShiftKeyBeingHeld] || sdMode == SDModeKanaKey) && shiftHoldEnabled;
	if (!deleteWord) {
		// the mode that's actually active is switched off
		%orig;
		return;
	}
	SDDeleteBackwardWord();

	// turn the backspace into a no-op but still call through so the
	// execution context returns to its parent
	input.string = nil;
	input.backspace = NO;
	%orig;
	[self stopAutoDelete];
}
%end

%hook UIKeyboardLayoutStar
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	%orig;
	if (!sdHidden) SDCancelSwipeSelection();

	UITouch *touch = touches.anyObject;
	NSString *name = [[self keyHitTest:[touch locationInView:self]] name];
	BOOL fromShift = NO;
	if ([name isEqualToString:@"Shift-Key"] || [name isEqualToString:@"1_Shift-Key"]) {
		SDSetMode(NO, SDColorForMode(shiftHoldEnabled, shiftHoldColor), SDModeShiftHold);
		fromShift = YES;
	} else if ([name isEqualToString:@"FiftyOn-Kana-Keyplane-Switch-Key"]
	        || [name isEqualToString:@"TenKey-Alphabet-Keyplane-Switch-Key"]
	        || [name isEqualToString:@"FiftyOn-SymbolNumber-Keyplane-Switch-Key"]) {
		SDSetMode(NO, SDColorForMode(shiftHoldEnabled, shiftHoldColor), SDModeKanaKey);
		fromShift = YES;
	}
	touch.startedFromShiftKeySD = fromShift;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	%orig;
	if (touches.anyObject.isStartedFromShiftKeySD)
		SDSetMode(YES, nil, SDModeNone);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	%orig;
	SDSetMode(YES, nil, SDModeNone);
}
%end

%end

void NFPShiftDeleteSync(NSDictionary *prefs) {
	shiftHoldEnabled = [prefs[@"shiftDeleteShiftHold"] boolValue];
	shiftLockEnabled = [prefs[@"shiftDeleteShiftLock"] boolValue];
	// switching a mode off while it's showing should clear the tint
	if ((sdMode == SDModeShiftLock && !shiftLockEnabled)
	    || ((sdMode == SDModeShiftHold || sdMode == SDModeKanaKey) && !shiftHoldEnabled))
		SDSetMode(YES, nil, SDModeNone);
}

void NFPShiftDeleteInit(void) {
	// only SpringBoard and apps, like the original
	NSString *path = [[NSProcessInfo processInfo] arguments].firstObject;
	if (path.length == 0) return;

	NSString *name = path.lastPathComponent;
	BOOL isSpringBoard = [name isEqualToString:@"SpringBoard"];
	BOOL isApp = [path rangeOfString:@"/Application/"].location != NSNotFound
	          || [path rangeOfString:@"/Applications/"].location != NSNotFound;
	if (!isSpringBoard && !isApp) return;
	if ([path rangeOfString:@".appex/"].location != NSNotFound) return;
	if ([name.lowercaseString rangeOfString:@"fileprovider"].location != NSNotFound) return;
	if ([@[ @"AdSheet", @"CoreAuthUI", @"InCallService", @"MessagesNotificationViewService" ] containsObject:name]) return;

	sdLayers = [NSHashTable weakObjectsHashTable];
	shiftHoldColor = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
	shiftLockColor = [UIColor colorWithRed:1.0 green:149 / 255.0 blue:0.0 alpha:1.0];
	%init(ShiftDelete);
}
