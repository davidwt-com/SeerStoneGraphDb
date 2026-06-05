REBAR3 ?= ./rebar3

.PHONY: all compile clean shell release rebar3 test-ct-parallel

all: compile

## Download rebar3 escript if not present
rebar3:
	curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o rebar3
	chmod +x rebar3

## Compile all apps
compile: $(REBAR3)
	$(REBAR3) compile

## Remove build artifacts
clean:
	$(REBAR3) clean
	rm -rf _build

## Start an interactive Erlang shell with all apps on the path
shell: $(REBAR3)
	$(REBAR3) shell

## Build a release
release: $(REBAR3)
	$(REBAR3) as prod release

## Run all Common Test suites concurrently (one isolated process per suite).
## Pass extra args via ARGS, e.g. `make test-ct-parallel ARGS="-j 8 rules class"`.
## (No $(REBAR3) prereq: the script validates rebar3/erl itself and a hard
## dep would re-download rebar3 on every run.)
test-ct-parallel:
	scripts/test-ct-parallel.sh $(ARGS)
