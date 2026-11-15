THEOS ?= $(CURDIR)/.tooling/theos
TARGET := iphone:clang:16.5:16.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless
DEBUG := 0
FINALPACKAGE := 1

# Host LLVM toolchain validated on this Linux machine. SDK's archive label is
# 16.5; its internal version is 16.4 (see docs/BUILD.md).
TARGET_CC := /usr/bin/clang
TARGET_CXX := /usr/bin/clang++
TARGET_LD := /usr/bin/clang
TARGET_STRIP := /usr/bin/llvm-strip
TARGET_CODESIGN := $(CURDIR)/.tooling/ldid/ldid

include $(THEOS)/makefiles/common.mk

TOOL_NAME := location-lab
location-lab_FILES := engine/ILLFixedLocationEngine.m console/main.m
location-lab_CFLAGS := -fobjc-arc -fblocks -Wall -Wextra -Werror -I$(CURDIR)/engine
location-lab_LDFLAGS := --ld-path=/usr/bin/ld64.lld -mlinker-version=820
location-lab_FRAMEWORKS := Foundation CoreLocation
location-lab_CODESIGN_FLAGS := -S$(CURDIR)/console/entitlements.plist
location-lab_INSTALL_PATH := /usr/bin

include $(THEOS_MAKE_PATH)/tool.mk
