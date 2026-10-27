#!/usr/bin/env perl
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More tests => 8;

my $checker = shift // 'scripts/checks/internal-call-check.pl';
my $root = tempdir(CLEANUP => 1);
my $source_dir = File::Spec->catdir($root, 'src');
make_path($source_dir);

my $source = File::Spec->catfile($source_dir, 'calls.lisp');
open my $source_handle, '>', $source or die "cannot write $source: $!";
print {$source_handle} <<'LISP';
(defstruct worktree
  (%status-state :unloaded)
  (%status-error-message nil)
  (%read-error-p nil)
  (%default-call (%slot-default-undefined)))

(defun %exercise-flet ()
  (flet ((%on-error (condition) condition)
         (%on-complete (result) result))
    (%on-complete :done)))

(defun %call-undefined-helper ()
  (%truly-undefined))
LISP
close $source_handle or die "cannot close $source: $!";

open my $checker_process, '-|', $^X, $checker, $root
  or die "cannot run $checker: $!";
local $/;
my $output = <$checker_process> // '';
close $checker_process;
my $status = $? >> 8;

is($status, 1, 'checker fails when a real undefined helper is present');
unlike($output, qr/%on-complete/, 'checker recognizes every local FLET binding');
unlike($output, qr/%status-state/, 'checker ignores a percent-prefixed defstruct slot');
unlike($output, qr/%status-error-message/, 'checker ignores a second defstruct slot');
unlike($output, qr/%read-error-p/, 'checker ignores a third defstruct slot');
like($output, qr/%slot-default-undefined/, 'checker still checks calls in slot initializers');
like($output, qr/%truly-undefined/, 'checker reports the real undefined helper');
is(scalar(() = $output =~ /%truly-undefined/g), 1,
   'checker reports the undefined helper once');
