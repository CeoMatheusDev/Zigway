// Zigway Wayland: tabelas de interface do protocolo (o equivalente Zig do
// codigo gerado por `wayland-scanner`).
//
// A libwayland precisa da tabela de cada interface para (a) criar os
// objetos filhos e (b) despachar os eventos (a assinatura dita o layout
// dos argumentos). O codigo gerado e C; aqui as tabelas sao escritas a
// mao em Zig.
//
// As assinaturas foram conferidas com o codigo gerado de referencia
// (`wayland-scanner private-code wayland.xml`): o numero inicial de uma
// assinatura indica a versao em que a mensagem passou a existir (quando
// nao ha argumentos, a assinatura e so o numero).
//
// Assinaturas (wayland-util.h): i=int, u=uint, f=fixed, s=string,
// o=object, n=new_id, a=array, h=fd, ?=anulavel.

const std = @import("std");

/// `struct wl_message` (wayland-util.h).
pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const Interface,
};

/// `struct wl_interface` (wayland-util.h).
pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

// --- wl_display (v1) ---
const display_sync_types = [_]?*const Interface{&callback_interface};
const display_registry_types = [_]?*const Interface{&registry_interface};
const display_methods: [2]Message = .{
    .{ .name = "sync", .signature = "n", .types = &display_sync_types },
    .{ .name = "get_registry", .signature = "n", .types = &display_registry_types },
};
const display_events: [2]Message = .{
    .{ .name = "error", .signature = "ous", .types = null },
    .{ .name = "delete_id", .signature = "u", .types = null },
};

pub const display_interface = Interface{
    .name = "wl_display",
    .version = 1,
    .method_count = 2,
    .methods = &display_methods,
    .event_count = 2,
    .events = &display_events,
};

// --- wl_registry (v1) ---
// `bind`: nome (uint), nome da interface (string), versao (uint) e o
// objeto novo (new_id). A interface do objeto filho e informada a
// libwayland (parametro `interface` do marshal).
const registry_bind_types = [_]?*const Interface{ null, null, null, null };
const registry_methods: [1]Message = .{
    .{ .name = "bind", .signature = "usun", .types = &registry_bind_types },
};
const registry_events: [2]Message = .{
    .{ .name = "global", .signature = "usu", .types = null },
    .{ .name = "global_remove", .signature = "u", .types = null },
};

pub const registry_interface = Interface{
    .name = "wl_registry",
    .version = 1,
    .method_count = 1,
    .methods = &registry_methods,
    .event_count = 2,
    .events = &registry_events,
};

// --- wl_callback (v1) ---
const callback_events: [1]Message = .{
    .{ .name = "done", .signature = "u", .types = null },
};

pub const callback_interface = Interface{
    .name = "wl_callback",
    .version = 1,
    .method_count = 0,
    .methods = null,
    .event_count = 1,
    .events = &callback_events,
};

// --- wl_output (v4) ---
const output_methods: [1]Message = .{
    .{ .name = "release", .signature = "3", .types = null },
};
const output_events: [6]Message = .{
    .{ .name = "geometry", .signature = "iiiiissi", .types = null },
    .{ .name = "mode", .signature = "uiii", .types = null },
    .{ .name = "done", .signature = "2", .types = null },
    .{ .name = "scale", .signature = "2i", .types = null },
    .{ .name = "name", .signature = "4s", .types = null },
    .{ .name = "description", .signature = "4s", .types = null },
};

pub const output_interface = Interface{
    .name = "wl_output",
    .version = 4,
    .method_count = 1,
    .methods = &output_methods,
    .event_count = 6,
    .events = &output_events,
};

// --- wl_seat (v11) ---
const seat_pointer_types = [_]?*const Interface{&pointer_interface};
const seat_keyboard_types = [_]?*const Interface{&keyboard_interface};
const seat_touch_types = [_]?*const Interface{&touch_interface};
const seat_methods: [4]Message = .{
    .{ .name = "get_pointer", .signature = "n", .types = &seat_pointer_types },
    .{ .name = "get_keyboard", .signature = "n", .types = &seat_keyboard_types },
    .{ .name = "get_touch", .signature = "n", .types = &seat_touch_types },
    .{ .name = "release", .signature = "5", .types = null },
};
const seat_events: [2]Message = .{
    .{ .name = "capabilities", .signature = "u", .types = null },
    .{ .name = "name", .signature = "2s", .types = null },
};

