const std = @import("std");
const meta = std.meta;

pub const Exit = union(enum) {};

pub fn Session(
    comptime name_: []const u8,
    comptime State_: type,
) type {
    return struct {
        pub const name = name_;
        pub const State = State_;
    };
}

pub const Role = enum {
    client,
    server,

    pub fn flip(role: Role) Role {
        return switch (role) {
            .client => .server,
            .server => .client,
        };
    }
};

pub fn Data(Data_: type, FsmState_: type) type {
    return struct {
        data: Data_,

        pub const Data = Data_;
        pub const FsmState = FsmState_;
    };
}

pub fn Cast(
    comptime Label_: []const u8,
    comptime agency_: Role,
    comptime CastFn: type,
    comptime T: type,
    comptime NextFsmState: type,
) type {
    return union(enum) {
        cast: Data(T, NextFsmState),

        pub const Label = Label_;

        pub const agency: Role = agency_;

        const ConfigContext = ContextFromState(CastFn, agency);

        pub fn process(ctx: *@field(ConfigContext, @tagName(agency))) !@This() {
            return .{ .cast = .{ .data = try CastFn.process(ctx) } };
        }

        pub fn preprocess(ctx: *@field(ConfigContext, @tagName(agency.flip())), msg: @This()) !void {
            switch (msg) {
                .cast => |val| try CastFn.preprocess(ctx, val.data),
            }
        }
    };
}

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
        const ExpectedContext = ContextFromState(FsmState.State, FsmState.State.agency);

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
                    const NextFsmState = field.type.FsmState;

                    const NextState = NextFsmState.State;

                    if (!states_set.has(NextState)) {
                        // Validate that the handler context type matches (skip for special states like Exit)
                        if (NextState != Exit) {
                            const NextContext = ContextFromState(NextState, NextState.agency);
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

pub const ClientAndServerContext = struct {
    client: type,
    server: type,
};

pub fn ContextFromState(comptime State: type, agency: Role) ClientAndServerContext {
    const process_context =
        @typeInfo(@typeInfo(@TypeOf(State.process)).@"fn".params[0].type.?).pointer.child;

    const preprocess_context =
        @typeInfo(@typeInfo(@TypeOf(State.preprocess)).@"fn".params[0].type.?).pointer.child;

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
) type {
    return struct {
        pub const Context = ContextFromState(FsmState.State, FsmState.State.agency);
        pub const state_map: StateMap = .init(FsmState);
        pub const StateId = state_map.StateId;

        pub fn idFromState(comptime State: type) StateId {
            return state_map.idFromState(State);
        }

        pub fn StateFromId(comptime state_id: StateId) type {
            return state_map.StateFromId(state_id);
        }

        pub fn runProtocol(
            comptime role: Role,
            channel: anytype,
            curr_id: StateId,
            comptime onProtocolSwitch: ?fn ([]const u8, []const u8) void, // Triggered when protocol switch,
            ctx: *@field(Context, @tagName(role)),
        ) !void {
            var curr_protocol_name: []const u8 = FsmState.name;
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (State == Exit) return;

                    const result = blk: {
                        if (comptime State.agency == role) {
                            const res = try State.process(ctx);
                            try channel.send(state_id, res);
                            break :blk res;
                        } else {
                            const res = try channel.recv(state_id, State);
                            try State.preprocess(ctx, res);
                            break :blk res;
                        }
                    };

                    switch (result) {
                        inline else => |new_fsm_state_wit| {
                            const NewFsmState = @TypeOf(new_fsm_state_wit).FsmState;
                            const new_protocol_name = comptime NewFsmState.name;
                            if (comptime onProtocolSwitch) |fun| {
                                if (!std.mem.eql(u8, curr_protocol_name, new_protocol_name)) {
                                    fun(curr_protocol_name, new_protocol_name);
                                    curr_protocol_name = new_protocol_name;
                                }
                            }
                            continue :sw comptime idFromState(NewFsmState.State);
                        },
                    }
                },
            }
        }
    };
}
