// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Inkscape for Android — GTK4 ネイティブ版
 *
 * キャンバスウィジェットの実装。
 *
 * SVG のページを中央に表示し、以下をサポートする:
 *   - 1 本指ドラッグ / マウスドラッグでのパン
 *   - ピンチでのズーム (フォーカルポイントを維持)
 *   - マウスホイール (Ctrl+ホイールでズーム、通常はパン)
 *   - ダブルタップで「ページにフィット」と 100% の切り替え
 */

#include "ink-canvas.h"

#include <math.h>

struct _InkCanvas
{
  GtkWidget parent_instance;

  GdkPaintable *paintable;

  double zoom;
  double pan_x;
  double pan_y;

  /* ジェスチャ開始時の状態 */
  double drag_start_pan_x;
  double drag_start_pan_y;
  double zoom_start;
  double zoom_focal_x;
  double zoom_focal_y;

  gboolean fit_pending;
};

G_DEFINE_TYPE (InkCanvas, ink_canvas, GTK_TYPE_WIDGET)

enum
{
  PROP_0,
  PROP_ZOOM,
  N_PROPS
};

static GParamSpec *properties[N_PROPS];

#define INK_CANVAS_MIN_ZOOM 0.01
#define INK_CANVAS_MAX_ZOOM 128.0

static void
ink_canvas_get_page_size (InkCanvas *self,
                         double    *width,
                         double    *height)
{
  *width = 0.0;
  *height = 0.0;

  if (self->paintable == NULL)
    return;

  *width = gdk_paintable_get_intrinsic_width (self->paintable);
  *height = gdk_paintable_get_intrinsic_height (self->paintable);
}

static void
ink_canvas_zoom_about (InkCanvas *self,
                       double     new_zoom,
                       double     focal_x,
                       double     focal_y)
{
  double pw, ph;
  double widget_w, widget_h;

  new_zoom = CLAMP (new_zoom, INK_CANVAS_MIN_ZOOM, INK_CANVAS_MAX_ZOOM);

  if (fabs (new_zoom - self->zoom) < 1e-9)
    return;

  ink_canvas_get_page_size (self, &pw, &ph);

  widget_w = gtk_widget_get_width (GTK_WIDGET (self));
  widget_h = gtk_widget_get_height (GTK_WIDGET (self));

  if (pw > 0.0 && ph > 0.0 && self->zoom > 0.0)
    {
      double cx = widget_w / 2.0;
      double cy = widget_h / 2.0;
      double ratio = new_zoom / self->zoom;

      /* widget = center + pan + zoom * (doc - page/2) */
      self->pan_x = (focal_x - cx) - ratio * ((focal_x - cx) - self->pan_x);
      self->pan_y = (focal_y - cy) - ratio * ((focal_y - cy) - self->pan_y);
    }

  self->zoom = new_zoom;
  gtk_widget_queue_draw (GTK_WIDGET (self));
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_ZOOM]);
}

static void
ink_canvas_apply_fit (InkCanvas *self)
{
  double pw, ph;
  int w, h;
  double margin = 24.0;

  ink_canvas_get_page_size (self, &pw, &ph);
  w = gtk_widget_get_width (GTK_WIDGET (self));
  h = gtk_widget_get_height (GTK_WIDGET (self));

  if (pw <= 0.0 || ph <= 0.0 || w <= 0 || h <= 0)
    return;

  self->zoom = CLAMP (MIN ((w - 2.0 * margin) / pw,
                           (h - 2.0 * margin) / ph),
                      INK_CANVAS_MIN_ZOOM, INK_CANVAS_MAX_ZOOM);
  self->pan_x = 0.0;
  self->pan_y = 0.0;

  gtk_widget_queue_draw (GTK_WIDGET (self));
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_ZOOM]);
}

