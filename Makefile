# AIUsageTracker — convenience targets

.PHONY: build app run clean

# Compile (debug) and verify it builds.
build:
	swift build

# Assemble a runnable .app bundle (release).
app:
	./scripts/build-app.sh release

# Build the bundle and launch the menu-bar app.
run: app
	open ".build/bundle/AIUsageTracker.app"

clean:
	swift package clean
	rm -rf .build/bundle
