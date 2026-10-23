#import <UIKit/UIKit.h>

/* Snapshots the game's save data into the app's own Documents/save-backups (see save_backup.m). No UI is ever shown:
   the Settings pane's TOTK_BACKUP switch decides, and a fresh install with an empty save folder restores silently. */
@interface TOTKSaveBackup : NSObject

+ (BOOL)enabled;
/* Restores the newest snapshot when the game has no save yet, then calls ready once; always before the game thread. */
+ (void)prepareWithCompletion:(void (^)(void))ready;
/* Copies the current save into a new snapshot, prunes the old ones; asynchronous, safe on app background. */
+ (void)snapshot;

@end