static void
ink_canvas_snapshot (GtkWidget   *widget,
                     GtkSnapshot *snapshot)
{
  InkCanvas *self = INK_CANVAS (widget);
  double pw, ph;
  double scale;
  double ox, oy;
  int w, h;
  GdkRGBA white = { 1.0f, 1.0f, 1.0f, 1.0f };
  GdkRGBA border = { 0.0f, 0.0f, 0.0f, 0.35f };
  graphene_rect_t page;

  /* テーマ由来の背景 (CSS) を描く */
  GTK_WIDGET_CLASS (ink_canvas_parent_class)->snapshot (widget, snapshot);

  ink_canvas_get_page_size (self, &pw, &ph);

  if (pw <= 0.0 || ph <= 0.0)
    {
      /* ドキュメント未読み込み時のプレースホルダ */
      GdkRGBA hint = { 0.6f, 0.6f, 0.6f, 1.0f };
      PangoLayout *layout;
      PangoFontDescription *desc;
      graphene_rect_t area;

      layout = gtk_widget_create_pango_layout (widget, "No document open");
      desc = pango_font_description_from_string ("Sans 16");
      pango_layout_set_font_description (layout, desc);
      pango_font_description_free (desc);

      w = gtk_widget_get_width (widget);
      h = gtk_widget_get_height (widget);
      graphene_rect_init (&area, 0, 0, w, h);

      gtk_snapshot_push_clip (snapshot, &area);
      gtk_snapshot_save (snapshot);
      {
        graphene_point_t origin;
        graphene_point_init (&origin, w / 2.0 - 80.0, h / 2.0 - 12.0);
        gtk_snapshot_translate (snapshot, &origin);
      }
      gtk_snapshot_append_layout (snapshot, layout, &hint);
      gtk_snapshot_restore (snapshot);
      gtk_snapshot_pop (snapshot);

      g_object_unref (layout);
      return;
    }

  if (self->fit_pending)
    {
      self->fit_pending = FALSE;
      ink_canvas_apply_fit (self);
    }

  w = gtk_widget_get_width (widget);
  h = gtk_widget_get_height (widget);

  scale = self->zoom;
  ox = (w - pw * scale) / 2.0 + self->pan_x;
  oy = (h - ph * scale) / 2.0 + self->pan_y;

  /* ページの影 (縁取り) */
  graphene_rect_init (&page, ox - 1.0, oy - 1.0, pw * scale + 2.0, ph * scale + 2.0);
  gtk_snapshot_append_color (snapshot, &border, &page);

  /* 白いページ */
  graphene_rect_init (&page, ox, oy, pw * scale, ph * scale);
  gtk_snapshot_append_color (snapshot, &white, &page);

  /* ページ範囲にクリップして SVG を描画 */
  gtk_snapshot_push_clip (snapshot, &page);
  gtk_snapshot_save (snapshot);
  {
    graphene_point_t origin;
    graphene_point_init (&origin, ox, oy);
    gtk_snapshot_translate (snapshot, &origin);
  }
  gdk_paintable_snapshot (self->paintable, snapshot, pw * scale, ph * scale);
  gtk_snapshot_restore (snapshot);
  gtk_snapshot_pop (snapshot);
}

static void
ink_canvas_measure (GtkWidget      *widget,
                    GtkOrientation  orientation,
                    int             for_size,
                    int            *minimum,
                    int            *natural,
                    int            *minimum_baseline,
                    int            *natural_baseline)
{
  *minimum = 0;
  *natural = 0;
  *minimum_baseline = -1;
  *natural_baseline = -1;
}

static void
ink_canvas_size_allocate (GtkWidget *widget,
                          int        width,
                          int        height,
                          int        baseline)
{
  InkCanvas *self = INK_CANVAS (widget);

  GTK_WIDGET_CLASS (ink_canvas_parent_class)->size_allocate (widget, width, height, baseline);

  if (self->fit_pending)
    {
      self->fit_pending = FALSE;
      ink_canvas_apply_fit (self);
    }
}

static void
on_drag_begin (GtkGestureDrag *gesture,
               double          start_x,
               double          start_y,
               InkCanvas      *self)
{
  (void) gesture;
  (void) start_x;
  (void) start_y;

  self->drag_start_pan_x = self->pan_x;
  self->drag_start_pan_y = self->pan_y;
}

static void
on_drag_update (GtkGestureDrag *gesture,
                double          offset_x,
                double          offset_y,
                InkCanvas      *self)
{
  (void) gesture;

  self->pan_x = self->drag_start_pan_x + offset_x;
  self->pan_y = self->drag_start_pan_y + offset_y;

  gtk_widget_queue_draw (GTK_WIDGET (self));
}

