#!/bin/bash
# amalgame-net-grpc — test runner.
#
# The gRPC core unit tests are pure, but the facade now also exposes
# GrpcServer.ServeH2c, which imports Amalgame.Net.Http (H2Server/H2Conn).
# amc resolves those stdlib classes through the PkgRegistry, so we stage
# a fake package cache + amalgame.lock pointing at the sibling net-http
# (+ async, whose runtime header net-http includes) — the same dance
# amalgame-net-proxy uses. tls is needed only as an -I include path.
set -u
PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"

AMC=""
if   [ -n "${1:-}" ];                   then AMC="$1"
elif command -v amc >/dev/null 2>&1;    then AMC="$(command -v amc)"
elif [ -x "$PKG_DIR/../Amalgame/amc" ]; then AMC="$PKG_DIR/../Amalgame/amc"
elif [ -x "$HOME/.local/bin/amc" ];     then AMC="$HOME/.local/bin/amc"
fi
[ -x "$AMC" ] || { echo "error: amc not found"; exit 2; }

RUNTIME_DIR=""
if   [ -n "${AMC_RUNTIME:-}" ] && [ -d "$AMC_RUNTIME" ]; then RUNTIME_DIR="$AMC_RUNTIME"
elif [ -d "$PKG_DIR/../Amalgame/runtime" ];             then RUNTIME_DIR="$PKG_DIR/../Amalgame/runtime"
elif [ -d "$HOME/.amalgame/runtime" ];                  then RUNTIME_DIR="$HOME/.amalgame/runtime"
fi

resolve() {  # $1=env var, $2=repo name, $3=needed-file
    local v="${!1:-}"
    if [ -n "$v" ] && [ -d "$v" ]; then echo "$v"; return; fi
    if [ -d "$PKG_DIR/../$2" ] && [ -e "$PKG_DIR/../$2/$3" ]; then echo "$PKG_DIR/../$2"; return; fi
    echo ""
}
NETHTTP_DIR="$(resolve AMALGAME_NET_HTTP amalgame-net-http facade.am)"
TLS_DIR="$(resolve AMALGAME_TLS amalgame-tls runtime)"
ASYNC_DIR="$(resolve AMALGAME_ASYNC amalgame-async amalgame.toml)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
[ -n "$NETHTTP_DIR" ] || { echo -e "${RED}error: amalgame-net-http not found${NC}"; exit 2; }
[ -n "$TLS_DIR" ]     || { echo -e "${RED}error: amalgame-tls not found${NC}"; exit 2; }
[ -n "$ASYNC_DIR" ]   || { echo -e "${RED}error: amalgame-async not found${NC}"; exit 2; }

BUILD_DIR=$(mktemp -d -t amalgame-net-grpc-XXXXXX)
EXISTING_LOCK=""
[ -f "$PKG_DIR/amalgame.lock" ] && { EXISTING_LOCK="$BUILD_DIR/lock.bak"; cp "$PKG_DIR/amalgame.lock" "$EXISTING_LOCK"; }
cleanup() {
    rm -rf "$BUILD_DIR"
    if [ -n "$EXISTING_LOCK" ] && [ -f "$EXISTING_LOCK" ]; then mv "$EXISTING_LOCK" "$PKG_DIR/amalgame.lock"
    else rm -f "$PKG_DIR/amalgame.lock"; fi
}
trap cleanup EXIT

FAKE_CACHE="$BUILD_DIR/pkg_cache"
link_pkg() {  # $1=dir $2=git-path $3=tag $4=sha
    local d="$FAKE_CACHE/$2/${3}_${4:0:8}"
    mkdir -p "$(dirname "$d")"; rm -rf "$d"; ln -s "$1" "$d"
}
link_pkg "$NETHTTP_DIR" "github.com/amalgame-lang/amalgame-net-http" "v0.24.0" "abcdef0123456789000000000000000000000ef"
link_pkg "$ASYNC_DIR"   "github.com/amalgame-lang/amalgame-async"    "v0.2.0"  "fedcba9876543210000000000000000000000ff"
export AMALGAME_PACKAGES_DIR="$FAKE_CACHE"

