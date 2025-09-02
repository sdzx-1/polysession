const std = @import("std");
const meta = std.meta;

pub const Exit = union(enum) {};

pub fn Session(
    comptime name_: []const u8,
    comptime State_: type,
    comptime Data_: type,
) type {
    return struct {
        data: Data_,

        pub const name = name_;

        pub const State = State_;
        pub const Data = Data_;
    };
}

pub const Role = enum { client, server };

//example

pub fn PingPong(State_: type, Data_: type) type {
    return Session("PingPong", State_, Data_);
}

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

pub const Idle = union(enum) {
    ping: PingPong(Busy, i32),
    exit: PingPong(Exit, void),

    pub const agency: Role = .client;

    pub fn process(ctx: *ClientContext) @This() {
        ctx.client_counter += 1;
        if (ctx.client_counter > 10) return .{ .exit = .{ .data = {} } };
        return .{ .ping = .{ .data = ctx.client_counter } };
    }

    pub fn preprocess(ctx: *ServerContext, msg: @This()) void {
        switch (msg) {
            .exit => {},
            .ping => |val| {
                ctx.server_counter = val.data;
            },
        }
    }
};

pub const Busy = union(enum) {
    pong: PingPong(Idle, i32),

    pub const agency: Role = .server;

    pub fn process(ctx: *ServerContext) @This() {
        ctx.server_counter += 2;
        return .{ .pong = .{ .data = ctx.server_counter } };
    }

    pub fn preprocess(ctx: *ClientContext, msg: @This()) void {
        switch (msg) {
            .pong => |val| {
                ctx.client_counter = val.data;
            },
        }
    }
};

// Runner impl
fn TypeSet(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count][]const type,

        const Self = @This();

        pub const init: Self = .{
            .buckets = @splat(&.{}),
        };

        pub fn insert(comptime self: *Self, comptime Type: type) void {
            comptime {
                const hash = std.hash_map.hashString(@typeName(Type));

                self.buckets[hash % bucket_count] = self.buckets[hash % bucket_count] ++ &[_]type{Type};
            }
        }

        pub fn has(comptime self: Self, comptime Type: type) bool {
            comptime {
                const hash = std.hash_map.hashString(@typeName(Type));

                return std.mem.indexOfScalar(type, self.buckets[hash % bucket_count], Type) != null;
            }
        }

        pub fn items(comptime self: Self) []const type {
            comptime {
                var res: []const type = &.{};

                for (&self.buckets) |bucket| {
                    res = res ++ bucket;
                }

                return res;
            }
        }
    };
}

pub fn reachableStates(comptime FsmState: type) struct { states: []const type, state_machine_names: []const []const u8 } {
    comptime {
        var states: []const type = &.{FsmState.State};
        var state_machine_names: []const []const u8 = &.{FsmState.name};
        var states_stack: []const type = &.{FsmState};
        var states_set: TypeSet(128) = .init;
        const ExpectedContext = ContextFromState(FsmState.State);

        states_set.insert(FsmState.State);

        reachableStatesDepthFirstSearch(FsmState, &states, &state_machine_names, &states_stack, &states_set, ExpectedContext);

        return .{ .states = states, .state_machine_names = state_machine_names };
    }
}

fn reachableStatesDepthFirstSearch(
    comptime FsmState: type,
    comptime states: *[]const type,
    comptime state_machine_names: *[]const []const u8,
    comptime states_stack: *[]const type,
    comptime states_set: *TypeSet(128),
    comptime ExpectedContext: ClientAndServerContext,
) void {
    @setEvalBranchQuota(20_000_000);

    comptime {
        if (states_stack.len == 0) {
            return;
        }

        const CurrentFsmState = states_stack.*[states_stack.len - 1];
        states_stack.* = states_stack.*[0 .. states_stack.len - 1];

        const CurrentState = CurrentFsmState.State;

        switch (@typeInfo(CurrentState)) {
            .@"union" => |un| {
                for (un.fields) |field| {
                    const NextFsmState = field.type;

                    const NextState = NextFsmState.State;

                    if (!states_set.has(NextState)) {
                        // Validate that the handler context type matches (skip for special states like Exit)
                        if (NextState != Exit) {
                            const NextContext = ContextFromState(NextState);
                            if (NextContext.client != ExpectedContext.client or NextContext.server != ExpectedContext.server) {
                                @compileError(std.fmt.comptimePrint("Context type mismatch: State {s} has context type {s}, but expected {s}", .{ @typeName(NextState), @typeName(NextContext), @typeName(ExpectedContext) }));
                            }
                        }

                        states.* = states.* ++ &[_]type{NextState};
                        state_machine_names.* = state_machine_names.* ++ &[_][]const u8{NextFsmState.name};
                        states_stack.* = states_stack.* ++ &[_]type{NextFsmState};
                        states_set.insert(NextState);

                        reachableStatesDepthFirstSearch(FsmState, states, state_machine_names, states_stack, states_set, ExpectedContext);
                    }
                }
            },
            else => @compileError("Only support tagged union!"),
        }
    }
}

