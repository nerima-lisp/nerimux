{
  description = "nerimux — a git-worktree workspace multiplexer in Common Lisp";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Sibling packages are ALWAYS pinned to a release tag. A bare
    # `github:nerima-lisp/cl-weave` follows that repo's default branch, so an
    # upstream push to main would break this repo's CI without warning.
    #
    # cl-weave is consumed as a flake, so it takes `inputs.nixpkgs.follows`:
    # without it it drags in its own nixpkgs, inflating flake.lock and
    # rebuilding the same derivations twice.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      # cl-weave's own flake still declares its paredit-cli dev input under the
      # pre-migration owner; pin it to the org (and to a tag) so no takeokunn/*
      # rev survives in our lock. paredit-cli is a transitive dev tool only and
      # is never linked into nerimux.
      inputs.paredit-cli.url = "github:nerima-lisp/paredit-cli/v1.6.2";
    };

    # `flake = false`: consumed as a plain source checkout, pushed onto ASDF's
    # central registry below rather than through each repo's own flake outputs.
    # This is the form DEPENDENCY_POLICY.md prescribes for sibling packages and
    # it keeps working regardless of whether a given sibling ships a flake.nix.
    #
    # A `flake = false` input has no inputs of its own, so it takes no
    # `follows` — there is no nested nixpkgs for it to duplicate. That is the
    # same goal `follows` serves for the two flake inputs above, reached a
    # different way, not an omission.
    cl-cli = {
      url = "github:nerima-lisp/cl-cli/v1.3.0";
      flake = false;
    };
    # Direct runtime dependency: cl-concurrent-kit's timeout API consumes
    # CL-DATE-KIT:DURATION values.
    cl-date-kit = {
      url = "github:nerima-lisp/cl-date-kit/v1.0.0";
      flake = false;
    };
    cl-parser-kit = {
      url = "github:nerima-lisp/cl-parser-kit/v1.1.1";
      flake = false;
    };
    cl-tty-kit = {
      # Provides the terminal-size ioctl and raw-mode fixes used by nerimux's
      # PTY layer, including arm64-safe ioctl marshalling.
      url = "github:nerima-lisp/cl-tty-kit/v1.6.1";
      flake = false;
    };
    cl-process-kit = {
      # Exports wait-for-input/select-fds, which the PTY process supervisor
      # calls directly.
      url = "github:nerima-lisp/cl-process-kit/v3.2.0";
      flake = false;
    };
    cl-log-kit = {
      # Transitive runtime dependency: cl-process-kit's ASDF system requires
      # this source even though nerimux does not call its API directly.
      url = "github:nerima-lisp/cl-log-kit/v2.2.0";
      flake = false;
    };
    cl-concurrent-kit = {
      # Supplies the threads, locks, condition variables and preemptive
      # WITH-TIMEOUT primitives used by the orchestration layer.
      url = "github:nerima-lisp/cl-concurrent-kit/v0.6.1";
      flake = false;
    };
    cl-boundary-kit = {
      # Transitive runtime dependency: cl-concurrent-kit's ASDF system requires
      # this source even though nerimux does not call its API directly.
      url = "github:nerima-lisp/cl-boundary-kit/v2.3.0";
      flake = false;
    };
    cl-regex-kit = {
      # Provides the compile-regex, scan, match, split and replace-all API used
      # by the command parser and format expansion code.
      url = "github:nerima-lisp/cl-regex-kit/v2.0.0";
      flake = false;
    };
    cl-codec-kit = {
      # From-scratch, babel-API-compatible codec: the 71 string<->octet call
      # sites in src/ and tests/ name cl-codec-kit:string-to-octets /
      # octets-to-string directly. Briefly routed through cl-host-kit instead;
      # re-pointed here on 2026-08-02 so the codec is named at its own call
      # sites rather than through a host-ops package.
      #
      # `:depends-on ()` — depth 0, so this input pulls in nothing else.
      # cl-tty-kit and cl-process-kit (both already inputs above) consume it
      # too, so one checkout serves all three.
      url = "github:nerima-lisp/cl-codec-kit/v0.5.0";
      flake = false;
    };
    cl-host-kit = {
      # Provides the pathname and host-string operations still used by the
      # bootstrap loader and environment parsing.
      url = "github:nerima-lisp/cl-host-kit/v0.3.1";
      flake = false;
    };
    cl-tui-kit = {
      # The headless surface/layout/backend boundary used by nerimux's
      # per-client renderer. Pin the API that exposes make-surface and the
      # ANSI backend used by the deterministic frame adapter.
      url = "github:nerima-lisp/cl-tui-kit/v4.1.3";
      flake = false;
    };
    cl-vcs-kit = {
      # ghq/repository/worktree discovery for the global picker. The adapter
      # keeps discovery off the UI thread while this source provides the
      # stable VCS observation API.
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
      # x86_64-linux is what CI gates; aarch64-darwin is the development
      # machine. Every per-system output -- packages, checks, apps AND devShells
      # -- comes from this one list, so leaving aarch64-darwin out takes `nix
      # build` and `nix develop` off the development machine as well. That trade
      # was made on 2026-08-01 and reverted on 2026-08-02; aarch64-darwin carries
      # no CI gate, which PACKAGE_STANDARD.md's "systems" section accepts
      # explicitly. aarch64-linux and x86_64-darwin are nobody's verification and
      # are not declared.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # No config.allowBroken. It was here for the Quicklisp-packaged Lisp
      # libraries this flake used to pull in — nixpkgs marks several sbcl-*
      # packages broken on darwin even though they are pure Lisp and load fine.
      # With bordeaux-threads and cl-ppcre gone, no sbcl-* package is referenced
      # at all, so the exemption would only be hiding a genuinely broken package
      # from us. Restore it only alongside a specific package that needs it.
      pkgsFor = system: import nixpkgs { inherit system; };

      # Single source of truth for the version: the `:version` form in
      # nerimux.asd. A release only ever edits the .asd, and every Nix package
      # follows automatically; release.yml refuses a tag that disagrees.
      #
      # Nix regexes are whole-string anchored and `.` never spans newlines, so
      # the version is extracted line-by-line rather than with one multi-line
      # match. The first match wins, which is the `nerimux` system — the test
      # systems repeat the same field further down the file.
      version =
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile ./nerimux.asd);
          versionLine = builtins.head (
            builtins.filter (line: builtins.match "[[:space:]]*:version \"[^\"]*\"" line != null) lines
          );
        in
        builtins.head (builtins.match "[[:space:]]*:version \"([^\"]*)\"" versionLine);

      # Every dogfooded sibling and its ASDF transitive sources are consumed
      # purely as source: each checkout goes on ASDF's central registry rather
      # than through nixpkgs Lisp packaging. This one list drives every SBCL
      # invocation below.
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

      # Colon-separated source roots, read by run-tests.lisp. Keeping the list
      # in one variable means the checks, the app and the devShell cannot drift
      # apart on which siblings they can see.
      siblingRegistry = system: nixpkgs.lib.concatStringsSep ":" (map toString (siblingRepos system));

      siblingRegistryPushEvals =
        system:
        nixpkgs.lib.concatMapStringsSep " " (
          repo: ''--eval "(push (truename \"${repo}/\") asdf:*central-registry*)"''
        ) (siblingRepos system);

      # Each in-repo unit lives in packages/<name>/ and carries its own .asd.
      # ASDF's central registry finds a .asd only in a directory registered
      # directly -- it does not recurse -- and the line above deliberately
      # empties the source registry, so without this a unit asked for by its own
      # name resolves to nothing. Kept in one binding for the same reason
      # siblingRegistry is: the build phase and the devShell cannot drift apart
      # on which units they can see.
      packagesRegistryPushEval = ''--eval "(dolist (d (directory \"packages/*/\")) (push d asdf:*central-registry*))"'';

      # Plain SBCL, with NO Quicklisp-packaged libraries wrapped around it.
      #
      # There is nothing left to wrap: nerimux has no external (non-org)
      # dependencies. Every name in nerimux.asd's :depends-on is a nerima-lisp
      # sibling, and siblings are consumed as SOURCE via siblingRegistry above,
      # not through nixpkgs Lisp packaging.
      #
      # The four that used to be here, and where each went:
      #   cffi             -> cl-process-kit / cl-tty-kit / sb-posix (2026-08-01)
      #   babel            -> cl-host-kit                            (2026-08-01)
      #   bordeaux-threads -> cl-concurrent-kit                      (2026-08-02)
      #   cl-ppcre         -> cl-regex-kit                            (2026-08-02)
      #
      # If a `pkgs.sbcl.withPackages` ever comes back here, nerimux.asd's
      # :depends-on must gain the matching external name in the same commit —
      # a mismatch between the two fails only at load time.

      # treefmt drives `nix fmt` and the `checks.<system>.formatting` gate.
      # Scope is Nix only: nixfmt is a low-diff formatter, whereas YAML
      # formatters mangle the GitHub Actions `on:` key and Markdown
      # reformatting would churn the whole docs tree.
      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule (pkgsFor system) {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );

      # One test derivation per suite. They differ only in which ASDF system
      # run-tests.lisp is pointed at, so the shape lives here once.
      #
      # The tree is copied and made writable because the suite compiles in
      # place; ${self} in the store is read-only.
      mkTestCheck =
        system: name: testSystem:
        let
          pkgs = pkgsFor system;
          sbcl = pkgs.sbcl;
        in
        pkgs.runCommand name
          {
            nativeBuildInputs = [
              sbcl
              pkgs.coreutils
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
            # Keep the heap explicit for the Darwin builder. This only controls
            # available address space; every test component is still loaded and the
            # test runner keeps its bounded 45-minute timeout.
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
          sbcl = pkgs.sbcl;
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

              # Compile all Lisp sources and save the image as a core file.
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

              # Wrap sbcl so users just call "nerimux".
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

          # Rendered documentation site (Material for MkDocs). Builds fully
          # offline: Material bundles all of its assets, so no network access is
          # required inside the Nix sandbox. --strict promotes broken links and
          # pages missing from the nav to build failures.
          #
          # The fileset covers docs/mkdocs.yml and docs/src only, so docs/notes/
          # (working records, deliberately unpublished) never reaches the site.
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

          # `nix build .#coverage-report` — a hermetic sb-cover report, for CI
          # to upload as an artifact without a local SBCL checkout. Mirrors
          # cl-tty-kit's package of the same name (scripts/coverage.lisp is
          # this project's counterpart to its scripts/coverage.lisp). Runs in
          # a writable copy with an isolated HOME, just like mkTestCheck, so
          # compilation artifacts cannot modify the source tree. The
          # interactive devShell helper below remains a separate local path.
          coverage-report =
            pkgs.runCommand "nerimux-coverage-report"
              {
                nativeBuildInputs = [
                  sbcl
                  pkgs.coreutils
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

      # `nix fmt` entry point.
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # Granularity lives here, NOT in extra GitHub Actions jobs: `nix flake
      # check` evaluates each attribute as its own derivation, in parallel, with
      # build caching. Add a check here rather than a job in ci.yml.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          sbcl = pkgs.sbcl;

          # scripts/checks/*.lisp and *.pl (see scripts/checks/README.md) need
          # neither ASDF nor a compile — each only reads the tree, so ${self}
          # is used directly rather than copied to a writable directory the
          # way mkTestCheck does for the suites that compile in place.
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
          # The full unit + integration suite. It spawns no pseudo-terminal: the
          # cases that do live in nerimux/pty-test and run as `nix run .#test-pty`,
          # because a sandbox has no /dev/ptmx and they would otherwise skip and be
          # counted as passes (R9.2).
          default = mkTestCheck system "nerimux-tests" "nerimux/test";

          # Fails `nix flake check` when any tracked file is unformatted,
          # turning the formatter into an enforced CI gate.
          formatting = treefmtEval.${system}.config.build.check self;

          # The docs package builds with `mkdocs --strict`, so a broken link or
          # a page missing from the nav fails here. Without this check the docs
          # are only ever built by the publish workflow, which runs after a
          # merge to main — so a break would surface as a failed deploy rather
          # than as a failed pull request.
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
          sbcl = pkgs.sbcl;

          test = pkgs.writeShellApplication {
            name = "nerimux-test";
            runtimeInputs = [
              sbcl
              pkgs.coreutils
            ];
            text = ''
              export NERIMUX_SIBLING_REGISTRY="${siblingRegistry system}"
              export NERIMUX_TEST_SYSTEM="''${NERIMUX_TEST_SYSTEM:-nerimux/test}"
              # Run against a writable copy for the same reason the checks do:
              # the suite compiles in place and ${self} is read-only.
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
            ];
            text = ''
              export NERIMUX_SIBLING_REGISTRY="${siblingRegistry system}"
              export NERIMUX_TEST_SYSTEM="nerimux/pty-test"
              # The PTY suite must use a deterministic POSIX shell.  A caller's
              # interactive SHELL can be fish (or another shell whose startup
              # hooks are not suitable for a non-login test PTY), making the
              # child exit before the test sends its command.
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

          # End-to-end smoke: headless server/kill scenarios plus the
          # real-PTY attach scenario (tests/e2e/e2e-smoke.lisp), driven against
          # the flake-built binary rather than a hand-run `nix build .`.
          # Runs read-only against ${self} in the store -- unlike test and
          # test-pty, e2e-smoke.lisp never compiles nerimux in place: the
          # headless scenarios only spawn the already-built binary as a
          # subprocess, and the attach scenario ASDF:LOAD-SYSTEMs nerimux,
          # which (like the package derivation above, flake.nix:314-368)
          # only ever writes its build output (fasls) under HOME's ASDF
          # cache, not next to the source. Only HOME needs a writable
          # scratch directory.
          e2e = pkgs.writeShellApplication {
            name = "nerimux-e2e";
            runtimeInputs = [
              sbcl
              pkgs.coreutils
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
              description = "nerimux — a git-worktree workspace multiplexer in Common Lisp";
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

          # The real-PTY suite. Deliberately an app and NOT a check: it needs
          # /dev/ptmx, which the sandbox a check builds in does not have. Running
          # it there would report a pass for cases that skipped, which is the
          # false green splitting the suite exists to prevent. Run it on a real
          # machine, by hand or from a job with a PTY available.
          test-pty = {
            type = "app";
            program = "${testPty}/bin/nerimux-test-pty";
            meta = {
              description = "Run nerimux's real-PTY suite (needs /dev/ptmx)";
              mainProgram = "nerimux-test-pty";
            };
          };

          # End-to-end smoke against the built binary. Also needs a real
          # PTY for the attach scenario, so it is an app, not a check, for
          # the same reason test-pty is.
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
          sbcl = pkgs.sbcl;
        in
        {
          default = pkgs.mkShell {
            packages = [
              sbcl
              pkgs.coreutils
              pkgs.python3Packages.mkdocs-material
            ];
            NERIMUX_SIBLING_REGISTRY = siblingRegistry system;
            shellHook = ''
              # Registers the central-registry entries the checks use, so an
              # interactive `sbcl` session finds nerimux and every sibling
              # library without repeating those --eval flags by hand. A plain
              # `sbcl --load nerimux.asd` fails: .asd files read `defsystem` in
              # whatever package ASDF put the reader in, which is only set up
              # correctly once `(require :asdf)` and the registry pushes below
              # have run.
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

              # Delegates to scripts/coverage.lisp — the single source of
              # truth for the sb-cover instrumentation-order recipe (also used
              # by `nix build .#coverage-report`, which runs it hermetically
              # inside the Nix sandbox rather than this interactive shell).
              nerimux-coverage() {
                report_dir="''${1:-./coverage-report}/"
                timeout --signal=TERM --kill-after=30s 2700 \
                  sbcl --dynamic-space-size 4096 --no-sysinit --no-userinit \
                  --disable-debugger --script scripts/coverage.lisp "$report_dir"
                echo "Coverage report: $report_dir" "cover-index.html"
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
