// SPDX-License-Identifier: GPL-2.0-or-later
#include "window-animation.h"

#include <gtk/gtk.h>

#ifdef GDK_WINDOWING_MACOS
#import <AppKit/AppKit.h>
#include <gdk/macos/gdkmacos.h>
#import <objc/runtime.h>

// NSWindow's synchronous zoom animation runs a private AppKit event loop in
// which GTK cannot lay out or paint. A nonblocking NSViewAnimation returns to
// the ordinary GTK loop between frames. Only document windows opt in, through
// the public NSWindowDelegate API; GTK and its native window class stay intact.
@interface InkscapeWindowAnimationDelegate : NSObject <NSWindowDelegate, NSAnimationDelegate>
@property(nonatomic, weak) id<NSWindowDelegate> original;
- (void)setGtkWindow:(GtkWindow *)window;
- (void)stop;
@end

@implementation InkscapeWindowAnimationDelegate {
    NSViewAnimation *_animation;
    NSRect _restoreFrame;
    NSRect _zoomFrame;
    BOOL _haveRestoreFrame;
    BOOL _zooming;
    GWeakRef _gtkWindow;
}

- (instancetype)init {
    self = [super init];
    if (self)
        g_weak_ref_init(&_gtkWindow, nullptr);
    return self;
}

- (void)setGtkWindow:(GtkWindow *)window {
    g_weak_ref_set(&_gtkWindow, window);
}

- (void)dealloc {
    g_weak_ref_clear(&_gtkWindow);
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.original respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return self.original;
}

- (void)stop {
    auto animation = _animation;
    _animation = nil;
    animation.delegate = nil;
    [animation stopAnimation];
    NSWindow *native = animation.viewAnimations.firstObject[NSViewAnimationTargetKey];
    if (native)
        [self syncSize:native.frame];
}

- (void)syncSize:(NSRect)frame {
    // GTK can have a layout request for the penultimate animation frame queued
    // when AppKit reaches the endpoint. Give GTK that endpoint too, otherwise
    // a late request can enlarge the restored window by a few pixels each time.
    auto window = GTK_WINDOW(g_weak_ref_get(&_gtkWindow));
    if (!window)
        return;
    auto surface = gtk_native_get_surface(GTK_NATIVE(window));
    if (surface && GDK_IS_MACOS_SURFACE(surface)) {
        auto native = (__bridge NSWindow *)gdk_macos_surface_get_native_window(GDK_MACOS_SURFACE(surface));
        auto content = [native contentRectForFrameRect:frame];
        gtk_window_set_default_size(window, content.size.width, content.size.height);
    }
    g_object_unref(window);
}

- (BOOL)windowShouldZoom:(NSWindow *)window toFrame:(NSRect)proposed {
    auto original = self.original;
    if ([original respondsToSelector:_cmd] && ![original windowShouldZoom:window toFrame:proposed]) {
        return NO;
    }
    if (!window.visible || (window.styleMask & NSWindowStyleMaskFullScreen)) {
        return YES;
    }

    NSRect target = proposed;
    if (_animation) {
        // AppKit can overwrite its saved user frame on a second zoom while the
        // first animation is in flight. Retain the real pre-zoom frame and let
        // a repeated command reverse direction without losing that geometry.
        _zooming = !_zooming;
        target = _zooming ? _zoomFrame : _restoreFrame;
        [self stop];
    } else if (window.zoomed) {
        _zooming = NO;
        _zoomFrame = window.frame;
        if (_haveRestoreFrame) {
            target = _restoreFrame;
        } else {
            // A window may already be maximized when first shown/restored.
            _restoreFrame = proposed;
            _haveRestoreFrame = YES;
        }
    } else {
        _restoreFrame = window.frame;
        _haveRestoreFrame = YES;
        _zooming = YES;
        _zoomFrame = proposed;
    }

    auto duration = [window animationResizeTime:target];
    if (duration <= 0 || NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion ||
        NSEqualRects(window.frame, target)) {
        [window setFrame:target display:YES];
        [self syncSize:target];
    } else {
        _animation =
            [[NSViewAnimation alloc] initWithViewAnimations:@[ @{
                                         NSViewAnimationTargetKey : window,
                                         NSViewAnimationStartFrameKey : [NSValue valueWithRect:window.frame],
                                         NSViewAnimationEndFrameKey : [NSValue valueWithRect:target]
                                     } ]];
        _animation.duration = duration;
        _animation.frameRate = 60;
        _animation.animationBlockingMode = NSAnimationNonblocking;
        _animation.delegate = self;
        [_animation startAnimation];
    }
    return NO; // The frame change above replaces only the blocking animation.
}

- (void)animationDidEnd:(NSAnimation *)animation {
    if (animation == _animation) {
        [self syncSize:(_zooming ? _zoomFrame : _restoreFrame)];
        _animation = nil;
    }
}

- (void)animationDidStop:(NSAnimation *)animation {
    if (animation == _animation)
        _animation = nil;
}

- (void)windowWillStartLiveResize:(NSNotification *)notification {
    [self stop];
    _haveRestoreFrame = NO;
    if ([self.original respondsToSelector:_cmd])
        [self.original windowWillStartLiveResize:notification];
}

- (void)windowWillMove:(NSNotification *)notification {
    [self stop];
    _haveRestoreFrame = NO;
    if ([self.original respondsToSelector:_cmd])
        [self.original windowWillMove:notification];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    [self stop];
    _haveRestoreFrame = NO;
    if ([self.original respondsToSelector:_cmd])
        [self.original windowWillEnterFullScreen:notification];
}

- (void)windowWillMiniaturize:(NSNotification *)notification {
    [self stop];
    if ([self.original respondsToSelector:_cmd])
        [self.original windowWillMiniaturize:notification];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self stop];
    if ([self.original respondsToSelector:_cmd])
        [self.original windowWillClose:notification];
}
@end

namespace Inkscape::UI::MacOS {
namespace {
char delegate_key;

NSWindow *native_window(GtkWindow *window) {
    auto surface = gtk_native_get_surface(GTK_NATIVE(window));
    if (!surface || !GDK_IS_MACOS_SURFACE(surface))
        return nil;
    return (__bridge NSWindow *)gdk_macos_surface_get_native_window(GDK_MACOS_SURFACE(surface));
}
} // namespace

void enable_window_animation(GtkWindow *window) {
    auto native = native_window(window);
    if (!native || objc_getAssociatedObject(native, &delegate_key))
        return;
    auto delegate = [[InkscapeWindowAnimationDelegate alloc] init];
    [delegate setGtkWindow:window];
    delegate.original = native.delegate;
    objc_setAssociatedObject(native, &delegate_key, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    native.delegate = delegate;
}

void disable_window_animation(GtkWindow *window) {
    auto native = native_window(window);
    if (!native)
        return;
    InkscapeWindowAnimationDelegate *delegate = objc_getAssociatedObject(native, &delegate_key);
    if (!delegate)
        return;
    [delegate stop];
    if (native.delegate == delegate)
        native.delegate = delegate.original;
    objc_setAssociatedObject(native, &delegate_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
} // namespace Inkscape::UI::MacOS
#else
namespace Inkscape::UI::MacOS {
void enable_window_animation(GtkWindow *) {}
void disable_window_animation(GtkWindow *) {}
} // namespace Inkscape::UI::MacOS
#endif
