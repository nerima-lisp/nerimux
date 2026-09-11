{
  description = "nerimux, a git-worktree workspace multiplexer in Common Lisp";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Pin sibling packages to release tags so upstream branch changes cannot
    # alter this repository's inputs without a lock-file update.
    # Share nixpkgs with the sibling flake to avoid duplicate inputs.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      # cl-weave's transitive development tool follows the project release.
      inputs.paredit-cli.url = "github:nerima-lisp/paredit-cli/v1.6.2";
    };
    paredit-cli = {
      url = "github:nerima-lisp/paredit-cli/v1.6.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Consume sibling packages as source checkouts and register them with ASDF.
    # A non-flake input has no nested nixpkgs to follow.
    cl-cli = {
      url = "github:nerima-lisp/cl-cli/v1.3.0";
      flake = false;
    };
    cl-date-kit = {
      url = "github:nerima-lisp/cl-date-kit/v1.0.0";
      flake = false;
    };
    cl-parser-kit = {
      url = "github:nerima-lisp/cl-parser-kit/v1.1.1";
      flake = false;
    };
    cl-tty-kit = {
      url = "github:nerima-lisp/cl-tty-kit/v1.6.1";
      flake = false;
    };
    cl-process-kit = {
      url = "github:nerima-lisp/cl-process-kit/v3.2.0";
      flake = false;
    };
    cl-log-kit = {
      # Required by cl-process-kit's ASDF system.
      url = "github:nerima-lisp/cl-log-kit/v2.2.0";
      flake = false;
    };
    cl-concurrent-kit = {
      url = "github:nerima-lisp/cl-concurrent-kit/v0.6.1";
      flake = false;
    };
    cl-boundary-kit = {
      # Required by cl-concurrent-kit's ASDF system.
      url = "github:nerima-lisp/cl-boundary-kit/v2.3.0";
      flake = false;
    };
    cl-regex-kit = {
      url = "github:nerima-lisp/cl-regex-kit/v2.0.0";
      flake = false;
    };
    cl-codec-kit = {
      url = "github:nerima-lisp/cl-codec-kit/v0.5.0";
      flake = false;
    };
    cl-host-kit = {
      url = "github:nerima-lisp/cl-host-kit/v0.3.1";
      flake = false;
    };
    cl-tui-kit = {
      url = "github:nerima-lisp/cl-tui-kit/v4.1.3";
      flake = false;
    };
    cl-vcs-kit = {
      url = "github:nerima-lisp/cl-vcs-kit/v0.2.0";
      flake = false;
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-weave,
      paredit-cli,
      cl-cli,
      cl-date-kit,
      cl-parser-kit,
      cl-tty-kit,
      cl-process-kit,
      cl-log-kit,
      cl-concurrent-kit,
      cl-boundary-kit,
      cl-regex-kit,
      cl-codec-kit,
      cl-host-kit,
      cl-tui-kit,
      cl-vcs-kit,
      treefmt-nix,
      ...
    }:
    let
      # CI targets x86_64-linux; local development targets aarch64-darwin.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Do not hide broken packages. Restore allowBroken only with a package that
      # requires it.
      pkgsFor = system: import nixpkgs { inherit system; };

      # SBCL's Darwin PTYs need a session and controlling terminal for job-control shells.
      sbclFor =
        system:
        let
          pkgs = pkgsFor system;
          controllingPtyPatch = pkgs.writeText "sbcl-darwin-controlling-pty.patch" ''
            diff --git a/src/runtime/run-program.c b/src/runtime/run-program.c
            --- a/src/runtime/run-program.c
            +++ b/src/runtime/run-program.c
            @@ -95,9 +95,25 @@
                 if ((fd = open(pty_name, O_RDWR, 0)) == -1)
                     return (-1);
            +#ifdef LISP_FEATURE_DARWIN
            +    if (ioctl(fd, TIOCSCTTY, 0) < 0 ||
            +        dup2(fd, 0) < 0 ||
            +        dup2(fd, 1) < 0 ||
            +        dup2(fd, 2) < 0 ||
            +        !set_noecho(0)) {
            +        int saved_errno = errno;
            +        if (fd > 2)
            +            close(fd);
            +        errno = saved_errno;
            +        return -1;
            +    }
            +    if (fd > 2)
            +        close(fd);
            +#else
                 dup2(fd, 0);
                 set_noecho(0);
                 dup2(fd, 1);
                 dup2(fd, 2);
                 close(fd);
            +#endif
                 return (0);
             }
            @@ -327,6 +343,12 @@
                 /* Put us in our own process group, but only if we need not
                  * share stdin with our parent. In the latter case we claim
                  * control of the terminal. */
            +#ifdef LISP_FEATURE_DARWIN
            +    if (pty_name) {
            +        if (setsid() < 0)
            +            goto child_setup_failed;
            +    } else
            +#endif
                 if (sin >= 0) {
             #ifdef LISP_FEATURE_OPENBSD
                   setsid();
            @@ -348,7 +370,12 @@
                 /* If we are supposed to be part of some other pty, go for it. */
            -    if (pty_name)
            +    if (pty_name) {
            +#ifdef LISP_FEATURE_DARWIN
            +        if (set_pty(pty_name) < 0)
            +            goto child_setup_failed;
            +#else
                     set_pty(pty_name);
            -    else {
            +#endif
            +    } else {
                 /* Set up stdin, stdout, and stderr */
                 if (sin >= 0)
                     dup2(sin, 0);
            @@ -385,3 +412,6 @@
            +#ifdef LISP_FEATURE_DARWIN
            +child_setup_failed:
            +#endif
                 /* When exec or chdir fails and channel is available, send the errno value. */
                 if (-1 != channel[1]) {
                     int our_errno = errno;
          '';
        in
        if pkgs.stdenv.hostPlatform.isDarwin then
          pkgs.sbcl.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ controllingPtyPatch ];
          })
        else
          pkgs.sbcl;

      # Release tags are checked against the version in nerimux.asd.
      version =
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile ./nerimux.asd);
          versionLine = builtins.head (
            builtins.filter (line: builtins.match "[[:space:]]*:version \"[^\"]*\"" line != null) lines
          );
        in
        builtins.head (builtins.match "[[:space:]]*:version \"([^\"]*)\"" versionLine);

      patchedClTuiKit =
        system:
        let
          pkgs = pkgsFor system;
          boundedDatumPatch = pkgs.writeText "cl-tui-kit-bounded-datum.patch" ''
            diff --git a/src/list.lisp b/src/list.lisp
            --- a/src/list.lisp
            +++ b/src/list.lisp
            @@ -36,5 +36,6 @@
             (defun %validated-model-count (value name)
               (unless (and (integerp value) (>= value 0))
            -    (error 'callback-contract-error :callback name :value (bounded-datum value)
            +    (error 'callback-contract-error :callback name
            +           :value (cl-tui-kit/core::bounded-datum value)
                        :detail (format nil "~A must return a non-negative integer." name)))
               value)
          '';
        in
        pkgs.applyPatches {
          name = "cl-tui-kit-${cl-tui-kit.shortRev or "v4.1.3"}";
          src = cl-tui-kit;
          patches = [ boundedDatumPatch ];
        };

      siblingRepos = system: [
        cl-weave
        cl-cli
        cl-date-kit
        cl-parser-kit
        cl-tty-kit
        cl-process-kit
        cl-log-kit
        cl-boundary-kit
        cl-concurrent-kit
        cl-regex-kit
        cl-codec-kit
        cl-host-kit
        (patchedClTuiKit system)
        cl-vcs-kit
      ];

      # Source roots read by run-tests.lisp and shared by checks, apps, and the
      # devShell.
      siblingRegistry = system: nixpkgs.lib.concatStringsSep ":" (map toString (siblingRepos system));

      siblingRegistryPushEvals =
        system:
        nixpkgs.lib.concatMapStringsSep " " (
          repo: ''--eval "(push (truename \"${repo}/\") asdf:*central-registry*)"''
        ) (siblingRepos system);

      # ASDF does not recurse through the central registry, so register each
      # in-repo package directory for test and development invocations.
      packagesRegistryPushEval = ''--eval "(dolist (d (directory \"packages/*/\")) (push d asdf:*central-registry*))"'';

      # Runtime dependencies are ASDF sibling sources, not nixpkgs Lisp
      # packages, so the build uses plain SBCL.

      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule (pkgsFor system) {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );

      # Copy the read-only flake source before running a suite that compiles in place.
      mkTestCheck =
        system: name: testSystem:
        let
          pkgs = pkgsFor system;
          sbcl = sbclFor system;
        in
        pkgs.runCommand name
          {
            nativeBuildInputs = [
              sbcl
              pkgs.coreutils
              pkgs.git
            ];
            NERIMUX_SIBLING_REGISTRY = siblingRegistry system;
            NERIMUX_TEST_SYSTEM = testSystem;
          }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cp -r ${self} ./src-tree
            chmod -R u+w ./src-tree
            cd ./src-tree
            # Darwin's builder needs an explicit heap.
            ${pkgs.coreutils}/bin/timeout --signal=TERM --kill-after=30s 2700 \
              ${sbcl}/bin/sbcl --dynamic-space-size 4096 --no-sysinit \
              --no-userinit --disable-debugger --script run-tests.lisp
            ${pkgs.coreutils}/bin/touch "$out"
          '';
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          sbcl = sbclFor system;
        in
        rec {
          nerimux = pkgs.stdenv.mkDerivation {
            pname = "nerimux";
            inherit version;
            src = self;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = [ sbcl ];

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR

              # save-lisp-and-die without :executable avoids the macOS-specific
              # issue where embedded-core binaries fail to find sbcl.core at
              # runtime.
              ${sbcl}/bin/sbcl \
                --no-sysinit \
                --no-userinit \
                --eval "(require :asdf)" \
                --eval "(sb-impl::module-provide-contrib :sb-posix)" \
                --eval "(asdf:register-preloaded-system \"sb-posix\")" \
                --eval "(setf asdf/source-registry:*source-registry* (make-hash-table :test (function equal)))" \
                --eval "(push (truename \".\") asdf:*central-registry*)" \
                ${siblingRegistryPushEvals system} \
                ${packagesRegistryPushEval} \
                --eval "(asdf:load-system \"nerimux\")" \
                --eval "(sb-ext:save-lisp-and-die \"nerimux.core\"
                           :toplevel #'nerimux:main
                           :executable nil
                           :compression t)" \
                --quit
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib/nerimux $out/bin

              cp nerimux.core $out/lib/nerimux/

              # --noinform is a C-runtime option; it must precede --core.
              # --no-sysinit/userinit are Lisp options; they follow --core.
              makeWrapper ${sbcl}/bin/sbcl $out/bin/nerimux \
                --add-flags "--noinform --core $out/lib/nerimux/nerimux.core --no-sysinit --no-userinit"
              runHook postInstall
            '';

            meta = {
              description = "A git-worktree workspace multiplexer in Common Lisp";
              homepage = "https://github.com/nerima-lisp/nerimux";
              license = pkgs.lib.licenses.mit;
              mainProgram = "nerimux";
            };
          };

          default = nerimux;

          # Build the published docs offline with strict link and nav checks.
          # docs/notes contains unpublished working records.
          docs = pkgs.stdenvNoCC.mkDerivation {
            pname = "nerimux-docs";
            inherit version;
            src = pkgs.lib.fileset.toSource {
              root = ./docs;
              fileset = pkgs.lib.fileset.unions [
                ./docs/mkdocs.yml
                ./docs/src
              ];
            };
            nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
            buildPhase = ''
              runHook preBuild
              mkdocs build --strict --config-file mkdocs.yml --site-dir "$out"
              runHook postBuild
            '';
            dontInstall = true;
            meta = {
              description = "Rendered MkDocs (Material) documentation for nerimux";
              homepage = "https://github.com/nerima-lisp/nerimux";
              license = pkgs.lib.licenses.mit;
            };
          };

          # Hermetic sb-cover report for CI. Use a writable copy because coverage
          # compilation writes fasls and the flake source is read-only.
          coverage-report =
            pkgs.runCommand "nerimux-coverage-report"
              {
                nativeBuildInputs = [
                  sbcl
                  pkgs.coreutils
                  pkgs.git
                ];
                NERIMUX_SIBLING_REGISTRY = siblingRegistry system;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                cp -r ${self} ./src-tree
                chmod -R u+w ./src-tree
                cd ./src-tree
                ${pkgs.coreutils}/bin/timeout --signal=TERM --kill-after=30s 2700 \
                  ${sbcl}/bin/sbcl --dynamic-space-size 4096 --no-sysinit \
                  --no-userinit --disable-debugger --script scripts/coverage.lisp \
                  ./coverage-report
                mkdir -p "$out"
                cp -R ./coverage-report/. "$out/"
              '';
        }
      );

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # Separate attributes let Nix build static checks in parallel.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          sbcl = sbclFor system;

          # Static checks only read the tree, so they do not need a writable copy.
          mkStaticCheck =
            name: cmd:
            pkgs.runCommand name
              {
                nativeBuildInputs = [
                  sbcl
                  pkgs.perl
                ];
              }
              ''
                cd ${self}
                ${cmd}
                touch "$out"
              '';
        in
        {
          # Sandbox checks omit real-PTY cases because /dev/ptmx is unavailable.
          default = mkTestCheck system "nerimux-tests" "nerimux/test";

          formatting = treefmtEval.${system}.config.build.check self;

          # Build documentation with mkdocs --strict so broken links fail the check.
          docs = self.packages.${system}.docs;

          read-check = mkStaticCheck "read-check" "${sbcl}/bin/sbcl --script scripts/checks/read-check.lisp";

          manifest-check = mkStaticCheck "manifest-check" "${sbcl}/bin/sbcl --script scripts/checks/manifest-check.lisp";

          export-check = mkStaticCheck "export-check" "perl scripts/checks/export-check.pl .";

          internal-call-check = mkStaticCheck "internal-call-check" "perl scripts/checks/internal-call-check.pl .";

          suite-structure-check = mkStaticCheck "suite-structure-check" "perl scripts/checks/suite-structure-check.pl .";
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          sbcl = sbclFor system;

          test = pkgs.writeShellApplication {
            name = "nerimux-test";
            runtimeInputs = [
              sbcl
              pkgs.coreutils
              pkgs.git
            ];
            text = ''
              export NERIMUX_SIBLING_REGISTRY="${siblingRegistry system}"
              export NERIMUX_TEST_SYSTEM="''${NERIMUX_TEST_SYSTEM:-nerimux/test}"
              # The suite compiles in place, so copy the read-only source first.
              work="$(mktemp -d)"
              trap 'rm -rf "$work"' EXIT
              mkdir -p "$work/home"
              export HOME="$work/home"
              cp -r ${self} "$work/src-tree"
              chmod -R u+w "$work/src-tree"
              cd "$work/src-tree"
              # No exec: it would replace the shell and the EXIT trap above
              # would never run, leaking $work on every invocation.
              timeout --signal=TERM --kill-after=30s 2700 \
                sbcl --dynamic-space-size 4096 --no-sysinit --no-userinit \
                --disable-debugger --script run-tests.lisp
            '';
          };

          testPty = pkgs.writeShellApplication {
            name = "nerimux-test-pty";
            runtimeInputs = [
              sbcl
              pkgs.coreutils
              pkgs.git
            ];
            text = ''
              export NERIMUX_SIBLING_REGISTRY="${siblingRegistry system}"
              export NERIMUX_TEST_SYSTEM="nerimux/pty-test"
              # A caller's interactive shell can exit before the test sends its
              # command, so the PTY suite always uses /bin/sh.
              export SHELL=/bin/sh
              work="$(mktemp -d)"
              trap 'rm -rf "$work"' EXIT
              mkdir -p "$work/home"
              export HOME="$work/home"
              cp -r ${self} "$work/src-tree"
              chmod -R u+w "$work/src-tree"
              cd "$work/src-tree"
              # No exec: it would replace the shell and the EXIT trap above
              # would never run, leaking $work on every invocation.
              timeout --signal=TERM --kill-after=30s 2700 \
                sbcl --dynamic-space-size 4096 --no-sysinit --no-userinit \
                --disable-debugger --script run-tests.lisp
            '';
          };

          # End-to-end smoke uses the built binary and loads ASDF output under a
          # temporary HOME, so the flake source remains read-only.
          e2e = pkgs.writeShellApplication {
            name = "nerimux-e2e";
            runtimeInputs = [
              sbcl
              pkgs.coreutils
              pkgs.git
            ];
            text = ''
              export NERIMUX_SIBLING_REGISTRY="${siblingRegistry system}"
              home="$(mktemp -d)"
              trap 'rm -rf "$home"' EXIT
              export HOME="$home"
              cd ${self}
              sbcl --dynamic-space-size 4096 --script tests/e2e/e2e-smoke.lisp \
                "${self.packages.${system}.nerimux}/bin/nerimux" "$@"
            '';
          };
        in
        {
          # `nix run .` starts the multiplexer, which is what the README
          # advertises; the test runner is reachable as `nix run .#test`.
          default = {
            type = "app";
            program = "${self.packages.${system}.nerimux}/bin/nerimux";
            meta = {
              description = "nerimux, a git-worktree workspace multiplexer in Common Lisp";
              mainProgram = "nerimux";
            };
          };

          test = {
            type = "app";
            program = "${test}/bin/nerimux-test";
            meta = {
              description = "Run nerimux's test suite (NERIMUX_TEST_SYSTEM selects which one)";
              mainProgram = "nerimux-test";
            };
          };

          # The sandbox lacks /dev/ptmx, so real-PTY runs as an app.
          test-pty = {
            type = "app";
            program = "${testPty}/bin/nerimux-test-pty";
            meta = {
              description = "Run nerimux's real-PTY suite (needs /dev/ptmx)";
              mainProgram = "nerimux-test-pty";
            };
          };

          # The attach scenario needs a real PTY, so this remains an app.
          e2e = {
            type = "app";
            program = "${e2e}/bin/nerimux-e2e";
            meta = {
              description = "Run nerimux's end-to-end smoke scenarios (needs /dev/ptmx)";
              mainProgram = "nerimux-e2e";
            };
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          sbcl = sbclFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              sbcl
              paredit-cli.packages.${system}.default
              (pkgs.writeShellScriptBin "paredit-cli" ''
                exec ${paredit-cli.packages.${system}.default}/bin/paredit "$@"
              '')
              pkgs.coreutils
              pkgs.python3Packages.mkdocs-material
            ];
            NERIMUX_SIBLING_REGISTRY = siblingRegistry system;
            shellHook = ''
              # Register the same ASDF roots used by the checks for interactive
              # sessions. Loading nerimux.asd directly does not set this up.
              nerimux-sbcl() {
                sbcl --dynamic-space-size 4096 --no-sysinit --no-userinit \
                     --disable-debugger --eval "(require :asdf)" \
                     --eval "(sb-impl::module-provide-contrib :sb-posix)" \
                     --eval "(asdf:register-preloaded-system \"sb-posix\")" \
                     --eval "(setf asdf/source-registry:*source-registry* (make-hash-table :test (function equal)))" \
                     --eval "(push (truename \".\") asdf:*central-registry*)" \
                     ${siblingRegistryPushEvals system} \
                     ${packagesRegistryPushEval} \
                     "$@"
              }

              # Use the same coverage recipe as the hermetic Nix report.
              nerimux-coverage() {
                report_dir="''${1:-./coverage-report}/"
                timeout --signal=TERM --kill-after=30s 2700 \
                  sbcl --dynamic-space-size 4096 --no-sysinit --no-userinit \
                  --disable-debugger --script scripts/coverage.lisp "$report_dir"
                echo "Coverage report: $report_dir" "cover-index.html"
              }

              paredit-cli() {
                paredit "$@"
              }

              echo "nerimux dev shell"
              echo "  run tests:       sbcl --dynamic-space-size 4096 --script run-tests.lisp"
              echo "  load in a REPL:  nerimux-sbcl --eval '(asdf:load-system \"nerimux\")'"
              echo "  coverage report: nerimux-coverage [output-dir]"
            '';
          };
        }
      );
    };
}