pub const seat_interface = Interface{
    .name = "wl_seat",
    .version = 11,
    .method_count = 4,
    .methods = &seat_methods,
    .event_count = 2,
    .events = &seat_events,
};

// --- wl_pointer (v11) ---
// `set_cursor`: serial(u), surface(?o), hotspot_x(i), hotspot_y(i).
const pointer_cursor_types = [_]?*const Interface{ null, &surface_interface, null, null };
// `enter`: serial(u), surface(o), x(f), y(f).
const pointer_enter_types = [_]?*const Interface{ null, &surface_interface, null, null };
// `leave`: serial(u), surface(o).
const pointer_leave_types = [_]?*const Interface{ null, &surface_interface };
const pointer_methods: [2]Message = .{
    .{ .name = "set_cursor", .signature = "u?oii", .types = &pointer_cursor_types },
    .{ .name = "release", .signature = "3", .types = null },
};
const pointer_events: [12]Message = .{
    .{ .name = "enter", .signature = "uoff", .types = &pointer_enter_types },
    .{ .name = "leave", .signature = "uo", .types = &pointer_leave_types },
    .{ .name = "motion", .signature = "uff", .types = null },
    .{ .name = "button", .signature = "uuuu", .types = null },
    .{ .name = "axis", .signature = "uuf", .types = null },
    .{ .name = "frame", .signature = "5", .types = null },
    .{ .name = "axis_source", .signature = "5u", .types = null },
    .{ .name = "axis_stop", .signature = "5uu", .types = null },
    .{ .name = "axis_discrete", .signature = "5ui", .types = null },
    .{ .name = "axis_value120", .signature = "8ui", .types = null },
    .{ .name = "axis_relative_direction", .signature = "9uu", .types = null },
    .{ .name = "warp", .signature = "11ff", .types = null },
};

pub const pointer_interface = Interface{
    .name = "wl_pointer",
    .version = 11,
    .method_count = 2,
    .methods = &pointer_methods,
    .event_count = 12,
    .events = &pointer_events,
};

// --- wl_keyboard (v11) ---
const keyboard_methods: [1]Message = .{
    .{ .name = "release", .signature = "3", .types = null },
};
// `enter`: serial(u), surface(o), keys(a).
const keyboard_enter_types = [_]?*const Interface{ null, &surface_interface, null };
// `leave`: serial(u), surface(o).
const keyboard_leave_types = [_]?*const Interface{ null, &surface_interface };
const keyboard_events: [6]Message = .{
    .{ .name = "keymap", .signature = "uhu", .types = null },
    .{ .name = "enter", .signature = "uoa", .types = &keyboard_enter_types },
    .{ .name = "leave", .signature = "uo", .types = &keyboard_leave_types },
    .{ .name = "key", .signature = "uuuu", .types = null },
    .{ .name = "modifiers", .signature = "uuuuu", .types = null },
    .{ .name = "repeat_info", .signature = "4ii", .types = null },
};

pub const keyboard_interface = Interface{
    .name = "wl_keyboard",
    .version = 11,
    .method_count = 1,
    .methods = &keyboard_methods,
    .event_count = 6,
    .events = &keyboard_events,
};

// --- wl_touch (v11) ---
const touch_methods: [1]Message = .{
    .{ .name = "release", .signature = "3", .types = null },
};
const touch_events: [7]Message = .{
    .{ .name = "down", .signature = "uuoiff", .types = null },
    .{ .name = "up", .signature = "uui", .types = null },
    .{ .name = "motion", .signature = "uiff", .types = null },
    .{ .name = "frame", .signature = "", .types = null },
    .{ .name = "cancel", .signature = "", .types = null },
    .{ .name = "shape", .signature = "6iff", .types = null },
    .{ .name = "orientation", .signature = "6if", .types = null },
};

pub const touch_interface = Interface{
    .name = "wl_touch",
    .version = 11,
    .method_count = 1,
    .methods = &touch_methods,
    .event_count = 7,
    .events = &touch_events,
};

// --- wl_compositor (v7) ---
const compositor_surface_types = [_]?*const Interface{&surface_interface};
const compositor_region_types = [_]?*const Interface{&region_interface};
const compositor_methods: [3]Message = .{
    .{ .name = "create_surface", .signature = "n", .types = &compositor_surface_types },
    .{ .name = "create_region", .signature = "n", .types = &compositor_region_types },
    .{ .name = "release", .signature = "7", .types = null },
};

