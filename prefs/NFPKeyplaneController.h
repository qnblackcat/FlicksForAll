#import <Preferences/PSListController.h>
#import "../h/UIKBTree.h"
@class NFPKeyPropsController;

@interface NFPKeyplaneController : PSListController
{
	UIKBTree *_keyboard, *_keyplane;
	NSString *_prefKey;
	NSMutableDictionary *_configData;
}
- (void)saveKeyInfoBackFrom:(NFPKeyPropsController *)kpc;
@end


