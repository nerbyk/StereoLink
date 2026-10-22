# Shortcuts for working on the mod. The real work is in tools/*.ps1, so CI and people without
# make run the same scripts. On Windows: `winget install ezwinports.make`.

PS := powershell -NoProfile -ExecutionPolicy Bypass -File
PSC := powershell -NoProfile -Command

.PHONY: help lint pack link fixtures release clean

help:
	@$(PSC) "'make lint                   luacheck the Lua code', 'make pack                   build dist/stereo_link_<version>.zip from tools/release-files.txt', 'make link                   point the game mods/unpacked/stereo_link at mod/', 'make fixtures               download reference audio for the decoder test', 'make release VERSION=x.y.z  set the version, commit, tag and push; GitHub publishes the release', 'make clean                  remove dist/'"

lint:
	$(PS) tools/lint.ps1

pack:
	$(PS) tools/pack.ps1

link:
	$(PS) tools/link.ps1

fixtures:
	$(PS) tools/fetch-fixtures.ps1

release:
ifndef VERSION
	$(error usage: make release VERSION=x.y.z)
endif
	$(PS) tools/release.ps1 -Version $(VERSION) -Push

clean:
	$(PSC) "Remove-Item -Recurse -Force dist -ErrorAction SilentlyContinue"
