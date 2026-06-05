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

## Typed services from a `.proto` (codegen)

`amalgame-formats-protobuf`'s `proto-gen.js` turns a `service {}` block
into a typed `<Name>Service`:

```amalgame
let svc = GreeterService.New()
    .OnSayHello((rq: HelloRequest) => {
        let out = HelloReply.New(); out.message = "Hello, " + rq.name; return out
    })
let server = GrpcServer.New()
svc.RegisterOn(server)        // decode → typed handler → encode, per rpc
server.ServeH2c(50051)
```

`RegisterOn` wires each rpc's path; the generated per-method adapter
decodes the request message, calls the typed `Closure<Req,Resp>`, and
encodes the reply. Unset handlers return `UNIMPLEMENTED`.

## gRPC client (v0.3.0)

```amalgame
let cli = GrpcClient.Dial("127.0.0.1", 50051)
let reply = cli.Call("/echo.Echo/Ping", requestMessageBytes)
// reply.Status (from the grpc-status trailer); reply.Body = reply message bytes
// decode reply.Body with ProtoReader / a generated <Msg>.Decode
```

`GrpcClient.Call` frames the request, sends it over net-http v0.23.0's
HTTP/2 client (`H2Client`), and returns a `GrpcReply` whose status comes
from the grpc-status trailer. **Proven end-to-end:** an Amalgame client
talks to an Amalgame `ServeH2c` server over TCP — echo round-trip incl. a
NUL byte + `grpc-status 0` (`examples/grpc_h2c_client.am`).

## gRPC over TLS (v0.5.0 server, v0.6.0 client)

```amalgame
GrpcServer.New() /* ...RegisterOn... */ .ServeHttps(443, "cert.pem", "key.pem")
```

`ServeHttps` serves HTTP/2 with ALPN `h2` over OpenSSL — production gRPC.
Same dispatch as `ServeH2c`; the H2 connection's I/O is TLS-wrapped.
The CLIENT speaks TLS too: GrpcClient.DialTls(host, port, insecure) (or a generated <Name>Client.DialTls). Validated by grpcurl over TLS AND a typed Amalgame client ↔ server over TLS (unary + streaming).

## All four method types (v0.7.0)

Unary, server-streaming, **client-streaming**, and **bidi** all work:

```amalgame
// client-streaming (N requests → 1 reply)
srv.RegisterClientStream("/s.S/Up", (reqs: GrpcRequests) => GrpcReply.Ok(summarize(reqs.Messages)))
let r = cli.CallClientStream("/s.S/Up", listOfRequestBytes)

// bidi (N requests → N replies)
srv.RegisterBidi("/s.S/Chat", (reqs: GrpcRequests) => GrpcStreamReply.Ok(replies))
let s = cli.CallBidi("/s.S/Chat", listOfRequestBytes)
```

Streaming uses the **collect model** (the client sends all its messages
framed in one body + END_STREAM; the server reads them all and replies)
— a valid gRPC exchange on the wire. True *incremental* flush (messages
delivered as produced) is a later net-http concern. Codegen covers unary
+ server-streaming; client-streaming/bidi use the runtime API directly.

## Server streaming (v0.4.0)

```amalgame
// server: one request → N reply messages
GrpcServer.New().RegisterStream("/feed.Feed/Items",
    (req: GrpcRequest) => GrpcStreamReply.Ok(listOfMessageBytes))

// client: collect every reply message
let s = cli.CallStream("/feed.Feed/Items", requestBytes)
// s.Messages : List<List<int>>  (s.Status from the grpc-status trailer)
```

The handler returns all messages at once (collect-then-send); on the
wire they go out as successive length-prefixed frames before the single
grpc-status trailer — a valid gRPC server-streaming response. Proven
end-to-end (3 messages, binary-safe). True incremental flush + client/
bidi streaming are later net-http work.

## Interop (grpcurl)

The test suite includes a **reference-client interop test**: the canonical
gRPC CLI [`grpcurl`](https://github.com/fullstorydev/grpcurl) calls a typed
`Greeter` server (`examples/greeter_server.am`) and must get
`{"message":"Hello, Ada"}` back:

```bash
grpcurl -plaintext -import-path tests -proto greeter.proto \
        -d '{"name":"Ada"}' localhost:50051 demo.v1.Greeter/SayHello
```

So the server speaks real, standard gRPC — not just our own client. CI
downloads grpcurl automatically; the local runner uses it if `grpcurl` is
on `PATH` (or `GRPCURL=<path>`), and skips otherwise.

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
