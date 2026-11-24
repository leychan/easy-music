#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <libdbusmenu-glib/server.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* desktop_channel;
  GtkWindow* main_window;
  GtkWidget* lyrics_window;
  GtkWidget* lyrics_label;
  int previous_width;
  int previous_height;
  gboolean was_maximized;
  gboolean mini;
  GDBusConnection* tray_bus;
  GDBusNodeInfo* tray_info;
  guint tray_object;
  guint tray_watch;
  gboolean tray_registered;
  gboolean tray_playback_ready;
  gboolean first_frame_rendered;
  gboolean quitting;
  DbusmenuServer* tray_menu;
  DbusmenuMenuitem* tray_track;
  DbusmenuMenuitem* tray_previous;
  DbusmenuMenuitem* tray_play_pause;
  DbusmenuMenuitem* tray_next;
  DbusmenuMenuitem* tray_quit;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static constexpr char kTrayPath[] = "/StatusNotifierItem";
static constexpr char kTrayInterface[] = "org.kde.StatusNotifierItem";
static constexpr char kWatcher[] = "org.kde.StatusNotifierWatcher";
static constexpr char kTrayMenuPath[] = "/EasyMusicTrayMenu";

// KDE and compatible Linux shells use the StatusNotifierItem D-Bus interface.
static constexpr char kTrayXml[] =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='IconPixmap' type='a(iiay)' access='read'/>"
    "<property name='WindowId' type='i' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "</interface></node>";

static GVariant* tray_property(GDBusConnection*, const gchar*, const gchar*,
                               const gchar*, const gchar* name, GError**,
                               gpointer) {
  if (g_str_equal(name, "Category")) return g_variant_new_string("ApplicationStatus");
  if (g_str_equal(name, "Id")) return g_variant_new_string(APPLICATION_ID);
  if (g_str_equal(name, "Title")) return g_variant_new_string("Easy Music");
  if (g_str_equal(name, "Status")) return g_variant_new_string("Active");
  if (g_str_equal(name, "IconName")) return g_variant_new_string("audio-x-generic");
  if (g_str_equal(name, "IconPixmap")) {
    return g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0);
  }
  if (g_str_equal(name, "WindowId")) return g_variant_new_int32(0);
  if (g_str_equal(name, "ItemIsMenu")) return g_variant_new_boolean(FALSE);
  if (g_str_equal(name, "Menu")) return g_variant_new_object_path(kTrayMenuPath);
  return nullptr;
}

static void tray_method(GDBusConnection*, const gchar*, const gchar*,
                        const gchar*, const gchar* name, GVariant* parameters,
                        GDBusMethodInvocation* invocation, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if ((g_str_equal(name, "Activate") || g_str_equal(name, "ContextMenu")) &&
      self->main_window != nullptr) {
    gtk_window_present(self->main_window);
  } else if (g_str_equal(name, "SecondaryActivate") &&
             self->desktop_channel != nullptr) {
    fl_method_channel_invoke_method(self->desktop_channel, "trayPlayPause",
                                   nullptr, nullptr, nullptr, nullptr);
  } else if (g_str_equal(name, "Scroll") && self->desktop_channel != nullptr) {
    gint32 delta;
    const gchar* orientation;
    g_variant_get(parameters, "(i&s)", &delta, &orientation);
    if (delta != 0 && g_str_equal(orientation, "vertical")) {
      g_autoptr(FlValue) value = fl_value_new_int(delta > 0 ? 1 : -1);
      fl_method_channel_invoke_method(self->desktop_channel, "trayVolume",
                                     value, nullptr, nullptr, nullptr);
    }
  }
  g_dbus_method_invocation_return_value(invocation, nullptr);
}

static const GDBusInterfaceVTable kTrayVtable = {tray_method, tray_property,
                                               nullptr, {nullptr}};

static void desktop_engine_destroyed(gpointer data, GObject*) {
  g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, [](gpointer data) -> gboolean {
    g_application_release(G_APPLICATION(data));
    return G_SOURCE_REMOVE;
  }, data, g_object_unref);
}