static void
on_scale_begin (GtkGestureZoom *gesture,
                GdkSequence    *sequence,
                InkCanvas      *self)
{
  double cx, cy;

  (void) sequence;

  self->zoom_start = self->zoom;

  if (!gtk_gesture_zoom_get_bounding_box_center (gesture, &cx, &cy))
    {
      cx = gtk_widget_get_width (GTK_WIDGET (self)) / 2.0;
      cy = gtk_widget_get_height (GTK_WIDGET (self)) / 2.0;
    }

  self->zoom_focal_x = cx;
  self->zoom_focal_y = cy;
}

static void
on_scale_changed (GtkGestureZoom *gesture,
                  double          scale,
                  InkCanvas      *self)
{
  (void) gesture;

  ink_canvas_zoom_about (self,
                         self->zoom_start * scale,
                         self->zoom_focal_x,
                         self->zoom_focal_y);
}

static void
on_click_pressed (GtkGestureClick *gesture,
                  int              n_press,
                  double           x,
                  double           y,
                  InkCanvas       *self)
{
  (void) gesture;
  (void) x;
  (void) y;

  if (n_press == 2)
    {
      /* ダブルタップ: フィット表示と 100% を切り替え */
      if (self->zoom > 1.02 || self->zoom < 0.98)
        ink_canvas_zoom_reset (self);
      else
        ink_canvas_zoom_fit (self);
    }
}

static gboolean
on_scroll (GtkEventControllerScroll *controller,
           double                    dx,
           double                    dy,
           InkCanvas                *self)
{
  GdkModifierType state;

  state = gtk_event_controller_get_current_event_state (GTK_EVENT_CONTROLLER (controller));

  if (state & GDK_CONTROL_MASK)
    {
      double cx = gtk_widget_get_width (GTK_WIDGET (self)) / 2.0;
      double cy = gtk_widget_get_height (GTK_WIDGET (self)) / 2.0;

      ink_canvas_zoom_about (self,
                             self->zoom * pow (1.1, -dy),
                             cx, cy);
    }
  else
    {
      self->pan_x -= dx;
      self->pan_y -= dy;
      gtk_widget_queue_draw (GTK_WIDGET (self));
    }

  return GDK_EVENT_STOP;
}

