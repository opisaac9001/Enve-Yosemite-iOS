#!/bin/sh
# Xcode Cloud runs this after cloning. The project is gitignored, so generate it before the build resolves it.
set -eu

brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
xcodegen generate
