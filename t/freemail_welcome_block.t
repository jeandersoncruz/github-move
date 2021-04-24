#!/usr/bin/perl -T

use lib '.'; use lib 't';
use SATest; sa_t_init("freemail_welcome_block");

use Test::More;

plan tests => 4;

# ---------------------------------------------------------------------------

tstprefs ("
  freemail_domains gmail.com
  freemail_import_welcomelist_auth 0
  welcomelist_auth test\@gmail.com
  header FREEMAIL_FROM eval:check_freemail_from()
");

%patterns = (
  q{ FREEMAIL_FROM }, 'FREEMAIL_FROM',
);

ok sarun ("-L -t < data/spam/relayUS.eml", \&patterns_run_cb);
ok_all_patterns();
clear_pattern_counters();

## Now test with freemail_import_welcomelist_auth, should not hit

%patterns = ();
%anti_patterns = (
  q{ FREEMAIL_FROM }, 'FREEMAIL_FROM',
);

tstlocalrules ("
  freemail_domains gmail.com
  freemail_import_welcomelist_auth 1
  welcomelist_auth test\@gmail.com
  header FREEMAIL_FROM eval:check_freemail_from()
");

ok sarun ("-L -t < data/spam/relayUS.eml", \&patterns_run_cb);
ok_all_patterns();