static void request_desktop_quit(MyApplication* self) {
  if (self->quitting) return;
  self->quitting = TRUE;
  g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, [](gpointer data) -> gboolean {
    MyApplication* self = MY_APPLICATION(data);
    if (self->main_window != nullptr) {
      GtkWidget* view = gtk_bin_get_child(GTK_BIN(self->main_window));
      // 关闭窗口后让 GTK 主循环继续处理，直到 Flutter 释放渲染线程。
      g_application_hold(G_APPLICATION(self));
      g_object_weak_ref(G_OBJECT(fl_view_get_engine(FL_VIEW(view))),
                        desktop_engine_destroyed, g_object_ref(self));
      gtk_widget_destroy(GTK_WIDGET(self->main_window));
    } else {
      g_application_quit(G_APPLICATION(self));
    }
    return G_SOURCE_REMOVE;
  }, g_object_ref(self), g_object_unref);
}

static void tray_menu_activated(DbusmenuMenuitem* item, guint, gpointer data) {
  if (!dbusmenu_menuitem_property_get_bool(item, DBUSMENU_MENUITEM_PROP_ENABLED)) return;
  MyApplication* self = MY_APPLICATION(data);
  const auto* action = static_cast<const char*>(
      g_object_get_data(G_OBJECT(item), "easy-music-action"));
  if (g_str_equal(action, "open")) {
    g_application_activate(G_APPLICATION(self));
  } else if (self->tray_playback_ready) {
    fl_method_channel_invoke_method(self->desktop_channel, action, nullptr,
                                   nullptr, nullptr, nullptr);
  } else if (g_str_equal(action, "trayQuit")) {
    request_desktop_quit(self);
  }
}

static DbusmenuMenuitem* add_tray_menu_item(MyApplication* self,
                                          DbusmenuMenuitem* root,
                                          const char* label,
                                          const char* action,
                                          gboolean enabled) {
  DbusmenuMenuitem* item = dbusmenu_menuitem_new();
  dbusmenu_menuitem_property_set(item, DBUSMENU_MENUITEM_PROP_LABEL, label);
  dbusmenu_menuitem_property_set_bool(item, DBUSMENU_MENUITEM_PROP_ENABLED, enabled);
  if (action != nullptr) {
    g_object_set_data(G_OBJECT(item), "easy-music-action", const_cast<char*>(action));
    g_signal_connect(item, DBUSMENU_MENUITEM_SIGNAL_ITEM_ACTIVATED,
                     G_CALLBACK(tray_menu_activated), self);
  }
  dbusmenu_menuitem_child_append(root, item);
  g_object_unref(item);
  return item;
}

static void create_tray_menu(MyApplication* self) {
  // 由桌面外壳绘制菜单，应用只发布菜单项和操作。
  self->tray_menu = dbusmenu_server_new(kTrayMenuPath);
  DbusmenuMenuitem* root = dbusmenu_menuitem_new();
  self->tray_track = add_tray_menu_item(self, root, "暂无歌曲", nullptr, FALSE);
  self->tray_previous = add_tray_menu_item(self, root, "上一首", "trayPrevious", FALSE);
  self->tray_play_pause = add_tray_menu_item(self, root, "播放", "trayPlayPause", FALSE);
  self->tray_next = add_tray_menu_item(self, root, "下一首", "trayNext", FALSE);
  add_tray_menu_item(self, root, "打开 Easy Music", "open", TRUE);
  self->tray_quit = add_tray_menu_item(self, root, "退出", "trayQuit",
                                     self->first_frame_rendered);
  dbusmenu_server_set_root(self->tray_menu, root);
  g_object_unref(root);
}

static void tray_registration_finished(GObject* source, GAsyncResult* result,
                                       gpointer data) {
  g_autoptr(MyApplication) self = MY_APPLICATION(data);
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, nullptr);
  self->tray_registered = reply != nullptr;
}

static void tray_watcher_appeared(GDBusConnection* connection, const gchar*,
                                  const gchar*, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (self->tray_object == 0) {
    self->tray_info = g_dbus_node_info_new_for_xml(kTrayXml, nullptr);
    if (self->tray_info == nullptr) return;
    self->tray_bus = G_DBUS_CONNECTION(g_object_ref(connection));
    self->tray_object = g_dbus_connection_register_object(
        connection, kTrayPath,
        g_dbus_node_info_lookup_interface(self->tray_info, kTrayInterface),
        &kTrayVtable, self, nullptr, nullptr);
    if (self->tray_object == 0) {
      g_clear_pointer(&self->tray_info, g_dbus_node_info_unref);
      g_clear_object(&self->tray_bus);
      return;
    }
  }
  g_dbus_connection_call(connection, kWatcher, "/StatusNotifierWatcher",
                         kWatcher, "RegisterStatusNotifierItem",
                         g_variant_new("(s)", kTrayPath), nullptr,
                         G_DBUS_CALL_FLAGS_NONE, 3000, nullptr,
                         tray_registration_finished, g_object_ref(self));
}

