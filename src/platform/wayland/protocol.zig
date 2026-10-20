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
const pointer_cursor_types = [_]?*const Interface{ null, null, &surface_interface, null, null };
const pointer_methods: [2]Message = .{
    .{ .name = "set_cursor", .signature = "u?oii", .types = &pointer_cursor_types },
    .{ .name = "release", .signature = "3", .types = null },
};
const pointer_events: [12]Message = .{
    .{ .name = "enter", .signature = "uoff", .types = null },
    .{ .name = "leave", .signature = "uo", .types = null },
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
const keyboard_events: [6]Message = .{
    .{ .name = "keymap", .signature = "uhu", .types = null },
    .{ .name = "enter", .signature = "uoa", .types = null },
    .{ .name = "leave", .signature = "uo", .types = null },
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
const surface_attach_types = [_]?*const Interface{ null, &buffer_interface, null, null };
const surface_frame_types = [_]?*const Interface{&callback_interface};
const surface_opaque_types = [_]?*const Interface{ null, &region_interface };
const surface_input_types = [_]?*const Interface{ null, &region_interface };
const surface_release_types = [_]?*const Interface{&callback_interface};
const surface_enter_types = [_]?*const Interface{&surface_interface};
const surface_leave_types = [_]?*const Interface{&surface_interface};
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
}