cat > "$PKG_DIR/amalgame.lock" <<EOF
[[package]]
name = "amalgame-net-http"
git  = "github.com/amalgame-lang/amalgame-net-http"
tag  = "v0.24.0"
rev  = "abcdef0123456789000000000000000000000ef"

[[package]]
name = "amalgame-async"
git  = "github.com/amalgame-lang/amalgame-async"
tag  = "v0.2.0"
rev  = "fedcba9876543210000000000000000000000ff"
EOF

cd "$PKG_DIR"
INCS="-Iruntime -I$NETHTTP_DIR/runtime -I$TLS_DIR/runtime -I$ASYNC_DIR/runtime -I$RUNTIME_DIR"
LIBS="-lnghttp2 -lssl -lcrypto -lpthread -lgc -lm -lz"
FAILED=0

NH_SRCS="$NETHTTP_DIR/facade.am $NETHTTP_DIR/cookie.am $NETHTTP_DIR/http_request.am $NETHTTP_DIR/http_response.am $NETHTTP_DIR/http_parser.am $NETHTTP_DIR/http_server.am $NETHTTP_DIR/http_client.am $NETHTTP_DIR/multipart.am $NETHTTP_DIR/sse.am"
"$AMC" --lib -o "$BUILD_DIR/nh" $NH_SRCS >/dev/null 2>&1
gcc -O2 $INCS -c "$BUILD_DIR/nh.c" -o "$BUILD_DIR/nh.o" 2>"$BUILD_DIR/e" \
    || { echo -e "${RED}net-http build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }

"$AMC" --lib -o "$BUILD_DIR/facade" facade.am >/dev/null 2>&1
gcc -O2 $INCS -c "$BUILD_DIR/facade.c" -o "$BUILD_DIR/facade.o" 2>"$BUILD_DIR/e" \
    || { echo -e "${RED}facade build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }

echo -e "\n── core tests ──"
"$AMC" -o "$BUILD_DIR/t" tests/grpc_test.am --external facade.am >/dev/null 2>&1
gcc -O2 $INCS "$BUILD_DIR/t.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nh.o" $LIBS -o "$BUILD_DIR/t" 2>"$BUILD_DIR/e" \
    || { echo -e "${RED}test build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
OUT="$("$BUILD_DIR/t")"; echo "$OUT"
echo "$OUT" | grep -q "\[FAIL\]" && FAILED=1

# ── service-stub codegen test (needs the sibling formats-protobuf) ──
PB_DIR="$(resolve AMALGAME_FORMATS_PROTOBUF amalgame-formats-protobuf facade.am)"
echo -e "\n── service-stub codegen ──"
if [ -z "$PB_DIR" ]; then
    echo "amalgame-formats-protobuf not found — skipping service-stub test"
else
    PINC="$INCS -I$PB_DIR/runtime"
    # regenerate the fixture if node + the generator are present
    if command -v node >/dev/null 2>&1 && [ -f "$PB_DIR/tools/proto-gen.js" ]; then
        node "$PB_DIR/tools/proto-gen.js" tests/greeter.proto tests/greeter_pb.am \
            || { echo -e "${RED}proto-gen (service) failed${NC}"; FAILED=1; }
    fi
    "$AMC" --lib -o "$BUILD_DIR/pb" "$PB_DIR/facade.am" >/dev/null 2>&1
    gcc -O2 $PINC -c "$BUILD_DIR/pb.c" -o "$BUILD_DIR/pb.o" 2>"$BUILD_DIR/e" \
        || { echo -e "${RED}formats-protobuf build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
    "$AMC" --lib -o "$BUILD_DIR/greeter" tests/greeter_pb.am --external facade.am --external "$PB_DIR/facade.am" >/dev/null 2>&1
    gcc -O2 $PINC -c "$BUILD_DIR/greeter.c" -o "$BUILD_DIR/greeter.o" 2>"$BUILD_DIR/e" \
        || { echo -e "${RED}generated build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
    "$AMC" -o "$BUILD_DIR/svc" tests/service_test.am --external facade.am --external "$PB_DIR/facade.am" --external tests/greeter_pb.am >/dev/null 2>&1
    gcc -O2 $PINC "$BUILD_DIR/svc.c" "$BUILD_DIR/greeter.o" "$BUILD_DIR/facade.o" "$BUILD_DIR/nh.o" "$BUILD_DIR/pb.o" $LIBS -o "$BUILD_DIR/svc" 2>"$BUILD_DIR/e" \
        || { echo -e "${RED}service test build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
    OUT2="$("$BUILD_DIR/svc")"; echo "$OUT2"
    echo "$OUT2" | grep -q "\[FAIL\]" && FAILED=1

    # ── grpcurl interop (the reference gRPC client calls our server) ──
    GRPCURL="${GRPCURL:-}"
    [ -z "$GRPCURL" ] && command -v grpcurl >/dev/null 2>&1 && GRPCURL="$(command -v grpcurl)"
    echo -e "\n── grpcurl interop (reference client → typed Greeter) ──"
    if [ -z "$GRPCURL" ] || [ ! -x "$GRPCURL" ]; then
        echo "grpcurl not found — skipping (set GRPCURL=<path> or install it; CI provides it)"
    else
        "$AMC" -o "$BUILD_DIR/gsrv" examples/greeter_server.am --external facade.am --external "$PB_DIR/facade.am" --external tests/greeter_pb.am >/dev/null 2>&1
        gcc -O2 $PINC "$BUILD_DIR/gsrv.c" "$BUILD_DIR/greeter.o" "$BUILD_DIR/facade.o" "$BUILD_DIR/nh.o" "$BUILD_DIR/pb.o" $LIBS -o "$BUILD_DIR/gsrv" 2>"$BUILD_DIR/e" \
            || { echo -e "${RED}greeter server build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
        GPORT=50098
        NS_GRPC_PORT=$GPORT "$BUILD_DIR/gsrv" >/dev/null 2>&1 & GSRV=$!
        sleep 0.6
        GOUT="$("$GRPCURL" -plaintext -import-path tests -proto greeter.proto -d '{"name":"Ada"}' 127.0.0.1:$GPORT demo.v1.Greeter/SayHello 2>&1)"
        kill "$GSRV" 2>/dev/null
        if echo "$GOUT" | grep -q "Hello, Ada"; then
            echo -e "${GREEN}[PASS]${NC} grpcurl → SayHello returns \"Hello, Ada\""
        else
            echo -e "${RED}[FAIL]${NC} grpcurl interop: $GOUT"; FAILED=1
        fi
    fi

    # ── typed e2e: generated GreeterClient ↔ generated GreeterService ──
    echo -e "\n── typed e2e: GreeterClient.SayHello ↔ GreeterService ──"
    for ex in greeter_server greeter_client; do
        "$AMC" -o "$BUILD_DIR/$ex" examples/$ex.am --external facade.am --external "$PB_DIR/facade.am" --external tests/greeter_pb.am >/dev/null 2>&1
        gcc -O2 $PINC "$BUILD_DIR/$ex.c" "$BUILD_DIR/greeter.o" "$BUILD_DIR/facade.o" "$BUILD_DIR/nh.o" "$BUILD_DIR/pb.o" $LIBS -o "$BUILD_DIR/$ex" 2>"$BUILD_DIR/e" \
            || { echo -e "${RED}$ex build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
    done
    TPORT=50100
    NS_GRPC_PORT=$TPORT "$BUILD_DIR/greeter_server" >/dev/null 2>&1 & TSRV=$!
    sleep 0.6
    TOUT="$(NS_GRPC_PORT=$TPORT timeout 15 "$BUILD_DIR/greeter_client")"; echo "$TOUT"
    kill "$TSRV" 2>/dev/null
    echo "$TOUT" | grep -q "\[PASS\]" || FAILED=1

    # ── gRPC over TLS (ServeHttps) validated by grpcurl ──────────────
    echo -e "\n── gRPC over TLS (ServeHttps) via grpcurl ──"
    if [ -z "$GRPCURL" ] || ! command -v openssl >/dev/null 2>&1; then
        echo "grpcurl/openssl not available — skipping TLS interop"
    else
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$BUILD_DIR/g.key" -out "$BUILD_DIR/g.crt" \
            -days 2 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
        SPORT=50102
        NS_GRPC_PORT=$SPORT NS_GRPC_CERT="$BUILD_DIR/g.crt" NS_GRPC_KEY="$BUILD_DIR/g.key" "$BUILD_DIR/greeter_server" >/dev/null 2>&1 & STSRV=$!
        sleep 0.8
        SOUT="$("$GRPCURL" -insecure -authority localhost -import-path tests -proto greeter.proto -d '{"name":"Bob"}' 127.0.0.1:$SPORT demo.v1.Greeter/SayHello 2>&1)"
        kill "$STSRV" 2>/dev/null
        if echo "$SOUT" | grep -q "Hello, Bob"; then
            echo -e "${GREEN}[PASS]${NC} grpcurl over TLS → \"Hello, Bob\""
        else
            echo -e "${RED}[FAIL]${NC} TLS interop: $SOUT"; FAILED=1
        fi

        # typed Amalgame client over TLS ↔ typed TLS server
        echo -e "\n── typed TLS e2e: GreeterClient.DialTls ↔ ServeHttps ──"
        CPORT=50103
        NS_GRPC_PORT=$CPORT NS_GRPC_CERT="$BUILD_DIR/g.crt" NS_GRPC_KEY="$BUILD_DIR/g.key" "$BUILD_DIR/greeter_server" >/dev/null 2>&1 & CTSRV=$!
        sleep 0.8
        CTOUT="$(NS_GRPC_PORT=$CPORT NS_GRPC_TLS=1 timeout 15 "$BUILD_DIR/greeter_client")"; echo "$CTOUT"
        kill "$CTSRV" 2>/dev/null
        echo "$CTOUT" | grep -q "\[PASS\]" || FAILED=1
        echo "$CTOUT" | grep -q "\[FAIL\]" && FAILED=1
    fi
fi

# ── end-to-end: AM gRPC client ↔ AM gRPC server over TCP (h2c) ─────
echo -e "\n── e2e: GrpcClient ↔ ServeH2c (h2c) ──"
"$AMC" -o "$BUILD_DIR/e2e_srv" examples/grpc_h2c_server.am --external facade.am >/dev/null 2>&1
gcc -O2 $INCS "$BUILD_DIR/e2e_srv.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nh.o" $LIBS -o "$BUILD_DIR/e2e_srv" 2>"$BUILD_DIR/e" \
    || { echo -e "${RED}e2e server build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
"$AMC" -o "$BUILD_DIR/e2e_cli" examples/grpc_h2c_client.am --external facade.am >/dev/null 2>&1
gcc -O2 $INCS "$BUILD_DIR/e2e_cli.c" "$BUILD_DIR/facade.o" "$BUILD_DIR/nh.o" $LIBS -o "$BUILD_DIR/e2e_cli" 2>"$BUILD_DIR/e" \
    || { echo -e "${RED}e2e client build failed${NC}"; cat "$BUILD_DIR/e"; exit 1; }
E2E_PORT=50096
NS_GRPC_PORT=$E2E_PORT "$BUILD_DIR/e2e_srv" >/dev/null 2>&1 & E2E_SRV=$!
sleep 0.6
E2E_OUT="$(NS_GRPC_PORT=$E2E_PORT timeout 15 "$BUILD_DIR/e2e_cli")"; echo "$E2E_OUT"
kill "$E2E_SRV" 2>/dev/null
echo "$E2E_OUT" | grep -q "\[FAIL\]" && FAILED=1
echo "$E2E_OUT" | grep -q "\[PASS\]" || FAILED=1

echo ""
if [ "$FAILED" -eq 0 ]; then echo -e "${GREEN}All tests passed${NC}"; else echo -e "${RED}FAILED${NC}"; exit 1; fi
