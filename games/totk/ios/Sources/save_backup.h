#import <UIKit/UIKit.h>

/* iCloud Drive / Files backup of Documents/save and Documents/game-slot (see save_backup.m). */
@interface TOTKSaveBackup : NSObject

+ (BOOL)enabled;
/* Resolves (or asks for) the backup folder, restores a fresh install, then calls ready once — and starts the game. */
+ (void)prepareFrom:(UIViewController *)host completion:(void (^)(void))ready;
+ (void)sync;

@end
