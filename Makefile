CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden
# Per Mac: the repo lives in Dropbox, and each Mac's signed build is its own.
BUILD := build/$(shell hostname -s)
DYLIB := $(BUILD)/libsk-icloud-keychain.dylib

HELPER_APP := $(BUILD)/xcode/Build/Products/Release/sk-icloud-keychain.app
# Same path on every Mac, so a Dropbox-shared ~/.ssh/config works everywhere.
INSTALL_DIR ?= /Applications
PROVIDER := $(INSTALL_DIR)/sk-icloud-keychain.app/Contents/Frameworks/libsk-icloud-keychain.dylib
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all clean test helper test-helper install uninstall

all: $(DYLIB) helper

$(DYLIB): provider/sk-icloud-keychain.c provider/sk-api.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -dynamiclib -install_name @rpath/libsk-icloud-keychain.dylib -o $@ $<

# Signs with team FJYY683YHH (Apple Development). The destination must be
# this Mac, not "generic/platform=macOS": only then does
# -allowProvisioningDeviceRegistration add this Mac to the profile.
helper:
	cd helper && xcodebuild -project SKICloudKeychain.xcodeproj -scheme sk-icloud-keychain \
	    -configuration Release -destination "platform=macOS,arch=$(shell uname -m)" -derivedDataPath ../$(BUILD)/xcode \
	    -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build

# The app holds both the helper and the provider dylib. Keys stay in
# iCloud Keychain, so uninstalling does not delete them.
# LaunchServices keeps the old record of a replaced bundle (and registers
# the build product too), so the Touch ID dialog can show a stale icon.
# Re-register the installed copy and drop the build product's record.
install: helper
	rm -rf "$(INSTALL_DIR)/sk-icloud-keychain.app"
	ditto "$(HELPER_APP)" "$(INSTALL_DIR)/sk-icloud-keychain.app"
	codesign --verify --strict "$(INSTALL_DIR)/sk-icloud-keychain.app"
	$(LSREGISTER) -u "$(HELPER_APP)"
	$(LSREGISTER) -f "$(INSTALL_DIR)/sk-icloud-keychain.app"
	@echo "SecurityKeyProvider $(PROVIDER)"

uninstall:
	rm -rf "$(INSTALL_DIR)/sk-icloud-keychain.app"

test: $(DYLIB) test-helper
	./tests/load-provider.sh $(DYLIB)

test-helper:
	cd helper && swift test --scratch-path ../$(BUILD)/swiftpm

clean:
	rm -rf $(BUILD)
