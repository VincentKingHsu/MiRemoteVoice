# MiRemoteVoice HAL proof of concept

This is a local, reversible experiment to learn whether Doubao only filters
CoreAudio devices whose transport type is `virtual`.

The build script:

1. copies the installed `BlackHole2ch.driver` into this folder;
2. gives the copy a distinct bundle ID, factory UUID, device UID, model UID,
   box name, and display name;
3. leaves the driver's outer Box transport as `virt`, but changes the actual
   audio Device transport to `usb ` in both Intel and Apple Silicon slices;
4. applies an ad-hoc local signature.

It does not modify the installed BlackHole driver. The generated bundle is:

`build/MiRemoteVoice.driver`

This binary-patching method is only for the shortest possible feasibility
test. If Doubao accepts the device, the maintainable next step is a source
build with the same identifiers and transport setting.

`install-poc.sh` installs only the new side-by-side bundle and refuses to
overwrite an existing copy. `uninstall-poc.sh` removes only that proof-of-
concept bundle. Both require administrator privileges.
