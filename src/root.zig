const std = @import("std");
const meta = std.meta;

pub const Exit = union(enum) {
    pub const protocol = "polysession_exit";
};

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
    comptime protocol_: []const u8,
    comptime Label_: []const u8,
    comptime agency_: Role,
    comptime T: type,
    comptime CastFn: type,
    comptime NextFsmState: type,
) type {
    return union(enum) {
        cast: Data(T, NextFsmState),

        pub const Label = Label_;

        pub const agency: Role = agency_;
        pub const protocol = protocol_;

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
        var states: []const type = &.{FsmState};
        var state_machine_names: []const []const u8 = &.{FsmState.protocol};
        var states_stack: []const type = &.{FsmState};
        var states_set: TypeSet(128) = .init;
        const ExpectedContext = ContextFromState(FsmState, FsmState.agency);

        states_set.insert(FsmState);

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

        const CurrentState = CurrentFsmState;

        switch (@typeInfo(CurrentState)) {
            .@"union" => |un| {
                for (un.fields) |field| {
                    const NextFsmState = field.type.FsmState;

                    if (!states_set.has(NextFsmState)) {
                        // Validate that the handler context type matches (skip for special states like Exit)
                        if (NextFsmState != Exit) {
                            const NextContext = ContextFromState(NextFsmState, NextFsmState.agency);
                            if (NextContext.client != ExpectedContext.client or NextContext.server != ExpectedContext.server) {
                                @compileError(std.fmt.comptimePrint(
                                    "Context type mismatch: FsmState {s} has context type {s}, but expected {s}",
                                    .{ @typeName(NextFsmState), @typeName(NextContext), @typeName(ExpectedContext) },
                                ));
                            }
                        }

                        states.* = states.* ++ &[_]type{NextFsmState};
                        state_machine_names.* = state_machine_names.* ++ &[_][]const u8{NextFsmState.protocol};
                        states_stack.* = states_stack.* ++ &[_]type{NextFsmState};
                        states_set.insert(NextFsmState);

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
        pub const Context = ContextFromState(FsmState, FsmState.agency);
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
            ctx: *@field(Context, @tagName(role)),
        ) !void {
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
                            const NewData = @TypeOf(new_fsm_state_wit);
                            continue :sw comptime idFromState(NewData.FsmState);
                        },
                    }
                },
            }
        }
    };
}
