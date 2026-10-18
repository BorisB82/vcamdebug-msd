// Minimal declaration of the private ControlCenterUIKit toggle-module base. We don't link
// ControlCenterUIKit — the superclass symbol is resolved at load time (-undefined dynamic_lookup)
// inside SpringBoard, where the framework is already loaded. This header just lets our subclass
// compile and override the toggle hooks.

#import <UIKit/UIKit.h>

@interface CCUIToggleModule : NSObject
- (void)refreshState;             // ask Control Center to re-query the toggle's appearance
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (UIColor *)selectedColor;
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
@end