pub const compositor_interface = Interface{
    .name = "wl_compositor",
    .version = 7,
    .method_count = 3,
    .methods = &compositor_methods,
    .event_count = 0,
    .events = null,
};

// --- wl_surface (v7) ---
// `attach`: buffer(?o), x(i), y(i).
const surface_attach_types = [_]?*const Interface{ &buffer_interface, null, null };
const surface_frame_types = [_]?*const Interface{&callback_interface};
const surface_opaque_types = [_]?*const Interface{ null, &region_interface };
const surface_input_types = [_]?*const Interface{ null, &region_interface };
const surface_release_types = [_]?*const Interface{&callback_interface};
// `enter`/`leave`: output(o).
const surface_enter_types = [_]?*const Interface{&output_interface};
const surface_leave_types = [_]?*const Interface{&output_interface};
const surface_methods: [12]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "attach", .signature = "?oii", .types = &surface_attach_types },
    .{ .name = "damage", .signature = "iiii", .types = null },
    .{ .name = "frame", .signature = "n", .types = &surface_frame_types },
    .{ .name = "set_opaque_region", .signature = "?o", .types = &surface_opaque_types },
    .{ .name = "set_input_region", .signature = "?o", .types = &surface_input_types },
    .{ .name = "commit", .signature = "", .types = null },
    .{ .name = "set_buffer_transform", .signature = "2i", .types = null },
    .{ .name = "set_buffer_scale", .signature = "3i", .types = null },
    .{ .name = "damage_buffer", .signature = "4iiii", .types = null },
    .{ .name = "offset", .signature = "5ii", .types = null },
    .{ .name = "get_release", .signature = "7n", .types = &surface_release_types },
};
const surface_events: [4]Message = .{
    .{ .name = "enter", .signature = "o", .types = &surface_enter_types },
    .{ .name = "leave", .signature = "o", .types = &surface_leave_types },
    .{ .name = "preferred_buffer_scale", .signature = "6i", .types = null },
    .{ .name = "preferred_buffer_transform", .signature = "6u", .types = null },
};

pub const surface_interface = Interface{
    .name = "wl_surface",
    .version = 7,
    .method_count = 12,
    .methods = &surface_methods,
    .event_count = 4,
    .events = &surface_events,
};

// --- wl_region (v7) ---
const region_methods: [3]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "add", .signature = "iiii", .types = null },
    .{ .name = "subtract", .signature = "iiii", .types = null },
};

pub const region_interface = Interface{
    .name = "wl_region",
    .version = 7,
    .method_count = 3,
    .methods = &region_methods,
    .event_count = 0,
    .events = null,
};

// --- wl_shm (v3) ---
const shm_pool_types = [_]?*const Interface{ &shm_pool_interface, null, null };
const shm_methods: [2]Message = .{
    .{ .name = "create_pool", .signature = "nhi", .types = &shm_pool_types },
    .{ .name = "release", .signature = "2", .types = null },
};
const shm_events: [1]Message = .{
    .{ .name = "format", .signature = "u", .types = null },
};

pub const shm_interface = Interface{
    .name = "wl_shm",
    .version = 3,
    .method_count = 2,
    .methods = &shm_methods,
    .event_count = 1,
    .events = &shm_events,
};

// --- wl_shm_pool (v3) ---
const shm_buffer_types = [_]?*const Interface{ &buffer_interface, null, null, null, null, null };
const shm_pool_methods: [3]Message = .{
    .{ .name = "create_buffer", .signature = "niiiiu", .types = &shm_buffer_types },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "resize", .signature = "i", .types = null },
};

pub const shm_pool_interface = Interface{
    .name = "wl_shm_pool",
    .version = 3,
    .method_count = 3,
    .methods = &shm_pool_methods,
    .event_count = 0,
    .events = null,
};

// --- wl_buffer (v1) ---
const buffer_methods: [1]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
};
const buffer_events: [1]Message = .{
    .{ .name = "release", .signature = "", .types = null },
};

pub const buffer_interface = Interface{
    .name = "wl_buffer",
    .version = 1,
    .method_count = 1,
    .methods = &buffer_methods,
    .event_count = 1,
    .events = &buffer_events,
};

