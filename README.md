# amalgame-net-grpc

gRPC **server core** for the Amalgame / Mosaic stack — the
transport-agnostic layer between the protobuf codec
([`amalgame-formats-protobuf`](https://github.com/amalgame-lang/amalgame-formats-protobuf))
and an HTTP/2 transport: message framing, status codes, method-path
routing, and unary request dispatch. Pure, binary-safe (`List<int>`),
and unit-testable without a live connection.

```amalgame
import Amalgame.Net.Grpc
import Amalgame.Formats.Protobuf

let srv = GrpcServer.New()
    .Register("/greeter.Greeter/SayHello",
        (req: GrpcRequest) => GrpcReply.Ok(
            // decode req.Body with ProtoReader, build a reply message
            ProtoWriter.New().Str(1, "Hello").ToBytes()))

// A frontend (HTTP/2) hands the path + framed request body in; the
// reply body goes back as DATA and reply.Status as the grpc-status trailer.
let reply = srv.Dispatch(path, requestFrame)
let wire  = GrpcServer.ResponseFrame(reply)
```

## What's here

- **`GrpcFrame` / `GrpcFrameReader`** — gRPC length-prefixed framing:
  1-byte compression flag (0) + 4-byte big-endian length + payload.
  Binary-safe; a stream may carry several frames back-to-back.
- **`GrpcStatus`** — the canonical status codes (`Ok()`=0 … `Unauthenticated()`=16).
- **`GrpcPath`** — `Make(service, method)` → `/service/method`.
- **`GrpcRequest` / `GrpcReply`** — handler in/out (`GrpcReply.Ok(body)`,
  `GrpcReply.Error(status, message)`).
- **`GrpcServer`** — `Register(path, handler)` + `Dispatch(path, requestFrame)`
  (unknown path → `UNIMPLEMENTED`) + `ResponseFrame(reply)`.

## Scope (v0.1.0 — honest)

Core only. **The HTTP/2 serving itself is NOT here yet:** gRPC requires
the `grpc-status` / `grpc-message` HTTP/2 **trailers** and a binary-safe
request body, and `amalgame-net-http`'s nghttp2 binding doesn't expose
either today (`H2Conn_Respond` sends fixed headers with no trailers;
`H2Conn_Body` is a NUL-truncating string). Wiring that — so a real gRPC
client like `grpcurl` can talk to a Mosaic service end-to-end — is the
next milestone. Also to come: `.proto` IDL codegen, client stubs,
streaming (the framing already supports it per-message), and compression.

## Build & test

```bash
./tests/run_tests.sh          # 7 tests: framing/BE-length/dispatch, binary-safe
```

Self-contained for testing (only `amc` + a C toolchain + `libgc`). At
runtime, handlers use `amalgame-formats-protobuf` to (de)serialize
messages — declared as a dependency.

## License

Apache-2.0.
