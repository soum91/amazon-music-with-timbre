#import <UIKit/UIKit.h>
#ifdef __cplusplus
extern "C" {
#endif
UIViewController *TBCreateEmbeddedController(void);
UIViewController *TBEmbeddedDiagnosticsController(void);
NSDictionary *TBEmbeddedInitialConfig(void);
void TBEmbeddedApplyConfig(NSDictionary *config);
NSDictionary *TBEmbeddedStatus(void);
// Next head-tracking reading becomes straight ahead.
void TBEmbeddedRecenterHead(void);
// Widget endpoint helpers. Main queue only.
NSDictionary *TBEmbeddedWidgetSnapshot(void);
BOOL TBEmbeddedWidgetCommand(NSString *command);
#ifdef __cplusplus
}
#endif
