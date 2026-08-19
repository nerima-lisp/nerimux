{
  description = "nerimux — a tmux-compatible terminal multiplexer in Common Lisp";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it advances only after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Sibling packages are ALWAYS pinned to a release tag. A bare
    # `github:nerima-lisp/cl-weave` follows that repo's default branch, so an
    # upstream push to main would break this repo's CI without warning.
    #
    # cl-weave and cl-prolog-kit are consumed as flakes, so they take
    # `inputs.nixpkgs.follows`: without it each drags in its own nixpkgs,
    # inflating flake.lock and rebuilding the same derivations twice.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.1.4";
      inputs.nixpkgs.follows = "nixpkgs";
      # cl-weave's own flake still declares its paredit-cli dev input under the
      # pre-migration owner; pin it to the org (and to a tag) so no takeokunn/*
      # rev survives in our lock. paredit-cli is a transitive dev tool only and
      # is never linked into nerimux.
      inputs.paredit-cli.url = "github:nerima-lisp/paredit-cli/v1.4.0";
    };

    cl-prolog-kit = {
      url = "github:nerima-lisp/cl-prolog-kit/v1.5.0";
      inputs.nixpkgs.follows = "nixpkgs";
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
      url = "github:nerima-lisp/cl-cli/v1.2.0";
      flake = false;
    };
    cl-boundary-kit = {
      # v1.0.0: first stable release, no exported symbol/protocol/behavior
      # changes from 0.6.0 (upstream release notes) — just an example-bootstrap
      # fix and a semver-stability commitment.
      url = "github:nerima-lisp/cl-boundary-kit/v2.0.1";
      flake = false;
    };
    # Transitive only: cl-boundary-kit depends on cl-log-kit, and siblings are
    # consumed as source, so the source has to be on the registry even though
    # nothing in nerimux.asd names it. Not a direct dependency of nerimux.
    cl-log-kit = {
      url = "github:nerima-lisp/cl-log-kit/v2.0.1";
      flake = false;
    };
    cl-dataflow-kit = {
      url = "github:nerima-lisp/cl-dataflow-kit/v1.2.0";
      flake = false;
    };
    # Transitive only: cl-log-kit depends on cl-date-kit >= 0.2.0, and
    # siblings are consumed as source, so the source has to be on the
    # registry even though nothing in nerimux.asd names it directly.
    cl-date-kit = {
      url = "github:nerima-lisp/cl-date-kit/v1.0.0";
      flake = false;
    };
    cl-parser-kit = {
      url = "github:nerima-lisp/cl-parser-kit/v1.0.3";
      flake = false;
    };
    cl-tty-kit = {
      # v1.1.0: adds set-terminal-size (ioctl TIOCSWINSZ), which replaces
      # nerimux's own cffi ioctl call in pty.lisp. That call used a FIXED
      # prototype for a variadic syscall, which misfires on the arm64 ABI, so
      # pane resize was a silent no-op on Apple Silicon; cl-tty-kit goes
      # through sb-unix:unix-ioctl, which marshals the pointer correctly.
      #
      # (v1.0.2 was the previous pin, for the raw-mode fix: a duplicate defvar
      # shadowed *raw-mode-tcsetattr-function*'s platform-specific initial
      # value, crashing nerimux every time it entered raw mode. Still present.)
      url = "github:nerima-lisp/cl-tty-kit/v1.2.0";
      flake = false;
    };
    cl-process-kit = {
      # v3.1.0 exports wait-for-input/select-fds (verified with
      # `git show v3.1.0:src/package.lisp`), which
      # src/infrastructure/pty/pty.lisp's process-kit:wait-for-input call
      # needs.
      url = "github:nerima-lisp/cl-process-kit/v3.1.0";
      flake = false;
    };
    cl-history-kit = {
      # Bounded command-history store + prefix-filtered recall navigation,
      # replacing the hand-rolled list-and-cursor *prompt-history* walk in
      # runtime-history.lisp / prompt.lisp.
      url = "github:nerima-lisp/cl-history-kit/v1.0.2";
      flake = false;
    };
    cl-concurrent-kit = {
      # Replaces bordeaux-threads: threads, locks, condition variables and a
      # preemptive WITH-TIMEOUT, each a thin wrapper over SB-THREAD/SB-EXT.
      #
      # v0.3.0 (the previous pin) predates #:lock/#:with-timeout, which
      # src/timeout.lisp needs. v0.4.0 is the earliest tag confirmed to
      # export both (verified with `git show v0.4.0:src/package.lisp`).
      url = "github:nerima-lisp/cl-concurrent-kit/v0.4.0";
      flake = false;
    };
    cl-regex-kit = {
      # Replaces cl-ppcre: a from-scratch Thompson-NFA + Pike-VM engine.
      #
      # v0.3.0 already ships :template-syntax :backslash
      # (src/api-replace.lisp) and the src/pike-vm-capture.lisp paren fix
      # (verified with `git show v0.3.0:src/api-replace.lisp`).
      #
      # Depends on cl-parser-kit, which is already an input above; siblings are
      # consumed as source, so that one checkout serves both.
      url = "github:nerima-lisp/cl-regex-kit/v0.3.0";
      flake = false;
    };
    cl-codec-kit = {
      # From-scratch, babel-API-compatible codec: the 71 string<->octet call
      # sites in src/ and t/ name cl-codec-kit:string-to-octets /
      # octets-to-string directly. Briefly routed through cl-host-kit instead;
      # re-pointed here on 2026-08-02 so the codec is named at its own call
      # sites rather than through a host-ops package.
      #
      # `:depends-on ()` — depth 0, so this input pulls in nothing else.
      # cl-tty-kit and cl-process-kit (both already inputs above) consume it
      # too, so one checkout serves all three.
      url = "github:nerima-lisp/cl-codec-kit/v0.4.0";
      flake = false;
    };
    cl-host-kit = {
      # Pathname/string host operations, replacing direct uiop: calls
      # (2026-08-01 org-wide uiop->cl-host-kit migration). Still used for
      # split-string and the pathname-directory-pathname/directory-pathname-p
      # helpers.
      #
      # This pin was marked STALE while nerimux's octet conversion went through
      # this package's own string/octet wrappers, which exist only in the
      # uncommitted src/text-encoding.lisp and in no tag. Those call sites now
      # go to cl-codec-kit, and v0.2.1 does export split-string,
      # pathname-directory-pathname and directory-pathname-p (verified with
      # `git show v0.2.1:src/package.lisp`), so the pin is current again.
      url = "github:nerima-lisp/cl-host-kit/v0.2.5";
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
      cl-prolog-kit,
      cl-cli,
      cl-boundary-kit,
      cl-log-kit,
      cl-dataflow-kit,
      cl-date-kit,
      cl-parser-kit,
      cl-tty-kit,
      cl-process-kit,
      cl-history-kit,
      cl-concurrent-kit,
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

      # Every dogfooded sibling library is dependency-free (or depends only on
      # other siblings here), so each is consumed purely as source: its checkout
      # goes on ASDF's central registry rather than through nixpkgs Lisp
      # packaging. This one list drives every sbcl invocation below.
      siblingRepos = [
        cl-prolog-kit
        cl-weave
        cl-cli
        cl-boundary-kit
        cl-log-kit
        cl-dataflow-kit
        cl-date-kit
        cl-parser-kit
        cl-tty-kit
        cl-process-kit
        cl-history-kit
        cl-concurrent-kit
        cl-regex-kit
        cl-codec-kit
        cl-host-kit
        cl-tui-kit
        cl-vcs-kit
      ];

      # Colon-separated source roots, read by run-tests.lisp. Keeping the list
      # in one variable means the checks, the app and the devShell cannot drift
      # apart on which siblings they can see.
      siblingRegistry = nixpkgs.lib.concatStringsSep ":" (map toString siblingRepos);

      siblingRegistryPushEvals = nixpkgs.lib.concatMapStringsSep " " (
        repo: ''--eval "(push (truename \"${repo}/\") asdf:*central-registry*)"''
      ) siblingRepos;

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
            NERIMUX_SIBLING_REGISTRY = siblingRegistry;
            NERIMUX_TEST_SYSTEM = testSystem;
          }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cp -r ${self} ./src-tree
            chmod -R u+w ./src-tree
            cd ./src-tree
            sbcl --script run-tests.lisp
            touch "$out"
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
                --eval "(push (truename \".\") asdf:*central-registry*)" \
                ${siblingRegistryPushEvals} \
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
              description = "A tmux-compatible terminal multiplexer in Common Lisp";
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
          # the same writable-copy-of-$self shape as mkTestCheck below, which
          # is proven to run the full suite cleanly inside the Nix sandbox —
          # unlike an interactive `nix develop` shell, where this exact suite
          # is known to hang (a real PTY/tty artifact of that environment, not
          # a suite bug; see the devShell nerimux-coverage helper below, which
          # calls this same script for local use once that hang is a non-issue
          # for the caller).
          coverage-report =
            pkgs.runCommand "nerimux-coverage-report"
              {
                nativeBuildInputs = [ sbcl ];
                NERIMUX_SIBLING_REGISTRY = siblingRegistry;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME"
                cp -r ${self} ./src-tree
                chmod -R u+w ./src-tree
                cd ./src-tree
                timeout 2700 sbcl --script scripts/coverage.lisp ./coverage-report
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
      checks = forAllSystems (system: {
        # The full unit + integration suite. PTY tests self-skip when
        # /dev/ptmx is unavailable, so a sandboxed run stays meaningful.
        default = mkTestCheck system "nerimux-tests" "nerimux/test";

        # The cl-prolog-kit-backed reasoning read-model (src/reasoning/).
        weave = mkTestCheck system "nerimux-weave-tests" "nerimux/weave";

        # The cl-dataflow-kit-backed copy-mode lifecycle read-model (src/dataflow/).
        dataflow = mkTestCheck system "nerimux-dataflow-tests" "nerimux/dataflow";

        # Fails `nix flake check` when any tracked file is unformatted,
        # turning the formatter into an enforced CI gate.
        formatting = treefmtEval.${system}.config.build.check self;

        # The docs package builds with `mkdocs --strict`, so a broken link or
        # a page missing from the nav fails here. Without this check the docs
        # are only ever built by the publish workflow, which runs after a
        # merge to main — so a break would surface as a failed deploy rather
        # than as a failed pull request.
        docs = self.packages.${system}.docs;
      });

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
              export NERIMUX_SIBLING_REGISTRY="${siblingRegistry}"
              export NERIMUX_TEST_SYSTEM="''${NERIMUX_TEST_SYSTEM:-nerimux/test}"
              # Run against a writable copy for the same reason the checks do:
              # the suite compiles in place and ${self} is read-only.
              work="$(mktemp -d)"
              trap 'rm -rf "$work"' EXIT
              cp -r ${self} "$work/src-tree"
              chmod -R u+w "$work/src-tree"
              cd "$work/src-tree"
              exec sbcl --script run-tests.lisp
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
              description = "nerimux — a tmux-compatible terminal multiplexer in Common Lisp";
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
            packages = [ sbcl ];
            NERIMUX_SIBLING_REGISTRY = siblingRegistry;
            shellHook = ''
              # Registers the central-registry entries the checks use, so an
              # interactive `sbcl` session finds nerimux and every sibling
              # library without repeating those --eval flags by hand. A plain
              # `sbcl --load nerimux.asd` fails: .asd files read `defsystem` in
              # whatever package ASDF put the reader in, which is only set up
              # correctly once `(require :asdf)` and the registry pushes below
              # have run.
              nerimux-sbcl() {
                sbcl --eval "(require :asdf)" \
                     --eval "(push (truename \".\") asdf:*central-registry*)" \
                     ${siblingRegistryPushEvals} \
                     "$@"
              }
              export -f nerimux-sbcl

              # Delegates to scripts/coverage.lisp — the single source of
              # truth for the sb-cover instrumentation-order recipe (also used
              # by `nix build .#coverage-report`, which runs it hermetically
              # inside the Nix sandbox rather than this interactive shell).
              nerimux-coverage() {
                local report_dir="''${1:-./coverage-report}/"
                sbcl --script scripts/coverage.lisp "$report_dir"
                echo "Coverage report: $report_dir" "cover-index.html"
              }
              export -f nerimux-coverage

              echo "nerimux dev shell"
              echo "  run tests:       sbcl --script run-tests.lisp"
              echo "  load in a REPL:  nerimux-sbcl --eval '(asdf:load-system \"nerimux\")'"
              echo "  coverage report: nerimux-coverage [output-dir]"
            '';
          };
        }
      );
    };
}