const ClientAndServerContext = struct {
    client: type,
    server: type,
};

fn ContextFromState(comptime State: type) ClientAndServerContext {
    const process_context =
        @typeInfo(@typeInfo(@TypeOf(State.process)).@"fn".params[0].type.?).pointer.child;

    const preprocess_context =
        @typeInfo(@typeInfo(@TypeOf(State.preprocess)).@"fn".params[0].type.?).pointer.child;

    const agency: Role = State.agency;

    return switch (agency) {
        .client => .{ .client = process_context, .server = preprocess_context },
        .server => .{ .client = preprocess_context, .server = process_context },
    };
}

pub const StateMap = struct {
    states: []const type,
    state_machine_names: []const []const u8,
    StateId: type,

    pub fn init(comptime FsmState: type) StateMap {
        @setEvalBranchQuota(200_000_000);

        comptime {
            const result = reachableStates(FsmState);
            return .{
                .states = result.states,
                .state_machine_names = result.state_machine_names,
                .StateId = @Type(.{
                    .@"enum" = .{
                        .tag_type = std.math.IntFittingRange(0, result.states.len - 1),
                        .fields = inner: {
                            var fields: [result.states.len]std.builtin.Type.EnumField = undefined;

                            for (&fields, result.states, 0..) |*field, State, state_int| {
                                field.* = .{
                                    .name = @typeName(State),
                                    .value = state_int,
                                };
                            }

                            const fields_const = fields;
                            break :inner &fields_const;
                        },
                        .decls = &.{},
                        .is_exhaustive = true,
                    },
                }),
            };
        }
    }

    pub fn StateFromId(comptime self: StateMap, comptime state_id: self.StateId) type {
        return self.states[@intFromEnum(state_id)];
    }

    pub fn idFromState(comptime self: StateMap, comptime State: type) self.StateId {
        if (!@hasField(self.StateId, @typeName(State))) @compileError(std.fmt.comptimePrint(
            "Can't find State {s}",
            .{@typeName(State)},
        ));
        return @field(self.StateId, @typeName(State));
    }
};

pub fn Runner(
    comptime FsmState: type,
    comptime role: Role,
) type {
    return struct {
        pub const Context = ContextFromState(FsmState.State);
        pub const state_map: StateMap = .init(FsmState);
        pub const StateId = state_map.StateId;

        pub fn idFromState(comptime State: type) StateId {
            return state_map.idFromState(State);
        }

        pub fn StateFromId(comptime state_id: StateId) type {
            return state_map.StateFromId(state_id);
        }

        pub fn runProtocol(curr_id: StateId, ctx: *@field(Context, @tagName(role))) void {
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (State == Exit) return;

                    const result = blk: {
                        if (comptime State.agency == role) {
                            const res = State.process(ctx);

                            // send msg
                            switch (role) {
                                .client => client_send(State, res),
                                .server => server_send(State, res),
                            }
                            std.debug.print("{t} send msg {any}\n", .{ role, res });
                            break :blk res;
                        } else {
                            //recv msg
                            const res =
                                switch (role) {
                                    .client => client_recv(State),
                                    .server => server_recv(State),
                                };
                            std.debug.print("{t} recv msg {any}\n", .{ role, res });
                            State.preprocess(ctx, res);
                            break :blk res;
                        }
                    };

                    switch (result) {
                        inline else => |new_fsm_state_wit| {
                            const NewFsmState = @TypeOf(new_fsm_state_wit);
                            continue :sw comptime idFromState(NewFsmState.State);
                        },
                    }
                },
            }
        }
    };
}

//simple send, recv
var client_mailbox: *const anyopaque = undefined;
pub var client_mutex: std.Thread.Mutex = .{};

var server_mailbox: *const anyopaque = undefined;
pub var server_mutex: std.Thread.Mutex = .{};

var gpa_install = std.heap.DebugAllocator(.{}).init;
const gpa = gpa_install.allocator();

pub fn client_send(T: type, val: T) void {
    const val1 = gpa.create(T) catch unreachable;
    val1.* = val;
    server_mailbox = val1;
    server_mutex.unlock();
}

pub fn client_recv(T: type) T {
    client_mutex.lock();
    const val: *const T = @ptrCast(@alignCast((client_mailbox)));
    const val1 = val.*;
    return val1;
}

pub fn server_send(T: type, val: T) void {
    const val1 = gpa.create(T) catch unreachable;
    val1.* = val;
    client_mailbox = val1;
    client_mutex.unlock();
}

pub fn server_recv(T: type) T {
    server_mutex.lock();
    const val: *const T = @ptrCast(@alignCast((server_mailbox)));
    const val1 = val.*;
    return val1;
}
