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

// Serve it end-to-end over HTTP/2 cleartext (h2c):
srv.ServeH2c(50051)   // blocks; accept → dispatch → RespondGrpc (trailers)
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

## End-to-end serving (v0.2.0)

`GrpcServer.ServeH2c(port)` serves real gRPC over HTTP/2 cleartext: it
accepts connections, reads the `:path` + the binary-safe framed request
body, dispatches to the registered handler, and answers via net-http
v0.22.0's `RespondGrpc` (which emits the `grpc-status`/`grpc-message`
HTTP/2 trailers). **Proven end-to-end:** a compiled Amalgame server
answers a real `nghttp2` client over TCP — `:status 200` +
`content-type application/grpc` + `grpc-status 0` + a framed echo body
byte-exact. See `examples/grpc_h2c_server.am`.

h2c suits internal service-to-service traffic; front it with TLS for
public endpoints. Unary only in v0.x.

## Scope — honest

**Remaining:** `.proto` IDL codegen + client stubs + streaming (the
framing already supports multiple messages per stream) + compression +
a `grpcurl` interop pass.

## Build & test

```bash
./tests/run_tests.sh          # 7 tests: framing/BE-length/dispatch, binary-safe
```

Needs `amc`, a C toolchain, `libgc`/`libnghttp2`/`libssl`, and the
sibling `amalgame-net-http` (+ `amalgame-tls`, `amalgame-async`) on disk
or via `amc package add` — `ServeH2c` builds on net-http's H2 transport.
Handlers use `amalgame-formats-protobuf` to (de)serialize messages.

## License

Apache-2.0.