// --- xdg_wm_base (v6) ---
// xdg-shell: superficie de janela (desktop-style). `get_xdg_surface`
// recebe a wl_surface e devolve a xdg_surface (papel do objeto).
const xdg_wm_base_create_positioner_types = [_]?*const Interface{&xdg_positioner_interface};
const xdg_wm_base_get_xdg_surface_types = [_]?*const Interface{ &xdg_surface_interface, &surface_interface };
const xdg_wm_base_pong_types = [_]?*const Interface{null};
const xdg_wm_base_methods: [4]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "create_positioner", .signature = "n", .types = &xdg_wm_base_create_positioner_types },
    .{ .name = "get_xdg_surface", .signature = "no", .types = &xdg_wm_base_get_xdg_surface_types },
    .{ .name = "pong", .signature = "u", .types = &xdg_wm_base_pong_types },
};
const xdg_wm_base_ping_types = [_]?*const Interface{null};
const xdg_wm_base_events: [1]Message = .{
    .{ .name = "ping", .signature = "u", .types = &xdg_wm_base_ping_types },
};

pub const xdg_wm_base_interface = Interface{
    .name = "xdg_wm_base",
    .version = 6,
    .method_count = 4,
    .methods = &xdg_wm_base_methods,
    .event_count = 1,
    .events = &xdg_wm_base_events,
};

// --- xdg_positioner (v6) ---
// Usado por popups (xdg_surface.get_popup). Mantido aqui para que os
// indices de request da xdg_surface permaneçam alinhados ao protocolo.
const xdg_positioner_set_size_types = [_]?*const Interface{ null, null };
const xdg_positioner_set_anchor_rect_types = [_]?*const Interface{ null, null, null, null };
const xdg_positioner_set_anchor_types = [_]?*const Interface{null};
const xdg_positioner_set_gravity_types = [_]?*const Interface{null};
const xdg_positioner_set_constraint_adjustment_types = [_]?*const Interface{null};
const xdg_positioner_set_offset_types = [_]?*const Interface{ null, null };
const xdg_positioner_set_parent_size_types = [_]?*const Interface{ null, null };
const xdg_positioner_set_parent_configure_types = [_]?*const Interface{null};
const xdg_positioner_methods: [10]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_size", .signature = "ii", .types = &xdg_positioner_set_size_types },
    .{ .name = "set_anchor_rect", .signature = "iiii", .types = &xdg_positioner_set_anchor_rect_types },
    .{ .name = "set_anchor", .signature = "u", .types = &xdg_positioner_set_anchor_types },
    .{ .name = "set_gravity", .signature = "u", .types = &xdg_positioner_set_gravity_types },
    .{ .name = "set_constraint_adjustment", .signature = "u", .types = &xdg_positioner_set_constraint_adjustment_types },
    .{ .name = "set_offset", .signature = "ii", .types = &xdg_positioner_set_offset_types },
    .{ .name = "set_reactive", .signature = "3", .types = null },
    .{ .name = "set_parent_size", .signature = "3ii", .types = &xdg_positioner_set_parent_size_types },
    .{ .name = "set_parent_configure", .signature = "3u", .types = &xdg_positioner_set_parent_configure_types },
};

pub const xdg_positioner_interface = Interface{
    .name = "xdg_positioner",
    .version = 6,
    .method_count = 10,
    .methods = &xdg_positioner_methods,
    .event_count = 0,
    .events = null,
};

// --- xdg_surface (v6) ---
const xdg_surface_get_toplevel_types = [_]?*const Interface{&xdg_toplevel_interface};
const xdg_surface_get_popup_types = [_]?*const Interface{ &xdg_popup_interface, &xdg_surface_interface, &xdg_positioner_interface };
const xdg_surface_set_window_geometry_types = [_]?*const Interface{ null, null, null, null };
const xdg_surface_ack_configure_types = [_]?*const Interface{null};
const xdg_surface_methods: [5]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "get_toplevel", .signature = "n", .types = &xdg_surface_get_toplevel_types },
    .{ .name = "get_popup", .signature = "n?oo", .types = &xdg_surface_get_popup_types },
    .{ .name = "set_window_geometry", .signature = "iiii", .types = &xdg_surface_set_window_geometry_types },
    .{ .name = "ack_configure", .signature = "u", .types = &xdg_surface_ack_configure_types },
};
const xdg_surface_configure_types = [_]?*const Interface{null};
const xdg_surface_events: [1]Message = .{
    .{ .name = "configure", .signature = "u", .types = &xdg_surface_configure_types },
};

