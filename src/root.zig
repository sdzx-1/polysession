const std = @import("std");
const meta = std.meta;
pub const Graph = @import("Graph.zig");

pub fn ProtocolInfo(Name_: []const u8, Role_: type, Context_: anytype) type {
    comptime {
        //TODO: check Role and Context;
    }

    return struct {
        sender: Role_,
        receiver: []const Role_,

        pub const Name = Name_;
        pub const Role = Role_;
        pub const Context = Context_;

        pub fn RoleCtx(_: @This(), r: Role_) type {
            return @field(Context_, @tagName(r));
        }
    };
}

pub const Exit = union(enum) {
    pub const info: Info = .{};

    pub const Info = struct {
        pub const Name = "polysession_exit";
        pub const Role = void;
        pub const Context = void;
    };
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
    comptime Role: type,
    comptime sender: Role,
    comptime receiver: Role,
    comptime T: type,
    comptime Context: anytype,
    comptime process_: fn (*@field(Context, @tagName(sender))) anyerror!T,
    comptime preprocess_: fn (*@field(Context, @tagName(receiver)), T) anyerror!void,
    comptime NextFsmState: type,
) type {
    return union(enum) {
        cast: Data(T, NextFsmState),

        pub const Label = Label_;

        pub const info: ProtocolInfo(protocol_, Role, Context) = .{
            .sender = sender,
            .receiver = &.{receiver},
        };

        pub fn process(ctx: *@field(Context, @tagName(sender))) !@This() {
            return .{ .cast = .{ .data = try process_(ctx) } };
        }

        pub fn preprocess_0(ctx: *@field(Context, @tagName(receiver)), msg: @This()) !void {
            switch (msg) {
                .cast => |val| try preprocess_(ctx, val.data),
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
        var state_machine_names: []const []const u8 = &.{@TypeOf(FsmState.info).Name};
        var states_stack: []const type = &.{FsmState};
        var states_set: TypeSet(128) = .init;
        const ExpectedContext = @TypeOf(FsmState.info).Context;

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
    comptime ExpectedContext: anytype, //Context type
) void {
    @setEvalBranchQuota(20_000_000);

    comptime {
        if (states_stack.len == 0) {
            return;
        }
        //TODO: Check the following conditions
        //Do not check Exit FsmState.
        //The receiver can be one or more, but cannot be the sender, and cannot be repeated.
        //The preprocess function corresponds to the receiver's sequence number (preprocess0, preprocess1...),
        // and in the branch state, it is required that: sender + receiver = all roles

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
                            const Info = @TypeOf(NextFsmState.info);
                            const NextContext = Info.Context;
                            const Role = Info.Role;
                            const is_equal: bool = blk: {
                                for (@typeInfo(Role).@"enum".fields) |F| {
                                    if (@field(NextContext, F.name) != @field(ExpectedContext, F.name)) {
                                        break :blk false;
                                    }
                                }
                                break :blk true;
                            };
                            if (!is_equal) {
                                @compileError(std.fmt.comptimePrint(
                                    "Context type mismatch: FsmState {any}\nhas context type {any}\nbut expected {any}",
                                    .{ NextFsmState, NextContext, ExpectedContext },
                                ));
                            }
                        }

                        states.* = states.* ++ &[_]type{NextFsmState};
                        state_machine_names.* = state_machine_names.* ++ &[_][]const u8{@TypeOf(NextFsmState.info).Name};
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
        const Info = @TypeOf(FsmState.info);
        pub const Role = Info.Role;
        pub const state_map: StateMap = .init(FsmState);
        pub const StateId = state_map.StateId;

        pub fn idFromState(comptime State: type) StateId {
            return state_map.idFromState(State);
        }

        pub fn StateFromId(comptime state_id: StateId) type {
            return state_map.StateFromId(state_id);
        }

        pub fn runProtocol(
            comptime curr_role: Role,
            mult_channel: anytype,
            curr_id: StateId,
            ctx: *FsmState.info.RoleCtx(curr_role),
        ) !void {
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (comptime State == Exit) return;

                    const sender: Role = State.info.sender;
                    const receiver: []const Role = State.info.receiver;

                    if (comptime curr_role == sender) {
                        const result = try State.process(ctx);
                        inline for (receiver) |rvr| {
                            try @field(mult_channel, @tagName(rvr)).send(state_id, result);
                        }
                        switch (result) {
                            inline else => |new_fsm_state_wit| {
                                const NewData = @TypeOf(new_fsm_state_wit);
                                continue :sw comptime idFromState(NewData.FsmState);
                            },
                        }
                    } else {
                        const midx: ?usize = comptime blk: {
                            for (0.., receiver) |i, rvr| {
                                if (curr_role == rvr) break :blk i;
                            }
                            break :blk null;
                        };

                        if (midx) |idx| {
                            const result = try @field(mult_channel, @tagName(sender)).recv(state_id, State);
                            const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                            try @field(State, fn_name)(ctx, result);

                            switch (result) {
                                inline else => |new_fsm_state_wit| {
                                    const NewData = @TypeOf(new_fsm_state_wit);
                                    continue :sw comptime idFromState(NewData.FsmState);
                                },
                            }
                        } else {
                            switch (@typeInfo(State)) {
                                .@"union" => |U| {
                                    comptime std.debug.assert(U.fields.len == 1);
                                    continue :sw comptime idFromState(U.fields[0].type.FsmState);
                                },
                                else => unreachable,
                            }
                        }
                    }
                },
            }
        }
    };
}
