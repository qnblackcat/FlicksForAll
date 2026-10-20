#include "NFPShiftDeleteController.h"

@implementation NFPShiftDeleteController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"ShiftDelete" target:self];
	}
	return _specifiers;
}

@end