static void tray_watcher_vanished(GDBusConnection*, const gchar*, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (self->tray_registered && self->main_window != nullptr &&
      !gtk_widget_get_visible(GTK_WIDGET(self->main_window))) {
    gtk_window_present(self->main_window);
  }
  self->tray_registered = FALSE;
}

static gboolean close_main_window(GtkWidget* window, GdkEvent*, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  // 没有可用托盘时保留系统原本的关闭行为，避免留下打不开的窗口。
  if (!self->tray_registered || !self->tray_playback_ready ||
      !self->first_frame_rendered) return FALSE;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      self->tray_bus, kWatcher, "/StatusNotifierWatcher",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", kWatcher, "IsStatusNotifierHostRegistered"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 500, nullptr, nullptr);
  if (reply == nullptr) return FALSE;
  g_autoptr(GVariant) host = nullptr;
  g_variant_get(reply, "(v)", &host);
  if (!g_variant_is_of_type(host, G_VARIANT_TYPE_BOOLEAN) ||
      !g_variant_get_boolean(host)) return FALSE;
  gtk_widget_hide(window);
  return TRUE;
}

static void set_lyrics_visible(MyApplication* self, gboolean visible) {
  if (!visible) {
    if (self->lyrics_window != nullptr) gtk_widget_hide(self->lyrics_window);
    return;
  }
  if (self->lyrics_window == nullptr) {
    self->lyrics_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    GtkWindow* window = GTK_WINDOW(self->lyrics_window);
    gtk_window_set_title(window, "Easy Music 桌面歌词");
    gtk_window_set_keep_above(window, TRUE);
    gtk_window_set_skip_taskbar_hint(window, TRUE);
    gtk_window_set_deletable(window, FALSE);
    gtk_window_set_resizable(window, FALSE);
    gtk_window_set_position(window, GTK_WIN_POS_CENTER);
    gtk_window_set_default_size(window, 520, 64);
    self->lyrics_label = gtk_label_new("");
    gtk_label_set_line_wrap(GTK_LABEL(self->lyrics_label), TRUE);
    gtk_widget_set_margin_start(self->lyrics_label, 14);
    gtk_widget_set_margin_end(self->lyrics_label, 14);
    g_autoptr(PangoAttrList) attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
    pango_attr_list_insert(attrs, pango_attr_size_new(19 * PANGO_SCALE));
    gtk_label_set_attributes(GTK_LABEL(self->lyrics_label), attrs);
    gtk_container_add(GTK_CONTAINER(window), self->lyrics_label);
  }
  gtk_widget_show_all(self->lyrics_window);
}

static void set_mini(MyApplication* self, gboolean enabled) {
  if (enabled == self->mini || self->main_window == nullptr) return;
  self->mini = enabled;
  if (enabled) {
    gtk_window_get_size(self->main_window, &self->previous_width,
                        &self->previous_height);
    self->was_maximized = gtk_window_is_maximized(self->main_window);
    gtk_window_unmaximize(self->main_window);
    gtk_window_set_keep_above(self->main_window, TRUE);
    gtk_window_resize(self->main_window, 456, 120);
  } else {
    gtk_window_set_keep_above(self->main_window, FALSE);
    gtk_window_resize(self->main_window, self->previous_width,
                      self->previous_height);
    if (self->was_maximized) gtk_window_maximize(self->main_window);
  }
}

