# Cross-compile a minimal espeak-ng for Kobo (armv7l)
# Usage: nix-build cross-build-espeak.nix --no-out-link
# Then: ls $(nix-build cross-build-espeak.nix --no-out-link)/bin/
let
  # Pin nixpkgs to a known-good commit (nixpkgs-unstable, 2026-03-22)
  # to avoid CI breakage from channel updates
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {
    overlays = [
      # libadwaita's test-preferences-group test crashes with SIGTRAP in
      # headless CI environments (no display server). It is pulled in
      # transitively via alsa-plugins -> ffmpeg -> sdl3 -> zenity.
      (self: super: {
        libadwaita = super.libadwaita.overrideAttrs (old: {
          doCheck = false;
        });
        # ibus 1.5.33's Makefile installs gi/overrides/IBus.py from two
        # sections that race under make -j: the loser hits "File exists"
        # and the install fails. Serial install is deterministic. The
        # race only bites on a cold CI nix store, where the whole
        # alsa-plugins -> ffmpeg -> sdl3 -> zenity -> ibus chain rebuilds
        # from source (armv7 outputs are not on the binary cache).
        ibus = super.ibus.overrideAttrs (old: {
          enableParallelInstalling = false;
        });
      })
    ];
  };
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
(crossPkgs.espeak-ng.override {
  # Disable all the heavy/failing optional dependencies
  pcaudiolibSupport = false;   # No audio output lib (we write to wav files)
  sonicSupport = false;        # No sonic speed adjustment
  mbrolaSupport = true;        # Enable MBROLA voice support
}).overrideAttrs (old: {
  # Remove the postInstall that wraps with alsa-plugins (fails cross-compile
  # and unnecessary for Kobo where we only use --stdout / -w file.wav)
  postInstall = "";

  # Patch mbrowrap.c to fix MBROLA voice synthesis on Kobo.
  # The bundled glibc dynamic linker keeps internal file descriptors open.
  # mbrowrap.c's aggressive close loop (for i = p_stderr[1]; i > 2; i--)
  # closes these fds, corrupting libc state and causing execlp("mbrola")
  # to fail with ENOENT even though the binary exists in PATH.
  # We replace the loop with explicit closes of only the parent's pipe ends.
  #
  # Also revert the nixpkgs mbrola.patch changes:
  # 1. Restore execlp("mbrola") so PATH lookup works (the nixpkgs patch uses
  #    @mbrola/bin/mbrola@ which CMake fails to substitute when mbrola is not
  #    found at configure time, leaving a literal placeholder in the binary).
  # 2. Restore the original voice path %s/mbrola/%s so voice databases are
  #    found relative to ESPEAK_DATA_PATH on the device.
  postPatch = (old.postPatch or "") + ''
    awk '
      /for \(i = p_stderr\[1\]; i > 2; i--\)/ {
        print "\t\tif (p_stdin[1] > 2) close(p_stdin[1]);"
        print "\t\tif (p_stdout[0] > 2) close(p_stdout[0]);"
        print "\t\tif (p_stderr[0] > 2) close(p_stderr[0]);"
        getline
        next
      }
      { print }
    ' src/libespeak-ng/mbrowrap.c > mbrowrap.c.tmp && mv mbrowrap.c.tmp src/libespeak-ng/mbrowrap.c

    # Revert nixpkgs mbrola.patch: restore original execlp path
    sed -i 's/execlp("@mbrola\/bin\/mbrola@"/execlp("mbrola"/' src/libespeak-ng/mbrowrap.c

    # Revert nixpkgs mbrola.patch: restore original voice lookup path
    sed -i 's|sprintf(path, "%s//nix/store/[^"]*/%s"|sprintf(path, "%s/mbrola/%s"|' src/libespeak-ng/synth_mbrola.c

    # Always copy MBROLA voice stubs (voices/mb) regardless of HAVE_MBROLA.
    # CMake skips them when mbrola is not found at configure time.
    sed -i 's/if (HAVE_MBROLA AND USE_MBROLA)/if (USE_MBROLA)/' cmake/data.cmake

    # Fix mbrola_is_idle() buffer too small for wrapped process name.
    # When mbrola is run through the bundled ld-linux linker, /proc/PID/stat
    # shows the process name as "(ld-linux-armhf.so.3)" (24 chars). The
    # original 20-byte buffer doesn't include the closing ')', so
    # mbrola_is_idle() always returns false, causing repeated 5-second stalls.
    sed -i 's/char buffer\[20\]; \/\/ looking for "12345 (mbrola) S" so 20 is plenty/char buffer[64]; \/\/ was 20; need 64 for "(ld-linux-armhf.so.3)"/' src/libespeak-ng/mbrowrap.c
    sed -i 's/if (read(mbr_proc_stat, buffer, sizeof(buffer)) != sizeof(buffer))/if (read(mbr_proc_stat, buffer, sizeof(buffer)) <= 0)/' src/libespeak-ng/mbrowrap.c
  '';
})
