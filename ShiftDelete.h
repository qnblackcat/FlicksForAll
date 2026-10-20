#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// installs the hooks; skips processes that have no use for them
void NFPShiftDeleteInit(void);
// picks up the shiftDeleteShiftHold / shiftDeleteShiftLock switches
void NFPShiftDeleteSync(NSDictionary *prefs);

#ifdef __cplusplus
}
#endif
