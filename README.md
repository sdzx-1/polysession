A multi-role communication protocol framework.


## Adding polysession to your project
Requires zig version greater than 0.15.0.


Download and add polysession as a dependency by running the following command in your project root:
```shell
zig fetch --save git+https://github.com/sdzx-1/polysession.git
```

Then, retrieve the dependency in your build.zig:
```zig
const polysession = b.dependency("polysession", .{
    .target = target,
    .optimize = optimize,
});
```

Finally, add the dependency's module to your module's imports:
```zig
exe_mod.addImport("polysession", polysession.module("root"));
```

You should now be able to import polysession in your module's code:
```zig
const ps = @import("polysession");
```
## Core idea
### 0. Polysession assumes that communication between roles is sequential
Polysession ensures that the behavior of each role is completely determined by the state machine.
If the communication itself can guarantee the order (such as TCP), then the protocol described by polysession is deterministic and the behavior of all roles is consistent.

### 1. Compositionality of State

Through [polystate](https://github.com/sdzx-1/polystate), we know that state can be used as a function and parameter, which we call high-order state.

### 2. Viewing the Communication Process as State Machines
Through the introduction [here](https://discourse.haskell.org/t/introduction-to-typed-session/10100), we know that communication can be modeled using a state machine.

### 3. How to handle branch status in multi-role communication
Multi-role communication differs from client-server communication in that polysession requires that messages generated during branching must be notified to all other parties.
This ensures that all roles are synchronized.

### 4. How to Combine Protocols with Different Participants
If two protocol participants are exactly the same, then the states are directly combined.
If the participants of the two protocols are different, then we need to notify all other roles except the roles of the previous protocol.
This [issue](https://github.com/sdzx-1/polysession/issues/15) describes the situation.

### 5. How to learn polysession
You need to first familiarize yourself with polystate and how to combine states. Then look at the examples that come with polysession.

## Examples
### pingpong
```shell
zig build pingpong
```
Alice and Bob have multiple ping-pong communications back and forth.

![pingpong](./data/pingpong.svg)
### sendfile

```shell
zig build sendfile
```
Alice sends a file to Bob, and every time she sends a chunk of data, she checks whether the hash values of the sent and received data match.

![sendfile](./data/sendfile.svg)
### pingpong-sendfile

```shell
zig build pingpong-sendfile
```
Combining the pingpong protocol and the sendfile protocol

![pingpong-sendfile](./data/pingpong-sendfile.svg)
### 2pc

```shell
zig build 2pc
```
A two-phase protocol demo with Charlie as the coordinator and Alice and Bob as participants.
Alice and Bob have no actual transactions; they simply randomly return true or false.

![2pc](./data/2pc.svg)
### random-pingpong-2pc

```shell
zig build random-pingpong-2pc
```
A complex protocol involving four actors has an additional selector to select the combined protocol to run.
Here, we arbitrarily combine the pingpong protocol and the 2pc protocol.
Note that the communication actors in pingpong and 2pc are different.
Polysession supports this combination of different protocols, even if the protocols have different numbers of participants.


![random-pingpong-2pc](./data/random-pingpong-2cp.svg)