pub const xdg_surface_interface = Interface{
    .name = "xdg_surface",
    .version = 6,
    .method_count = 5,
    .methods = &xdg_surface_methods,
    .event_count = 1,
    .events = &xdg_surface_events,
};

// --- xdg_toplevel (v6) ---
const xdg_toplevel_set_parent_types = [_]?*const Interface{&xdg_toplevel_interface};
const xdg_toplevel_set_title_types = [_]?*const Interface{null};
const xdg_toplevel_set_app_id_types = [_]?*const Interface{null};
const xdg_toplevel_show_window_menu_types = [_]?*const Interface{ &seat_interface, null, null, null };
const xdg_toplevel_move_types = [_]?*const Interface{ &seat_interface, null };
const xdg_toplevel_resize_types = [_]?*const Interface{ &seat_interface, null, null };
const xdg_toplevel_set_max_size_types = [_]?*const Interface{ null, null };
const xdg_toplevel_set_min_size_types = [_]?*const Interface{ null, null };
const xdg_toplevel_set_fullscreen_types = [_]?*const Interface{&output_interface};
const xdg_toplevel_methods: [14]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_parent", .signature = "?o", .types = &xdg_toplevel_set_parent_types },
    .{ .name = "set_title", .signature = "s", .types = &xdg_toplevel_set_title_types },
    .{ .name = "set_app_id", .signature = "s", .types = &xdg_toplevel_set_app_id_types },
    .{ .name = "show_window_menu", .signature = "ouii", .types = &xdg_toplevel_show_window_menu_types },
    .{ .name = "move", .signature = "ou", .types = &xdg_toplevel_move_types },
    .{ .name = "resize", .signature = "ouu", .types = &xdg_toplevel_resize_types },
    .{ .name = "set_max_size", .signature = "ii", .types = &xdg_toplevel_set_max_size_types },
    .{ .name = "set_min_size", .signature = "ii", .types = &xdg_toplevel_set_min_size_types },
    .{ .name = "set_maximized", .signature = "", .types = null },
    .{ .name = "unset_maximized", .signature = "", .types = null },
    .{ .name = "set_fullscreen", .signature = "?o", .types = &xdg_toplevel_set_fullscreen_types },
    .{ .name = "unset_fullscreen", .signature = "", .types = null },
    .{ .name = "set_minimized", .signature = "", .types = null },
};
const xdg_toplevel_configure_types = [_]?*const Interface{ null, null, null };
const xdg_toplevel_configure_bounds_types = [_]?*const Interface{ null, null };
const xdg_toplevel_wm_capabilities_types = [_]?*const Interface{null};
const xdg_toplevel_events: [4]Message = .{
    .{ .name = "configure", .signature = "iia", .types = &xdg_toplevel_configure_types },
    .{ .name = "close", .signature = "", .types = null },
    .{ .name = "configure_bounds", .signature = "4ii", .types = &xdg_toplevel_configure_bounds_types },
    .{ .name = "wm_capabilities", .signature = "5a", .types = &xdg_toplevel_wm_capabilities_types },
};

pub const xdg_toplevel_interface = Interface{
    .name = "xdg_toplevel",
    .version = 6,
    .method_count = 14,
    .methods = &xdg_toplevel_methods,
    .event_count = 4,
    .events = &xdg_toplevel_events,
};

// --- xdg_popup (v6) ---
// Popups nao sao usados ainda; a tabela existe para manter os indices
// de request da xdg_surface alinhados ao protocolo.
const xdg_popup_grab_types = [_]?*const Interface{ &xdg_popup_interface, null };
const xdg_popup_reposition_types = [_]?*const Interface{ &xdg_popup_interface, &seat_interface, null };
const xdg_popup_methods: [3]Message = .{
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "grab", .signature = "ou", .types = &xdg_popup_grab_types },
    .{ .name = "reposition", .signature = "3ou", .types = &xdg_popup_reposition_types },
};
const xdg_popup_configure_types = [_]?*const Interface{ null, null, null, null };
const xdg_popup_repositioned_types = [_]?*const Interface{null};
const xdg_popup_events: [3]Message = .{
    .{ .name = "configure", .signature = "iiii", .types = &xdg_popup_configure_types },
    .{ .name = "popup_done", .signature = "", .types = null },
    .{ .name = "repositioned", .signature = "3u", .types = &xdg_popup_repositioned_types },
};

