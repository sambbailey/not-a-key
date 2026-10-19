#!/bin/sh
# Regenerates TeslaKit/Proto/*.pb.swift from Protos/*.proto.
# Requires protoc and protoc-gen-swift 1.39.0 (brew install protobuf swift-protobuf).
set -eu
cd "$(dirname "$0")/.."
rm -f TeslaKit/Proto/*.pb.swift
protoc -I Protos --swift_out=TeslaKit/Proto --swift_opt=Visibility=Public Protos/*.proto
