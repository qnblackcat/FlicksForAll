#import "NFPListController.h"
#import "../h/UIKeyboardInputMode.h"
#import "../h/UIKBTree.h"
#import "../h/TUIKeyboardLayoutFactory.h"

@interface NFPKeyboardController : NFPListController
{
	UIKBTree *_keyboard;

	UIKBTree *_smallLettersKeyplane, *_capitalLettersKeyplane;
	PSSpecifier *_separateSpecifier;
	PSSpecifier *_capitalLettersKeyplaneSpecifier;
}
@end