pub const xdg_popup_interface = Interface{
    .name = "xdg_popup",
    .version = 6,
    .method_count = 3,
    .methods = &xdg_popup_methods,
    .event_count = 3,
    .events = &xdg_popup_events,
};

// --- wl_data_device_manager (v4) ---
const manager_source_types = [_]?*const Interface{&data_source_interface};
const manager_device_types = [_]?*const Interface{ &data_device_interface, &seat_interface };
const manager_methods: [3]Message = .{
    .{ .name = "create_data_source", .signature = "n", .types = &manager_source_types },
    .{ .name = "get_data_device", .signature = "no", .types = &manager_device_types },
    .{ .name = "release", .signature = "4", .types = null },
};

pub const data_device_manager_interface = Interface{
    .name = "wl_data_device_manager",
    .version = 4,
    .method_count = 3,
    .methods = &manager_methods,
    .event_count = 0,
    .events = null,
};

// --- wl_data_device (v4) ---
const device_drag_types = [_]?*const Interface{
    null,
    &data_source_interface,
    &surface_interface,
    &surface_interface,
    &seat_interface,
};
const device_selection_types = [_]?*const Interface{ &data_source_interface, null };
const device_offer_types = [_]?*const Interface{&data_offer_interface};
const device_selection_event_types = [_]?*const Interface{&data_offer_interface};
const device_enter_types = [_]?*const Interface{
    null,
    null,
    null,
    null,
    &surface_interface,
};
const device_methods: [3]Message = .{
    .{ .name = "start_drag", .signature = "?oo?ou", .types = &device_drag_types },
    .{ .name = "set_selection", .signature = "?ou", .types = &device_selection_types },
    .{ .name = "release", .signature = "2", .types = null },
};
const device_events: [6]Message = .{
    .{ .name = "data_offer", .signature = "n", .types = &device_offer_types },
    .{ .name = "enter", .signature = "uoff?o", .types = &device_enter_types },
    .{ .name = "leave", .signature = "", .types = null },
    .{ .name = "motion", .signature = "uff", .types = null },
    .{ .name = "drop", .signature = "", .types = null },
    .{ .name = "selection", .signature = "?o", .types = &device_selection_event_types },
};

pub const data_device_interface = Interface{
    .name = "wl_data_device",
    .version = 4,
    .method_count = 3,
    .methods = &device_methods,
    .event_count = 6,
    .events = &device_events,
};

// --- wl_data_source (v4) ---
const source_methods: [3]Message = .{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "set_actions", .signature = "3u", .types = null },
};
const source_events: [6]Message = .{
    .{ .name = "target", .signature = "?s", .types = null },
    .{ .name = "send", .signature = "sh", .types = null },
    .{ .name = "cancelled", .signature = "", .types = null },
    .{ .name = "dnd_drop_performed", .signature = "3", .types = null },
    .{ .name = "dnd_finished", .signature = "3", .types = null },
    .{ .name = "action", .signature = "3u", .types = null },
};

pub const data_source_interface = Interface{
    .name = "wl_data_source",
    .version = 4,
    .method_count = 3,
    .methods = &source_methods,
    .event_count = 6,
    .events = &source_events,
};

// --- wl_data_offer (v4) ---
const offer_methods: [5]Message = .{
    .{ .name = "accept", .signature = "u?s", .types = null },
    .{ .name = "receive", .signature = "sh", .types = null },
    .{ .name = "destroy", .signature = "", .types = null },
    .{ .name = "finish", .signature = "3", .types = null },
    .{ .name = "set_actions", .signature = "3uu", .types = null },
};
const offer_events: [3]Message = .{
    .{ .name = "offer", .signature = "s", .types = null },
    .{ .name = "source_actions", .signature = "3u", .types = null },
    .{ .name = "action", .signature = "3u", .types = null },
};

pub const data_offer_interface = Interface{
    .name = "wl_data_offer",
    .version = 4,
    .method_count = 5,
    .methods = &offer_methods,
    .event_count = 3,
    .events = &offer_events,
};

test "interface layout matches wayland-util.h" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Interface));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Interface, "name"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Interface, "version"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Interface, "method_count"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Interface, "methods"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Interface, "event_count"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Interface, "events"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Message));
}