static void
ink_canvas_set_property (GObject      *object,
                         guint         prop_id,
                         const GValue *value,
                         GParamSpec   *pspec)
{
  InkCanvas *self = INK_CANVAS (object);

  switch (prop_id)
    {
    case PROP_ZOOM:
      ink_canvas_set_zoom (self, g_value_get_double (value));
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
ink_canvas_get_property (GObject    *object,
                         guint       prop_id,
                         GValue     *value,
                         GParamSpec *pspec)
{
  InkCanvas *self = INK_CANVAS (object);

  switch (prop_id)
    {
    case PROP_ZOOM:
      g_value_set_double (value, self->zoom);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
      break;
    }
}

static void
ink_canvas_dispose (GObject *object)
{
  InkCanvas *self = INK_CANVAS (object);

  g_clear_object (&self->paintable);

  G_OBJECT_CLASS (ink_canvas_parent_class)->dispose (object);
}

static void
ink_canvas_class_init (InkCanvasClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  object_class->set_property = ink_canvas_set_property;
  object_class->get_property = ink_canvas_get_property;
  object_class->dispose = ink_canvas_dispose;

  widget_class->snapshot = ink_canvas_snapshot;
  widget_class->measure = ink_canvas_measure;
  widget_class->size_allocate = ink_canvas_size_allocate;

  properties[PROP_ZOOM] =
    g_param_spec_double ("zoom", NULL, NULL,
                         INK_CANVAS_MIN_ZOOM, INK_CANVAS_MAX_ZOOM, 1.0,
                         G_PARAM_READWRITE | G_PARAM_EXPLICIT_NOTIFY | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, N_PROPS, properties);

  gtk_widget_class_set_css_name (widget_class, "inkcanvas");
}

static void
ink_canvas_init (InkCanvas *self)
{
  GtkGesture *drag;
  GtkGesture *zoom;
  GtkGesture *click;
  GtkEventController *scroll;

  self->zoom = 1.0;
  self->fit_pending = TRUE;

  gtk_widget_set_hexpand (GTK_WIDGET (self), TRUE);
  gtk_widget_set_vexpand (GTK_WIDGET (self), TRUE);
  gtk_widget_set_focusable (GTK_WIDGET (self), TRUE);

  drag = gtk_gesture_drag_new ();
  gtk_gesture_single_set_button (GTK_GESTURE_SINGLE (drag), 1);
  g_signal_connect (drag, "drag-begin", G_CALLBACK (on_drag_begin), self);
  g_signal_connect (drag, "drag-update", G_CALLBACK (on_drag_update), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (drag));

  zoom = gtk_gesture_zoom_new ();
  g_signal_connect (zoom, "scale-begin", G_CALLBACK (on_scale_begin), self);
  g_signal_connect (zoom, "scale-changed", G_CALLBACK (on_scale_changed), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (zoom));

  gtk_gesture_group (drag, zoom);

  click = gtk_gesture_click_new ();
  gtk_gesture_single_set_button (GTK_GESTURE_SINGLE (click), 1);
  g_signal_connect (click, "pressed", G_CALLBACK (on_click_pressed), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (click));

  scroll = gtk_event_controller_scroll_new (GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect (scroll, "scroll", G_CALLBACK (on_scroll), self);
  gtk_widget_add_controller (GTK_WIDGET (self), scroll);
}

GtkWidget *
ink_canvas_new (void)
{
  return g_object_new (INK_TYPE_CANVAS, NULL);
}

void
ink_canvas_set_paintable (InkCanvas    *self,
                          GdkPaintable *paintable)
{
  g_return_if_fail (INK_IS_CANVAS (self));

  if (self->paintable == paintable)
    return;

  g_set_object (&self->paintable, paintable);
  self->fit_pending = TRUE;

  gtk_widget_queue_draw (GTK_WIDGET (self));
}

GdkPaintable *
ink_canvas_get_paintable (InkCanvas *self)
{
  g_return_val_if_fail (INK_IS_CANVAS (self), NULL);

  return self->paintable;
}

void
ink_canvas_set_zoom (InkCanvas *self,
                     double     zoom)
{
  g_return_if_fail (INK_IS_CANVAS (self));

  ink_canvas_zoom_about (self,
                         zoom,
                         gtk_widget_get_width (GTK_WIDGET (self)) / 2.0,
                         gtk_widget_get_height (GTK_WIDGET (self)) / 2.0);
}

double
ink_canvas_get_zoom (InkCanvas *self)
{
  g_return_val_if_fail (INK_IS_CANVAS (self), 1.0);

  return self->zoom;
}

void
ink_canvas_zoom_fit (InkCanvas *self)
{
  g_return_if_fail (INK_IS_CANVAS (self));

  self->fit_pending = TRUE;
  gtk_widget_queue_draw (GTK_WIDGET (self));
}

void
ink_canvas_zoom_reset (InkCanvas *self)
{
  g_return_if_fail (INK_IS_CANVAS (self));

  self->fit_pending = FALSE;
  self->pan_x = 0.0;
  self->pan_y = 0.0;
  self->zoom = 1.0;

  gtk_widget_queue_draw (GTK_WIDGET (self));
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_ZOOM]);
}

void
ink_canvas_zoom_in (InkCanvas *self)
{
  g_return_if_fail (INK_IS_CANVAS (self));

  ink_canvas_zoom_about (self,
                         self->zoom * 1.25,
                         gtk_widget_get_width (GTK_WIDGET (self)) / 2.0,
                         gtk_widget_get_height (GTK_WIDGET (self)) / 2.0);
}

void
ink_canvas_zoom_out (InkCanvas *self)
{
  g_return_if_fail (INK_IS_CANVAS (self));

  ink_canvas_zoom_about (self,
                         self->zoom / 1.25,
                         gtk_widget_get_width (GTK_WIDGET (self)) / 2.0,
                         gtk_widget_get_height (GTK_WIDGET (self)) / 2.0);
}

