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
