#import <UIKit/UIKit.h>
#ifdef __cplusplus
extern "C" {
#endif
UIViewController *TBCreateEmbeddedController(void);
UIViewController *TBEmbeddedDiagnosticsController(void);
NSDictionary *TBEmbeddedInitialConfig(void);
void TBEmbeddedApplyConfig(NSDictionary *config);
NSDictionary *TBEmbeddedStatus(void);
#ifdef __cplusplus
}
#endif