static void desktop_method_call(FlMethodChannel* channel, FlMethodCall* call,
                                gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  const FlValueType type = args == nullptr ? FL_VALUE_TYPE_NULL : fl_value_get_type(args);
  gboolean accepted = TRUE;
  if (g_str_equal(method, "mini") && type == FL_VALUE_TYPE_BOOL) {
    set_mini(self, fl_value_get_bool(args));
  } else if (g_str_equal(method, "lyricsVisible") && type == FL_VALUE_TYPE_BOOL) {
    set_lyrics_visible(self, fl_value_get_bool(args));
  } else if (g_str_equal(method, "lyrics") && type == FL_VALUE_TYPE_STRING) {
    if (self->lyrics_label != nullptr) {
      gtk_label_set_text(GTK_LABEL(self->lyrics_label), fl_value_get_string(args));
    }
  } else if (g_str_equal(method, "trayPlayback") && type == FL_VALUE_TYPE_MAP) {
    FlValue* title = fl_value_lookup_string(args, "title");
    const bool has_track = title != nullptr && fl_value_get_type(title) == FL_VALUE_TYPE_STRING;
    const bool playing = fl_value_get_bool(fl_value_lookup_string(args, "playing"));
    dbusmenu_menuitem_property_set(self->tray_track, DBUSMENU_MENUITEM_PROP_LABEL,
                                  has_track ? fl_value_get_string(title) : "暂无歌曲");
    dbusmenu_menuitem_property_set(self->tray_play_pause, DBUSMENU_MENUITEM_PROP_LABEL,
                                  playing ? "暂停" : "播放");
    dbusmenu_menuitem_property_set_bool(self->tray_play_pause,
                                       DBUSMENU_MENUITEM_PROP_ENABLED, has_track);
    dbusmenu_menuitem_property_set_bool(self->tray_previous, DBUSMENU_MENUITEM_PROP_ENABLED,
        fl_value_get_bool(fl_value_lookup_string(args, "hasPrevious")));
    dbusmenu_menuitem_property_set_bool(self->tray_next, DBUSMENU_MENUITEM_PROP_ENABLED,
        fl_value_get_bool(fl_value_lookup_string(args, "hasNext")));
    self->tray_playback_ready = TRUE;
  } else if (!g_str_equal(method, "quit")) {
    accepted = FALSE;
  }
  g_autoptr(FlMethodResponse) response =
      accepted ? FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr))
               : FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
  if (g_str_equal(method, "quit")) request_desktop_quit(self);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  self->first_frame_rendered = TRUE;
  // 渲染器完成首帧前退出会与 GTK 图形资源的初始化重叠。
  if (self->tray_quit != nullptr) {
    dbusmenu_menuitem_property_set_bool(self->tray_quit,
                                       DBUSMENU_MENUITEM_PROP_ENABLED, TRUE);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->quitting) return;

  // Reuse the player window so two processes cannot update the same queue.
  if (self->main_window != nullptr) {
    gtk_window_present(self->main_window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->main_window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->main_window));
  g_signal_connect(window, "delete-event", G_CALLBACK(close_main_window), self);
  gtk_window_set_default_size(window, 1280, 720);

  // If you want to use a header bar, uncomment the following lines.
  // Header bars are commonly used in GNOME based desktop environments and
  // allow additional widgets to be added to the title bar.
  // See https://docs.gtk.org/gtk3/class.HeaderBar.html
  // GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
  // gtk_widget_show(GTK_WIDGET(header_bar));
  // gtk_header_bar_set_show_close_button(header_bar, TRUE);
  // gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));

  gtk_window_set_title(window, "Easy Music");

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  // Release 模式可能在视图 realize 后立刻发送初始播放状态。
  g_autoptr(FlStandardMethodCodec) desktop_codec = fl_standard_method_codec_new();
  self->desktop_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "dev.easymusic.easy_music/desktop", FL_METHOD_CODEC(desktop_codec));
  fl_method_channel_set_method_call_handler(
      self->desktop_channel, desktop_method_call, self, nullptr);
  create_tray_menu(self);

  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  // 在无 GPU 的虚拟机上 Impeller 可能永远出不了第一帧，窗口就一直不显示，
  // 表现为“进程活着但看不到界面”。这里先按最小尺寸显示，首帧到达后再把
  // 尺寸调回设计值，两种环境都能用。
  gtk_widget_show(GTK_WIDGET(window));
  gtk_window_resize(window, 1280, 720);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  self->tray_watch = g_bus_watch_name(
      G_BUS_TYPE_SESSION, kWatcher, G_BUS_NAME_WATCHER_FLAGS_NONE,
      tray_watcher_appeared, tray_watcher_vanished, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  if (self->main_window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->main_window),
                                reinterpret_cast<gpointer*>(&self->main_window));
  }
  if (self->tray_watch != 0) {
    g_bus_unwatch_name(self->tray_watch);
    self->tray_watch = 0;
  }
  if (self->tray_object != 0) {
    g_dbus_connection_unregister_object(self->tray_bus, self->tray_object);
    self->tray_object = 0;
  }
  g_clear_object(&self->tray_bus);
  g_clear_pointer(&self->tray_info, g_dbus_node_info_unref);
  g_clear_object(&self->tray_menu);
  g_clear_object(&self->desktop_channel);
  g_clear_pointer(&self->lyrics_window, gtk_widget_destroy);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, nullptr));
}
