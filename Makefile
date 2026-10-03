.PHONY: setup core ipa-unsigned verify-ipa test-go test-scripts

# 版本不足时直接失败，不让 Go 自动下载另一套编译器绕过环境声明。
export GOTOOLCHAIN := local

# 保留旧入口默认检查签名的契约。值经环境传递，避免路径被当作 shell 代码。
IPA_MODE ?= signed
override IPA := $(value IPA)
override IPA_MODE := $(value IPA_MODE)
export IPA IPA_MODE

setup:
	./Scripts/setup.sh

core:
	./Scripts/build-core.sh

ipa-unsigned:
	./Scripts/build-unsigned-ipa.sh

verify-ipa:
	@test -n "$$IPA" || (echo 'Usage: make verify-ipa IPA=/path/to/app.ipa [IPA_MODE=unsigned|signed]' >&2; exit 2)
	./Scripts/verify-ipa.sh --"$$IPA_MODE" "$$IPA"

test-go:
	cd Core && go mod download && go mod verify && go test -race -count=1 -timeout=5m -v ./... && go vet ./...

test-scripts:
	@set -eu; for script in build.sh Scripts/*.sh Tests/*_test.sh; do bash -n "$$script"; done
	@set -eu; for script in Tests/*_test.sh; do bash "$$script"; done
	node --test Tests/wloc_scripts_behavior_test.cjs