test "protocol tables match the generated reference" {
    // Assinaturas conferidas com `wayland-scanner private-code`.
    try std.testing.expectEqualStrings("usun", std.mem.span(registry_methods[0].signature));
    try std.testing.expectEqualStrings("usu", std.mem.span(registry_events[0].signature));
    try std.testing.expectEqualStrings("iiiiissi", std.mem.span(output_events[0].signature));
    try std.testing.expectEqualStrings("uiii", std.mem.span(output_events[1].signature));
    try std.testing.expectEqualStrings("2", std.mem.span(output_events[2].signature));
    try std.testing.expectEqualStrings("2i", std.mem.span(output_events[3].signature));
    try std.testing.expectEqualStrings("4s", std.mem.span(output_events[4].signature));
    try std.testing.expectEqualStrings("2s", std.mem.span(seat_events[1].signature));
    try std.testing.expectEqual(@as(c_int, 4), output_interface.version);
    try std.testing.expectEqual(@as(c_int, 6), output_interface.event_count);
    // Clipboard (data device).
    try std.testing.expectEqualStrings("n", std.mem.span(manager_methods[0].signature));
    try std.testing.expectEqualStrings("no", std.mem.span(manager_methods[1].signature));
    try std.testing.expectEqualStrings("?ou", std.mem.span(device_methods[1].signature));
    try std.testing.expectEqualStrings("?o", std.mem.span(device_events[5].signature));
    try std.testing.expectEqualStrings("sh", std.mem.span(source_events[1].signature));
    try std.testing.expectEqualStrings("u?s", std.mem.span(offer_methods[0].signature));
    try std.testing.expectEqualStrings("sh", std.mem.span(offer_methods[1].signature));
}

test "xdg-shell tables match the generated reference" {
    // Assinaturas conferidas com `wayland-scanner private-code
    // xdg-shell.xml` (wayland-protocols 6.x).
    try std.testing.expectEqualStrings("n", std.mem.span(xdg_wm_base_methods[1].signature));
    try std.testing.expectEqualStrings("no", std.mem.span(xdg_wm_base_methods[2].signature));
    try std.testing.expectEqualStrings("u", std.mem.span(xdg_wm_base_methods[3].signature));
    try std.testing.expectEqualStrings("u", std.mem.span(xdg_wm_base_events[0].signature));
    try std.testing.expectEqualStrings("n", std.mem.span(xdg_surface_methods[1].signature));
    try std.testing.expectEqualStrings("n?oo", std.mem.span(xdg_surface_methods[2].signature));
    try std.testing.expectEqualStrings("iiii", std.mem.span(xdg_surface_methods[3].signature));
    try std.testing.expectEqualStrings("u", std.mem.span(xdg_surface_methods[4].signature));
    try std.testing.expectEqualStrings("u", std.mem.span(xdg_surface_events[0].signature));
    try std.testing.expectEqualStrings("?o", std.mem.span(xdg_toplevel_methods[1].signature));
    try std.testing.expectEqualStrings("s", std.mem.span(xdg_toplevel_methods[2].signature));
    try std.testing.expectEqualStrings("ouu", std.mem.span(xdg_toplevel_methods[6].signature));
    try std.testing.expectEqualStrings("ii", std.mem.span(xdg_toplevel_methods[7].signature));
    try std.testing.expectEqualStrings("?o", std.mem.span(xdg_toplevel_methods[11].signature));
    try std.testing.expectEqualStrings("iia", std.mem.span(xdg_toplevel_events[0].signature));
    try std.testing.expectEqualStrings("", std.mem.span(xdg_toplevel_events[1].signature));
    try std.testing.expectEqualStrings("4ii", std.mem.span(xdg_toplevel_events[2].signature));
    try std.testing.expectEqualStrings("5a", std.mem.span(xdg_toplevel_events[3].signature));
    // Indices de request sao o opcode do protocolo: a ordem importa.
    try std.testing.expectEqualStrings("get_toplevel", std.mem.span(xdg_surface_methods[1].name));
    try std.testing.expectEqualStrings("set_title", std.mem.span(xdg_toplevel_methods[2].name));
    try std.testing.expectEqualStrings("ack_configure", std.mem.span(xdg_surface_methods[4].name));
    try std.testing.expectEqual(@as(c_int, 6), xdg_wm_base_interface.version);
    try std.testing.expectEqual(@as(c_int, 4), xdg_toplevel_interface.event_count);
    try std.testing.expectEqual(@as(c_int, 14), xdg_toplevel_interface.method_count);
}
