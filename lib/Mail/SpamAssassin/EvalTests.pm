# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::EvalTests;
1;

package Mail::SpamAssassin::PerMsgStatus;

use strict;
use bytes;

use Mail::SpamAssassin::Conf;
use Mail::SpamAssassin::Dns;
use Mail::SpamAssassin::Locales;
use Mail::SpamAssassin::MailingList;
use Mail::SpamAssassin::PerMsgStatus;
use Mail::SpamAssassin::SHA1 qw(sha1);
use Mail::SpamAssassin::TextCat;
use Mail::SpamAssassin::Constants qw(:ip);

use Fcntl;
use File::Path;
use Time::Local;
use File::Basename;

use constant HAS_DB_FILE => eval { require DB_File; };

use vars qw{
  $CCTLDS_WITH_LOTS_OF_OPEN_RELAYS
  $ROUND_THE_WORLD_RELAYERS
  $WORD_OBFUSCATION_CHARS 
  $CHARSETS_LIKELY_TO_FP_AS_CAPS
};

# sad but true. sort it out, sysadmins!
$CCTLDS_WITH_LOTS_OF_OPEN_RELAYS = qr{(?:kr|cn|cl|ar|hk|il|th|tw|sg|za|tr|ma|ua|in|pe|br)};
$ROUND_THE_WORLD_RELAYERS = qr{(?:net|com|ca)};

# Here's how that RE was determined... relay rape by country (as of my
# spam collection on Dec 12 2001):
#
#     10 in     10 ua     11 ma     11 tr     11 za     12 gr
#     13 pl     14 se     15 hu     17 sg     19 dk     19 pt
#     19 th     21 us     22 hk     24 il     26 ch     27 ar
#     27 es     29 cz     32 cl     32 mx     37 nl     38 fr
#     41 it     43 ru     59 au     62 uk     67 br     70 ca
#    104 tw    111 de    123 jp    130 cn    191 kr
#
# However, since some ccTLDs just have more hosts/domains (skewing those
# figures), I cut down this list using data from
# http://www.isc.org/ds/WWW-200107/. I used both hostcount and domain counts
# for figuring this. any ccTLD with > about 40000 domains is left out of this
# regexp.  Then I threw in some unscientific seasoning to taste. ;)

$WORD_OBFUSCATION_CHARS = '*_.,/|-+=';

# Charsets which use capital letters heavily in their encoded representation.
$CHARSETS_LIKELY_TO_FP_AS_CAPS = qr{[-_a-z0-9]*(?:
	  koi|jp|jis|euc|gb|big5|isoir|cp1251|georgianps|pt154|tis
	)[-_a-z0-9]*}ix;

###########################################################################
# HEAD TESTS:
###########################################################################

sub check_for_from_dns {
  my ($self) = @_;

  if (!defined ($self->{checked_for_from_dns})) {
    $self->{checked_for_from_dns} = $self->_check_for_from_dns();
  }

  return $self->{checked_for_from_dns};
}

sub _check_for_from_dns {
  my ($self) = @_;

  my $from = $self->get ('Reply-To:addr');
  if (!defined $from || $from !~ /\@\S+/) {
    $from = $self->get ('From:addr');
  }
  return 0 unless ($from =~ /\@(\S+)/);
  $from = $1;

  # First check that DNS is available, if not do not perform this check
  return 0 unless $self->is_dns_available();
  $self->load_resolver();

  if ($from eq 'compiling.spamassassin.taint.org') {
    # only used when compiling
    return 0;
  }

  if ($self->{conf}->{check_mx_attempts} < 1) {
    return 0;
  }

  # Try check_mx_attempts times to protect against temporary outages.
  # sleep between checks to give the DNS a chance to recover.
  for my $i (1 .. $self->{conf}->{check_mx_attempts}) {
    return 0 if ($self->lookup_mx_exists ($from));
    return 0 if ($self->lookup_a ($from));
    if ($i < $self->{conf}->{check_mx_attempts}) {
      sleep $self->{conf}->{check_mx_delay};
    }
  }

  $self->set_server_failed_to_respond_for_domain($from);
  return 1;
}

###########################################################################

# From and To have same address, but are not exactly the same and
# neither contains intermediate spaces.
sub check_for_from_to_same {
  my ($self) = @_;

  my $hdr_from = $self->get('From');
  my $hdr_to = $self->get('To');
  return 0 if (!length($hdr_from) || !length($hdr_to) ||
	       $hdr_from eq $hdr_to);

  my $addr_from = $self->get('From:addr');
  my $addr_to = $self->get('To:addr');
  # BUG: From:addr and To:addr sometimes contain whitespace
  $addr_from =~ s/\s+//g;
  $addr_to =~ s/\s+//g;
  return 0 if (!length($addr_from) || !length($addr_to) ||
	       $addr_from ne $addr_to);

  if ($hdr_from =~ /^\s*\S+\s*$/ && $hdr_to =~ /^\s*\S+\s*$/) {
    return 1;
  }
}

sub sorted_recipients {
  my ($self) = @_;

  if (!exists $self->{tocc_sorted}) {
    $self->_check_recipients();
  }
  return $self->{tocc_sorted};
}

sub similar_recipients {
  my ($self, $min, $max) = @_;

  if (!exists $self->{tocc_similar}) {
    $self->_check_recipients();
  }
  return (($min eq 'undef' || $self->{tocc_similar} >= $min) &&
	  ($max eq 'undef' || $self->{tocc_similar} < $max));
}

# best experimentally derived values
use constant TOCC_SORTED_COUNT => 7;
use constant TOCC_SIMILAR_COUNT => 5;
use constant TOCC_SIMILAR_LENGTH => 2;

sub _check_recipients {
  my ($self) = @_;

  my @address;

  # ToCc: pseudo-header works best, but sometimes Bcc: is better
  for ('ToCc', 'Bcc') {
    my $to = $self->get($_);	# get recipients
    $to =~ s/\(.*?\)//g;	# strip out the (comments)
    @address = ($to =~ m/([\w.=-]+\@\w+(?:[\w.-]+\.)+\w+)/g);
    last if scalar(@address) >= TOCC_SIMILAR_COUNT;
  }

  # ideas that had both poor S/O ratios and poor hit rates:
  # - testing for reverse sorted recipient lists
  # - testing To: and Cc: headers separately
  $self->{tocc_sorted} = (scalar(@address) >= TOCC_SORTED_COUNT &&
			  join(',', @address) eq (join(',', sort @address)));

  # a good S/O ratio and hit rate is achieved by comparing 2-byte
  # substrings and requiring 5 or more addresses
  $self->{tocc_similar} = 0;
  if (scalar (@address) >= TOCC_SIMILAR_COUNT) {
    my @user = map { substr($_,0,TOCC_SIMILAR_LENGTH) } @address;
    my @fqhn = map { m/\@(.*)/ } @address;
    my @host = map { substr($_,0,TOCC_SIMILAR_LENGTH) } @fqhn;
    my $hits = 0;
    my $combinations = 0;
    for (my $i = 0; $i <= $#address; $i++) {
      for (my $j = $i+1; $j <= $#address; $j++) {
	$hits++ if $user[$i] eq $user[$j];
	$hits++ if $host[$i] eq $host[$j] && $fqhn[$i] ne $fqhn[$j];
	$combinations++;
      }
    }
    $self->{tocc_similar} = $hits / $combinations;
  }
}

###########################################################################
# tests to detect when the MTA added the Message-ID

sub mta_added_message_id {
  my ($self, $test) = @_;

  if (!exists $self->{"mta_added_message_id_$test"}) {
    $self->_mta_added_message_id();
  }
  return $self->{"mta_added_message_id_$test"};
}

sub backup_mx_host {
  my ($self, $host, $test) = @_;

  # check that DNS is available, if not do not perform this check
  return 0 unless $self->is_dns_available();

  $self->load_resolver();

  if ($self->{conf}->{check_mx_attempts} < 1) {
    return 0;
  }

  # try check_mx_attempts times to protect against temporary outages.
  # sleep between checks to give the DNS a chance to recover.
  for my $i (1..$self->{conf}->{check_mx_attempts}) {
    my @mx = Net::DNS::mx($self->{res}, $host);
    return 0 unless (scalar @mx);
    my $primary;
    my $preference;
    foreach my $mx (@mx) {
      if (!defined($primary) || ($mx->preference =~ /^\d+$/ &&
				 $mx->preference < $primary))
      {
	$primary = $mx->preference;
      }
      if (lc($mx->exchange) eq lc($test)) {
	$preference = $mx->preference;
      }
    }
    if (defined($primary) && defined($preference) && $preference > $primary) {
      return 1;
    }
  }

  return 0;
}

# Please make sure you understand how this test works before changing
# it, especially to add exemptions which are very unlikely be needed.
sub _mta_added_message_id {
  my ($self) = @_;

  $self->{mta_added_message_id_short} = 0;
  $self->{mta_added_message_id_later} = 0;
  $self->{mta_added_message_id_backup} = 0;

  # We may get headers with continuations in them, so deal with it ...
  my @received = grep(/\S/, map { s/\r?\n\s+/ /g; $_; } $self->get('Received'));
  my $id = $self->get('Resent-Message-ID') || $self->get('Message-ID');
  return unless defined($id) && $id;
  my $local = 1;

  # general method to detect local messages
  my $from = $self->get('From:addr');
  $from =~ s/.*\@//;
  $from = ($from =~ m/(\S+\.\S+)\s*$/) ? lc($1) : '';

  # Postfix adds the Message-ID on the second local hop.  Note: this is not
  # an exemption, this is a special case to classify these hits correctly.
  if ($#received > 0 &&
      $received[$#received] =~ /\[127\.0\.0\.1\].+\(Postfix.*?\)/i &&
      $received[$#received - 1] =~ /\(Postfix, from userid \d+\)/i)
  {
    $local = 2;
  }

  # Message-ID headers added by qmail generally include the current local
  # date and time instead of an ID, so no exemption is necessary for qmail.

  # Note: these tests intentionally do not exempt localhost!
  for (my $i = 0; $i <= $#received; $i++) {
    if ($received[$i] =~ /\sid ([^\s;]{3,})/) {
      my $received_id = $1;

      if (index($id, $received_id) != -1) {
	# if: only 1 or 2 hops
	if ($local > $#received && !($from && $id =~ /\@.*\Q$from\E>/)) {
	  $self->{mta_added_message_id_short} = 1;
	}
	# else: hops after first 1 or 2 hops
	elsif ($i + $local <= $#received) {
	  $self->{mta_added_message_id_later} = 1;
	}
	# else: first 1 or 2 hops and through a backup MX
	else {
	  my $host;
	  my $test;
	  if ($received[$i] =~ /\bfor\s\W*([^\s>;]+)/) {
	    $host = lc($1);
	    $host =~ s/.*\@//;
	  }
	  if ($host && $received[$i] =~ /\bby\s\W*([^\s>;]+)/) {
	    $test = lc($1);
	  }
	  if ($host && $test && $self->backup_mx_host($host, $test)) {
	    $self->{mta_added_message_id_backup} = 1;
	  }
	}
      }
    }
  }
}

###########################################################################

# FORGED_RCVD_TRAIL
sub check_for_forged_received_trail {
  my ($self) = @_;
  $self->_check_for_forged_received unless exists $self->{mismatch_from};
  return ($self->{mismatch_from} > 1);
}

# FORGED_RCVD_HELO
sub check_for_forged_received_helo {
  my ($self) = @_;
  $self->_check_for_forged_received unless exists $self->{mismatch_helo};
  return ($self->{mismatch_helo} > 0);
}

# FORGED_RCVD_IP_HELO
sub check_for_forged_received_ip_helo {
  my ($self) = @_;
  $self->_check_for_forged_received unless exists $self->{mismatch_ip_helo};
  return ($self->{mismatch_ip_helo} > 0);
}

sub _check_for_forged_received {
  my ($self) = @_;

  $self->{mismatch_from} = 0;
  $self->{mismatch_helo} = 0;
  $self->{mismatch_ip_helo} = 0;

  my @fromip = map { $_->{ip} } @{$self->{relays_untrusted}};
  # just pick up domains for these
  my @by = map {
               hostname_to_domain ($_->{lc_by});
             } @{$self->{relays_untrusted}};
  my @from = map {
               hostname_to_domain ($_->{lc_rdns});
             } @{$self->{relays_untrusted}};
  my @helo = map {
               hostname_to_domain ($_->{lc_helo});
             } @{$self->{relays_untrusted}};
 
  for (my $i = 0; $i < $self->{num_relays_untrusted}; $i++) {
    next if (!defined $by[$i] || $by[$i] !~ /^\w+(?:[\w.-]+\.)+\w+$/);

    if (defined ($from[$i]) && defined($fromip[$i])) {
      if ($from[$i] =~ /^localhost(?:\.localdomain)?$/) {
        if ($fromip[$i] eq '127.0.0.1') {
          # valid: bouncing around inside 1 machine, via the localhost
          # interface (freshmeat newsletter does this).  TODO: this
	  # may be obsolete, I think we do this in Received.pm anyway
          $from[$i] = undef;
        }
      }
    }

    my $frm = $from[$i];
    my $hlo = $helo[$i];
    my $by = $by[$i];

    dbg ("forged-HELO: from=".(defined $frm ? $frm : "(undef)").
			" helo=".(defined $hlo ? $hlo : "(undef)").
			" by=".(defined $by ? $by : "(undef)"));

    # note: this code won't catch IP-address HELOs, but we already have
    # a separate rule for that anyway.

    next unless ($by =~ /^\w+(?:[\w.-]+\.)+\w+$/);

    if (defined($hlo) && defined($frm)
		&& $hlo =~ /^\w+(?:[\w.-]+\.)+\w+$/
		&& $frm =~ /^\w+(?:[\w.-]+\.)+\w+$/
		&& $frm ne $hlo && !helo_forgery_whitelisted($frm, $hlo))
    {
      dbg ("forged-HELO: mismatch on HELO: '$hlo' != '$frm'");
      $self->{mismatch_helo}++;
    }

    my $fip = $fromip[$i];

    if (defined($hlo) && defined($fip)) {
      if ($hlo =~ /^\d+\.\d+\.\d+\.\d+$/
		  && $fip =~ /^\d+\.\d+\.\d+\.\d+$/
		  && $fip ne $hlo)
      {
	$hlo =~ /^(\d+\.\d+)\.\d+\.\d+$/; my $hclassb = $1;
	$fip =~ /^(\d+\.\d+)\.\d+\.\d+$/; my $fclassb = $1;

	# allow private IP addrs here, could be a legit screwup
	if ($hclassb && $fclassb && 
		$hclassb ne $fclassb &&
		!($hlo =~ /IP_IN_RESERVED_RANGE/o))
	{
	  dbg ("forged-HELO: massive mismatch on IP-addr HELO: '$hlo' != '$fip'");
	  $self->{mismatch_ip_helo}++;
	}
      }
    }

    my $prev = $from[$i-1];
    if (defined($prev) && $i > 0
		&& $prev =~ /^\w+(?:[\w.-]+\.)+\w+$/
		&& $by ne $prev && !helo_forgery_whitelisted($by, $prev))
    {
      dbg ("forged-HELO: mismatch on from: '$prev' != '$by'");
      $self->{mismatch_from}++;
    }
  }
}

sub helo_forgery_whitelisted {
  my ($helo, $rdns) = @_;
  if ($helo eq 'msn.com' && $rdns eq 'hotmail.com') { return 1; }
  0;
}

sub hostname_to_domain {
  my ($hostname) = @_;

  if ($hostname !~ /[a-zA-Z]/) { return $hostname; }	# IP address

  my @parts = split(/\./, $hostname);
  if (@parts > 1 && $parts[-1] =~ /(?:\S{3,}|ie|fr|de)/) {
    return join('.', @parts[-2..-1]);
  }
  elsif (@parts > 2) {
    return join('.', @parts[-3..-1]);
  }
  else {
    return $hostname;
  }
}

# FORGED_HOTMAIL_RCVD
sub _check_for_forged_hotmail_received_headers {
  my ($self) = @_;

  if (defined $self->{hotmail_addr_but_no_hotmail_received}) { return; }

  $self->{hotmail_addr_with_forged_hotmail_received} = 0;
  $self->{hotmail_addr_but_no_hotmail_received} = 0;

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  return if ($rcvd =~
        /from mail pickup service by hotmail\.com with Microsoft SMTPSVC;/);

  my $ip = $self->get ('X-Originating-Ip');
  if ($ip =~ /IP_ADDRESS/) { $ip = 1; } else { $ip = 0; }

  # Hotmail formats its received headers like this:
  # Received: from hotmail.com (f135.law8.hotmail.com [216.33.241.135])
  # spammers do not ;)

  if ($self->gated_through_received_hdr_remover()) { return; }

  if ($rcvd =~ /from \S*hotmail.com \(\S+\.hotmail(?:\.msn)?\.com[ \)]/ && $ip)
                { return; }
  if ($rcvd =~ /from \S+ by \S+\.hotmail(?:\.msn)?\.com with HTTP\;/ && $ip)
                { return; }
  if ($rcvd =~ /from \[66\.218.\S+\] by \S+\.yahoo\.com/ && $ip)
                { return; }

  if ($rcvd =~ /(?:from |HELO |helo=)\S*hotmail\.com\b/) {
    # HELO'd as hotmail.com, despite not being hotmail
    $self->{hotmail_addr_with_forged_hotmail_received} = 1;
  } else {
    # check to see if From claimed to be @hotmail.com
    my $from = $self->get ('From:addr');
    if ($from !~ /hotmail.com/) { return; }
    $self->{hotmail_addr_but_no_hotmail_received} = 1;
  }
}

# FORGED_HOTMAIL_RCVD
sub check_for_forged_hotmail_received_headers {
  my ($self) = @_;
  $self->_check_for_forged_hotmail_received_headers();
  return $self->{hotmail_addr_with_forged_hotmail_received};
}

# SEMIFORGED_HOTMAIL_RCVD
sub check_for_no_hotmail_received_headers {
  my ($self) = @_;
  $self->_check_for_forged_hotmail_received_headers();
  return $self->{hotmail_addr_but_no_hotmail_received};
}

# MSN_GROUPS
sub check_for_msn_groups_headers {
  my ($self) = @_;

  return 0 unless ($self->get('To') =~ /<(\S+)\@groups\.msn\.com>/i);
  my $listname = $1;

  # from Theo Van Dinter, see
  # http://www.hughes-family.org/bugzilla/show_bug.cgi?id=591
  return 0 unless $self->get('Message-Id') =~ /^<$listname-\S+\@groups\.msn\.com>/;
  return 0 unless $self->get('X-Loop') =~ /^notifications\@groups\.msn\.com/;
  return 0 unless $self->get('Return-Path') =~ /<$listname-bounce\@groups\.msn\.com>/;

  $_ = $self->get ('Received');
  return 0 if !/from mail pickup service by groups\.msn\.com\b/;
  return 1;

# MSN Groups
# Return-path: <ListName-bounce@groups.msn.com>
# Received: from groups.msn.com (tk2dcpuba02.msn.com [65.54.195.210]) by
#    dogma.slashnull.org (8.11.6/8.11.6) with ESMTP id g72K35v10457 for
#    <zzzzzzzzzzzz@jmason.org>; Fri, 2 Aug 2002 21:03:05 +0100
# Received: from mail pickup service by groups.msn.com with Microsoft
#    SMTPSVC; Fri, 2 Aug 2002 13:01:30 -0700
# Message-id: <ListName-1392@groups.msn.com>
# X-loop: notifications@groups.msn.com
# Reply-to: "List Full Name" <ListName@groups.msn.com>
# To: "List Full Name" <ListName@groups.msn.com>

}

###########################################################################

sub check_for_forged_eudoramail_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /eudoramail.com/) { return 0; }

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  my $ip = $self->get ('X-Sender-Ip');
  if ($ip =~ /IP_ADDRESS/) { $ip = 1; } else { $ip = 0; }

  # Eudoramail formats its received headers like this:
  # Received: from Unknown/Local ([?.?.?.?]) by shared1-mail.whowhere.com;
  #      Thu Nov 29 13:44:25 2001
  # Message-Id: <JGDHDEHPPJECDAAA@shared1-mail.whowhere.com>
  # Organization: QUALCOMM Eudora Web-Mail  (http://www.eudoramail.com:80)
  # X-Sender-Ip: 192.175.21.146
  # X-Mailer: MailCity Service

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /by \S*whowhere.com\;/ && $ip) { return 0; }
  
  return 1;
}

###########################################################################

sub check_for_forged_excite_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /excite.com/) { return 0; }

  my $rcvd = $self->get ('Received');
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  # Excite formats its received headers like this:
  # Received: from bucky.excite.com ([198.3.99.218]) by vaxc.cc.monash.edu.au
  #    (PMDF V6.0-24 #38147) with ESMTP id
  #    <01K53WHA3OGCA5W9MM@vaxc.cc.monash.edu.au> for luv@luv.asn.au;
  #    Sat, 23 Jun 2001 13:36:20 +1000
  # Received: from hippie.excite.com ([199.172.148.180]) by bucky.excite.com
  #    (InterMail vM.4.01.02.39 201-229-119-122) with ESMTP id
  #    <20010623033612.NRCY6361.bucky.excite.com@hippie.excite.com> for
  #    <luv@luv.asn.au>; Fri, 22 Jun 2001 20:36:12 -0700
  # spammers do not ;)

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /from \S*excite.com (\S+) by \S*excite.com/) { return 0; }
  
  return 1;
}

###########################################################################

sub check_for_forged_yahoo_received_headers {
  my ($self) = @_;

  my $from = $self->get ('From:addr');
  if ($from !~ /yahoo\.com$/) { return 0; }

  my $rcvd = $self->get ('Received');
  
  if ( $self->get("Resent-From") && $self->get("Resent-To") ) {
    my $xrcvd = $self->get("X-Received");
    $rcvd = $xrcvd if ( $xrcvd );
  }
  $rcvd =~ s/\s+/ /gs;		# just spaces, simplify the regexp

  # not sure about this
  #if ($rcvd !~ /from \S*yahoo\.com/) { return 0; }

  if ($self->gated_through_received_hdr_remover()) { return 0; }

  if ($rcvd =~ /by web\S+\.mail\.yahoo\.com via HTTP/) { return 0; }
  if ($rcvd =~ /by smtp\S+\.yahoo\.com with SMTP/) { return 0; }
  if ($rcvd =~
      /from \[IP_ADDRESS\] by \S+\.(?:groups|grp\.scd)\.yahoo\.com with NNFMP/) {
    return 0;
  }

  # used in "forward this news item to a friend" links.  There's no better
  # received hdrs to match on, unfortunately.  I'm not sure if the next test is
  # still useful, as a result.
  #
  # search for msgid <20020929140301.451A92940A9@xent.com>, subject "Yahoo!
  # News Story - Top Stories", date Sep 29 2002 on
  # <http://xent.com/pipermail/fork/> for an example.
  #
  if ($rcvd =~ /\bmailer\d+\.bulk\.scd\.yahoo\.com\b/
                && $from =~ /\@reply\.yahoo\.com$/) { return 0; }

  if ($rcvd =~ /by \w+\.\w+\.yahoo\.com \(\d+\.\d+\.\d+\/\d+\.\d+\.\d+\)(?: with ESMTP)? id \w+/) {
      # possibly sent from "mail this story to a friend"
      return 0;
  }

  return 1;
}

sub check_for_forged_juno_received_headers {
  my ($self) = @_;

  my $from = $self->get('From:addr');
  if($from !~ /\bjuno.com/) { return 0; }

  if($self->gated_through_received_hdr_remover()) { return 0; }

  my $xmailer = $self->get('X-Mailer');
  my $xorig = $self->get('X-Originating-IP');
  my $rcvd = $self->get('Received');

  if (!$xorig) {  # New style Juno has no X-Originating-IP header, and other changes
    if($rcvd !~ /from.*\b(?:juno|untd)\.com.*[\[\(]IP_ADDRESS[\]\)].*by/
        && $rcvd !~ / cookie\.(?:juno|untd)\.com /) { return 1; }
    if($xmailer !~ /Juno /) { return 1; }
  } else {
    if($rcvd !~ /from.*\bmail\.com.*\[IP_ADDRESS\].*by/) { return 1; }
    if($xorig !~ /IP_ADDRESS/) { return 1; }
    if($xmailer !~ /\bmail\.com/) { return 1; }
  }

  return 0;   
}

#Received: from dragnet.sjc.ebay.com (dragnet.sjc.ebay.com [10.6.21.14])
#	by bashir.ebay.com (8.10.2/8.10.2) with SMTP id g29JpwB10940
#	for <rod@begbie.com>; Sat, 9 Mar 2002 11:51:58 -0800

sub check_for_from_domain_in_received_headers {
  my ($self, $domain, $desired) = @_;
  
  if (exists $self->{from_domain_in_received}) {
      if (exists $self->{from_domain_in_received}->{$domain}) {
	  if ($desired eq 'true') {
	      # See use of '0e0' below for why we force int() here:
	      return int($self->{from_domain_in_received}->{$domain});
	  }
	  else {
	      # And why we deliberately do NOT use integers here:
	      return !$self->{from_domain_in_received}->{$domain};
	  }
      }
  } else {
      $self->{from_domain_in_received} = {};
  }

  my $from = $self->get('From:addr');
  if ($from !~ /\b\Q$domain\E/i) {
      # '0e0' is Perl idiom for "true but zero":
      $self->{from_domain_in_received}->{$domain} = '0e0';
      return 0;
  }

  my $rcvd = $self->{relays_trusted_str}.$self->{relays_untrusted_str};

  if ($rcvd =~ / rdns=\S*\b${domain} [^\]]*by=\S*\b${domain} /) {
      $self->{from_domain_in_received}->{$domain} = 1;
      return ($desired eq 'true');
  }

  $self->{from_domain_in_received}->{$domain} = 0;
  return ($desired ne 'true');   
}

# ezmlm has a very bad habit of removing Received: headers! bad ezmlm.
#
sub gated_through_received_hdr_remover {
  my ($self) = @_;

  my $txt = $self->get ("Mailing-List");
  if (defined $txt && $txt =~ /^contact \S+\@\S+\; run by ezmlm$/) {
    my $dlto = $self->get ("Delivered-To");
    my $rcvd = $self->get ("Received");

    # ensure we have other indicative headers too
    if ($dlto =~ /^mailing list \S+\@\S+/ &&
      	$rcvd =~ /qmail \d+ invoked by .{3,20}\); \d+ ... \d+/)
    {
      return 1;
    }
    # jm: this line *was* included:
    #   $rcvd =~ /qmail \d+ invoked from network\); \d+ ... \d+/ &&
    # but I've found FPs where it did not appear in the mail; it's
    # not required.
  }

  if ($self->get ("Received") !~ /\S/) {
    # we have no Received headers!  These tests cannot run in that case
    return 1;
  }

  # MSN groups removes Received lines. thanks MSN
  if ($self->get ("Received") =~ /from groups\.msn\.com \(\S+\.msn\.com /) {
    return 1;
  }

  return 0;
}

###########################################################################

# Bug 1133

# Some spammers will, through HELO, tell the server that their machine
# name *is* the relay; don't know why. An example:

# from mail1.mailwizards.com (m448-mp1.cvx1-b.col.dial.ntli.net
#        [213.107.233.192])
#        by mail1.mailwizards.com

# When this occurs for real, the from name and HELO name will be the
# same, unless the "helo" name is localhost, or the from and by hostsnames
# themselves are localhost
sub _check_received_helos {
  my ($self) = @_;

  for (my $i = 0; $i < $self->{num_relays_untrusted}; $i++) {
    my $rcvd = $self->{relays_untrusted}->[$i];

    # Ignore where IP is in reserved IP space
    next if ($rcvd->{ip_is_reserved});

    my $from_host = $rcvd->{rdns};
    my $helo_host = $rcvd->{helo};
    my $by_host = $rcvd->{by};
    my $no_rdns = $rcvd->{no_reverse_dns};

    next unless defined($helo_host);

    # Check for a faked dotcom HELO, e.g.
    # Received: from mx02.hotmail.com (www.sucasita.com.mx [148.223.251.99])...
    # this can be a stronger spamsign than the normal case, since the
    # big dotcoms don't screw up their rDNS normally ;), so less FPs.
    # Since spammers like sending out their mails from the dotcoms (esp.
    # hotmail and AOL) this will catch those forgeries.
    #
    # allow stuff before the dot-com for both from-name and HELO-name,
    # so HELO="outgoing.aol.com" and from="mx34853495.mx.aol.com" works OK.
    #
    $self->{no_rdns_dotcom_helo} = 0;
    if ($helo_host =~ /(?:\.|^)(lycos\.com|lycos\.co\.uk|hotmail\.com
		|localhost\.com|excite\.com|caramail\.com
		|cs\.com|aol\.com|msn\.com|yahoo\.com|drizzle\.com)$/ix)
    {
      my $dom = $1;

      # ok, let's catch the case where there's *no* reverse DNS there either
      if ($no_rdns) {
	dbg ("Received: no rDNS for dotcom HELO: from=$from_host HELO=$helo_host");
	$self->{no_rdns_dotcom_helo} = 1;
      }
    }
  }
} # _check_received_helos()

sub check_for_no_rdns_dotcom_helo {
  my ($self) = @_;
  if (!exists $self->{no_rdns_dotcom_helo}) { $self->_check_received_helos(@_); }
  return $self->{no_rdns_dotcom_helo};
}

###########################################################################

# look for 8-bit and other illegal characters that should be MIME
# encoded, these might want to exempt languages that do not use
# Latin-based alphabets, but only if the user wants it that way
sub check_illegal_chars {
  my ($self, $header, $ratio, $count) = @_;

  $header .= ":raw" unless ($header eq "ALL" || $header =~ /:raw$/);
  my $str = $self->get($header);
  return 0 unless $str;

  # avoid overlap between tests
  if ($header eq "ALL") {
    # fix continuation lines, then remove Subject and From
    $str =~ s/\n[ \t]+/  /gs;
    $str =~ s/^(?:Subject|From):.*$//gm;
  }

  # count illegal substrings (RFC 2045)
  my $illegal = () = ($str =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\xff]/g);

  # minor exemptions for Subject
  if ($header eq "Subject:raw") {
    # only exempt a single cent sign, pound sign, or registered sign
    my $exempt = () = ($str =~ /[\xa2\xa3\xae]/g);
    $illegal-- if $exempt == 1;
  }

  return (($illegal / length($str)) >= $ratio && $illegal >= $count);
}

sub are_more_high_bits_set {
  my ($self, $str) = @_;

  my $numhis = () = ($str =~ /[\200-\377]/g);
  my $numlos = length($str) - $numhis;

  ($numlos <= $numhis && $numhis > 3);
}

###########################################################################

sub check_for_missing_to_header {
  my ($self) = @_;

  my $hdr = $self->get ('To');
  $hdr ||= $self->get ('Apparently-To');
  return 1 if ($hdr eq '');

  return 0;
}

###########################################################################

# Check if the apparent sender (in the last received header) had
# no reverse lookup for it's IP
#
# Look for headers like:
#
#   Received: from mx1.eudoramail.com ([204.32.147.84])
sub check_for_sender_no_reverse {
  my ($self) = @_;

  # Sender received header is the last in the sequence
  my $srcvd = $self->{relays_untrusted}->
				[$self->{num_relays_untrusted} - 1];

  return 0 unless (defined $srcvd);

  # Ignore if the from host is domainless (has no dot)
  return 0 unless ($srcvd->{rdns} =~ /\./);

  # Ignore if the from host is from a reserved IP range
  return 0 if ($srcvd->{ip_is_reserved});

  return 1;
} # check_for_sender_no_reverse()

###########################################################################

sub check_from_in_list {
  my ($self,$list) = @_;
  my $list_ref = $self->{conf}{$list};
  warn "Could not find list $list" unless defined $list_ref;

  foreach my $addr ( all_from_addrs $self ) {
    return 1 if _check_whitelist $self $list_ref, $addr;
  }

  return 0;
}

###########################################################################

sub check_to_in_list {
  my ($self,$list) = @_;
  my $list_ref = $self->{conf}{$list};
  warn "Could not find list $list" unless defined $list_ref;

  foreach my $addr ( all_to_addrs $self ) {
    return 1 if _check_whitelist $self $list_ref, $addr;
  }

  return 0;
}


###########################################################################

sub check_from_in_whitelist {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_from_addrs()) {
    if ($self->_check_whitelist ($self->{conf}->{whitelist_from}, $_)) {
      return 1;
    }
    if ($self->_check_whitelist_rcvd ($self->{conf}->{whitelist_from_rcvd}, $_)) {
      return 1;
    }
  }

  return 0;
}

###########################################################################

sub check_from_in_default_whitelist {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_from_addrs()) {
    if ($self->_check_whitelist_rcvd ($self->{conf}->{def_whitelist_from_rcvd}, $_)) {
      return 1;
    }
  }

  return 0;
}

###########################################################################

sub check_from_in_auto_whitelist {
    my ($self) = @_;

    return unless defined $self->{main}->{pers_addr_list_factory};

    local $_ = lc $self->get('From:addr');
    return 0 unless /\S/;

    # find the earliest usable "originating IP".  ignore reserved nets
    my $origip;
    foreach my $rly (reverse (@{$self->{relays_trusted}}, @{$self->{relays_untrusted}}))
    {
      next if ($rly->{ip_is_reserved});
      if ($rly->{ip}) {
	$origip = $rly->{ip}; last;
      }
    }

    my $awlpoints = $self->get_nonlearn_nonuserconf_points();

    # Create the AWL object, catching 'die's
    my $whitelist;
    my $evalok = eval {
      $whitelist = Mail::SpamAssassin::AutoWhitelist->new($self->{main});

      # check
      my $meanscore = $whitelist->check_address($_, $origip);
      my $delta = 0;

      dbg("AWL active, pre-score: $self->{score}, autolearn score: $awlpoints, ".
	"mean: ". ($meanscore || 'undef') .", IP: ". ($origip || 'undef'));

      if (defined ($meanscore)) {
        $delta = ($meanscore - $awlpoints) * $self->{main}->{conf}->{auto_whitelist_factor};
	$self->{tag_data}->{AWL} = sprintf("%2.1f",$delta);
	# Save this for _AWL_ tag
      }

      # Update the AWL *before* adding the new score, otherwise
      # early high-scoring messages are reinforced compared to
      # later ones.  http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=159704
      if (!$self->{disable_auto_learning}) {
        $whitelist->add_score($awlpoints);
      }

      # current AWL score changes with each hit
      for my $set (0..3) {
	$self->{conf}->{scoreset}->[$set]->{"AWL"} = sprintf("%0.3f", $delta);
      }

      if ($delta != 0) {
        $self->_handle_hit("AWL", $delta, "AWL: ",
			   $self->{main}->{conf}->{descriptions}->{AWL});
      }

      $whitelist->finish();
      1;
    };

    if (!$evalok) {
      dbg ("open of AWL file failed: $@");
      # try an unlock, in case we got that far
      eval { $whitelist->finish(); };
    }

    dbg("Post AWL score: ".$self->{score});

    # test hit is above
    return 0;
}

###########################################################################

sub _check_whitelist_rcvd {
  my ($self, $list, $addr) = @_;

  # we can only match this if we have at least 1 trusted or untrusted header
  return unless ($self->{num_relays_untrusted}+$self->{num_relays_trusted} > 0);

  my @relays = ();
  # try the untrusted one first
  if ($self->{num_relays_untrusted} > 0) {
    @relays = $self->{relays_untrusted}->[0];
  }
  # then try the trusted ones; the user could have whitelisted a trusted
  # relay, totally permitted
  if ($self->{num_relays_trusted} > 0) {
    push (@relays, @{$self->{relays_trusted}});
  }

  $addr = lc $addr;
  foreach my $white_addr (keys %{$list}) {
    my $regexp = $list->{$white_addr}{re};
    my $domain = $list->{$white_addr}{domain};

    if ($addr =~ /${regexp}/i) {
      foreach my $lastunt (@relays) {
	my $rdns = $lastunt->{lc_rdns};
	if ($rdns =~ /(?:^|\.)\Q${domain}\E$/) { return 1; }
      }
    }
  }

  return 0;
}

###########################################################################

sub _check_whitelist {
  my ($self, $list, $addr) = @_;
  $addr = lc $addr;
  if (defined ($list->{$addr})) { return 1; }
  study $addr;
  foreach my $regexp (values %{$list}) {
    if ($addr =~ /$regexp/i) {
      return 1;
    }
  }

  return 0;
}

sub all_from_addrs {
  my ($self) = @_;

  if (exists $self->{all_from_addrs}) { return @{$self->{all_from_addrs}}; }

  my @addrs;

  # Resent- headers take priority, if present. see bug 672
  # http://www.hughes-family.org/bugzilla/show_bug.cgi?id=672
  my $resent = $self->get ('Resent-From');
  if (defined $resent && $resent =~ /\S/) {
    @addrs = $self->{main}->find_all_addrs_in_line (
  	 $self->get ('Resent-From'));

  } else {
    @addrs = $self->{main}->find_all_addrs_in_line
  	($self->get ('From') .                  # std
  	 $self->get ('Envelope-Sender') .       # qmail: new-inject(1)
  	 $self->get ('Resent-Sender') .         # procmailrc manpage
  	 $self->get ('X-Envelope-From') .       # procmailrc manpage
  	 $self->get ('Return-Path') .           # Postfix, sendmail; rfc821
  	 $self->get ('Resent-From'));
    # http://www.cs.tut.fi/~jkorpela/headers.html is useful here
  }

  dbg ("all '*From' addrs: ".join (" ", @addrs));
  $self->{all_from_addrs} = \@addrs;
  return @addrs;
}

sub all_to_addrs {
  my ($self) = @_;

  if (exists $self->{all_to_addrs}) { return @{$self->{all_to_addrs}}; }

  my @addrs;

  # Resent- headers take priority, if present. see bug 672
  # http://www.hughes-family.org/bugzilla/show_bug.cgi?id=672
  my $resent = $self->get ('Resent-To') . $self->get ('Resent-Cc');
  if (defined $resent && $resent =~ /\S/) {
    @addrs = $self->{main}->find_all_addrs_in_line (
  	 $self->get ('Resent-To') .             # std, rfc822
  	 $self->get ('Resent-Cc'));             # std, rfc822

  } else {
    # OK, a fetchmail trick: try to find the recipient address from
    # the most recent 3 Received lines.  This is required for sendmail,
    # since it does not add a helpful header like exim, qmail
    # or Postfix do.
    #
    my $rcvd = $self->get ('Received');
    $rcvd =~ s/\n[ \t]+/ /gs;
    $rcvd =~ s/\n+/\n/gs;

    my @rcvdlines = split (/\n/, $rcvd, 4); pop @rcvdlines; # forget last one
    my @rcvdaddrs = ();
    foreach my $line (@rcvdlines) {
      if ($line =~ / for (\S+\@\S+);/) { push (@rcvdaddrs, $1); }
    }

    @addrs = $self->{main}->find_all_addrs_in_line (
	 join (" ", @rcvdaddrs)."\n" .
         $self->get ('To') .                    # std
  	 $self->get ('Apparently-To') .         # sendmail, from envelope
  	 $self->get ('Delivered-To') .          # Postfix, poss qmail
  	 $self->get ('Envelope-Recipients') .   # qmail: new-inject(1)
  	 $self->get ('Apparently-Resent-To') .  # procmailrc manpage
  	 $self->get ('X-Envelope-To') .         # procmailrc manpage
  	 $self->get ('Envelope-To') .           # exim
	 $self->get ('X-Delivered-To') .	# procmail quick start
	 $self->get ('X-Original-To') .		# procmail quick start
	 $self->get ('X-Rcpt-To') .		# procmail quick start
	 $self->get ('X-Real-To') .		# procmail quick start
	 $self->get ('Cc'));                    # std

    # those are taken from various sources; thanks to Nancy McGough,
    # who noted some in <http://www.ii.com/internet/robots/procmail/qs/#envelope>

  }

  dbg ("all '*To' addrs: ".join (" ", @addrs));
  $self->{all_to_addrs} = \@addrs;
  return @addrs;

# http://www.cs.tut.fi/~jkorpela/headers.html is useful here, also
# http://www.exim.org/pipermail/exim-users/Week-of-Mon-20001009/021672.html
}

###########################################################################

sub check_obfuscated_words {
  my ($self, $body) = @_;
  foreach my $line (@$body) {
      while ($line =~ /[\w$WORD_OBFUSCATION_CHARS]/) {
        # TODO, it seems ;)
      }
  }
}

sub check_unique_words {
  my ($self, $body, $m, $b) = @_;

  if (!defined $self->{unique_words_repeat}) {
    $self->_check_unique_words($body);
  }
  # y = mx+b where y is number of unique words needed
  my $unique = $self->{unique_words_unique};
  my $repeat = $self->{unique_words_repeat};
  my $y = ($unique + $repeat) * $m + $b;
  return ($unique > $y);
}

sub _check_unique_words {
  my ($self, $body) = @_;

  $self->{unique_words_repeat} = 0;
  $self->{unique_words_unique} = 0;
  my %count;
  for (@$body) {
    # copy to avoid changing @$body
    my $line = $_;
    # from tokenize_line in Bayes.pm
    $line =~ tr/-A-Za-z0-9,\@\*\!_'"\$.\241-\377 / /cs;
    $line =~ s/(\w)(\.{3,6})(\w)/$1 $2 $3/gs;
    $line =~ s/(\w)(\-{2,6})(\w)/$1 $2 $3/gs;
    $line =~ s/(?:^|\.\s+)([A-Z])([^A-Z]+)(?:\s|$)/ ' '.(lc $1).$2.' '/ge;
    for my $token (split(' ', $line)) {
      $count{$token}++;
    }
  }
  my $unique = 0;
  my $repeat = 0;
  for my $count (values %count) {
    $count == 1 ? $unique++ : $repeat++;
  }
  $self->{unique_words_repeat} = $repeat;
  $self->{unique_words_unique} = $unique;
}

###########################################################################

sub check_from_in_blacklist {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_from_addrs()) {
    if ($self->_check_whitelist ($self->{conf}->{blacklist_from}, $_)) {
      return 1;
    }
  }
}

sub check_to_in_blacklist {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_to_addrs()) {
    if ($self->_check_whitelist ($self->{conf}->{blacklist_to}, $_)) {
      return 1;
    }
  }
}

###########################################################################
# added by DJ

sub check_to_in_whitelist {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_to_addrs()) {
    if ($self->_check_whitelist ($self->{conf}->{whitelist_to}, $_)) {
      return 1;
    }
  }
}


###########################################################################
# added by DJ

sub check_to_in_more_spam {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_to_addrs()) {
    if ($self->_check_whitelist ($self->{conf}->{more_spam_to}, $_)) {
      return 1;
    }
  }
}


###########################################################################
# added by DJ

sub check_to_in_all_spam {
  my ($self) = @_;
  local ($_);
  foreach $_ ($self->all_to_addrs()) {
    if ($self->_check_whitelist ($self->{conf}->{all_spam_to}, $_)) {
      return 1;
    }
  }
}

###########################################################################

sub check_lots_of_cc_lines {
  my ($self) = @_;
  local ($_);
  $_ = $self->get ('Cc');
  my @count = /\n/gs;
  if ($#count > 20) { return 1; }
  return 0;
}

###########################################################################

sub check_rbl_backend {
  my ($self, $rule, $set, $rbl_server, $type, $subtest) = @_;
  local ($_);

  # First check that DNS is available, if not do not perform this check
  return 0 if $self->{conf}->{skip_rbl_checks};
  return 0 unless $self->is_dns_available();
  $self->load_resolver();
  
  dbg ("checking RBL $rbl_server, set $set", "rbl", -1);

  # ok, make a list of all the IPs in the untrusted set
  my @fullips = map { $_->{ip} } @{$self->{relays_untrusted}};

  # now, make a list of all the IPs in the external set, for use in
  # notfirsthop testing.  this will often be more IPs than found
  # in @fullips.  It includes the IPs that are trusted, but
  # not in internal_networks.
  my @fullexternal = map {
	(!$_->{internal}) ? ( $_->{ip} ) : ()
      } @{$self->{relays_trusted}};
  push (@fullexternal, @fullips);	# add untrusted set too

  # Make sure a header significantly improves results before adding here
  # X-Sender-Ip: could be worth using (very low occurance for me)
  # X-Sender: has a very low bang-for-buck for me
  my @originating = ();
  for my $header ('X-Originating-IP', 'X-Apparently-From') {
    my $str = $self->get($header);
    next unless defined $str;
    push (@originating, ($str =~ m/(IP_ADDRESS)/g));
  }

  # Let's go ahead and trim away all Reserved ips (KLC)
  # also uniq the list and strip dups. (jm)
  my @ips = $self->ip_list_uniq_and_strip_reserved (@fullips);

  # if there's no untrusted IPs, it means we trust all the open-internet
  # relays, so we can return right now.
  return 0 unless (scalar @ips + scalar @originating > 0);

  dbg("rbl: IPs found: full-external: ".join(", ", @fullips).
	" untrusted: ".join(", ", @ips).
	" originating: ".join(", ", @originating), "rbl", -3);

  if (scalar @ips + scalar @originating > 0) {
    # If name is foo-notfirsthop, check all addresses except for
    # the originating one.  Suitable for use with dialup lists, like the PDL.
    # note that if there's only 1 IP in the untrusted set, do NOT pop the
    # list, since it'd remove that one, and a legit user is supposed to
    # use their SMTP server (ie. have at least 1 more hop)!
    if ($set =~ /-notfirsthop$/)
    {
      # use the external IP set, instead of the trusted set; the user may have
      # specified some third-party relays as trusted.  Also, don't use
      # @originating; those headers are added by a phase of relaying through
      # a server like Hotmail, which is not going to be in dialup lists anyway.
      @ips = $self->ip_list_uniq_and_strip_reserved (@fullexternal);
      if (scalar @ips > 1) { pop @ips; }
    }
    # If name is foo-firsttrusted, check only the Received header just
    # after it enters our trusted networks; that's the only one we can
    # trust the IP address from (since our relay added that header).
    # And if name is foo-untrusted, check any untrusted IP address.
    elsif ($set =~ /-(first|un)trusted$/)
    {
      push(@ips, @originating);
      if ($1 eq "first") {
	@ips = ( $ips[0] );
      }
      else {
	shift @ips;
      }
    }
    else
    {
      # add originating IPs as untrusted IPs
      @ips = reverse $self->ip_list_uniq_and_strip_reserved (@ips, @originating);

      # How many IPs max you check in the received lines
      my $checklast=$self->{conf}->{num_check_received};

      if (scalar @ips > $checklast) {
	splice (@ips, $checklast);	# remove all others
      }
    }
  }
  dbg("rbl: only inspecting the following IPs: ".join(", ", @ips), "rbl", -3);

  eval {
    foreach my $ip (@ips) {
      next unless ($ip =~ /(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/);
      $self->do_rbl_lookup($rule, $set, $type, $rbl_server,
			   "$4.$3.$2.$1.$rbl_server", $subtest);
    }
  };

  # note that results are not handled here, hits are handled directly
  # as DNS responses are harvested
  return 0;
}

sub check_rbl {
  my ($self, $rule, $set, $rbl_server, $subtest) = @_;
  $self->check_rbl_backend($rule, $set, $rbl_server, 'A', $subtest);
}

sub check_rbl_txt {
  my ($self, $rule, $set, $rbl_server, $subtest) = @_;
  $self->check_rbl_backend($rule, $set, $rbl_server, 'TXT', $subtest);
}

# run for first message 
sub check_rbl_sub {
  my ($self, $rule, $set, $subtest) = @_;

  return 0 if $self->{conf}->{skip_rbl_checks};
  return 0 unless $self->is_dns_available();

  $self->register_rbl_subtest($rule, $set, $subtest);
}

# backward compatibility
sub check_rbl_results_for {
  #warn "check_rbl_results_for() is deprecated, use check_rbl_sub()\n";
  check_rbl_sub(@_);
}

# check a RBL if a message is Habeas SWE
sub check_rbl_swe {
  my ($self, $rule, $set, $rbl_server, $subtest) = @_;

  if (!defined $self->{habeas_swe}) {
    $self->message_is_habeas_swe();
  }
  if (defined $self->{habeas_swe} && $self->{habeas_swe}) {
    $self->check_rbl_backend($rule, $set, $rbl_server, 'A', $subtest);
  }
  return 0;
}

# this only checks the address host name and not the domain name because
# using the domain name had much worse results for dsn.rfc-ignorant.org
sub check_rbl_from_host {
  my ($self, $rule, $set, $rbl_server) = @_;

  return 0 if $self->{conf}->{skip_rbl_checks};
  return 0 unless $self->is_dns_available();

  my %hosts;
  for my $from ($self->all_from_addrs()) {
    if ($from =~ m/\@(\S+\.\S+)/) {
      $hosts{lc($1)} = 1;
    }
  }
  return unless scalar keys %hosts;

  $self->load_resolver();
  for my $host (keys %hosts) {
    $self->do_rbl_lookup($rule, $set, 'A', $rbl_server, "$host.$rbl_server");
  }
}

sub ip_list_uniq_and_strip_reserved {
  my ($self, @origips) = @_;
  my @ips = ();
  my %seen = ();
  foreach my $ip (@origips) {
    next unless $ip;
    next if (exists ($seen{$ip})); $seen{$ip} = 1;
    next if ($ip =~ /IP_IN_RESERVED_RANGE/o);
    push(@ips, $ip);
  }
  return @ips;
}

###########################################################################

sub check_for_unique_subject_id {
  my ($self) = @_;
  local ($_);
  $_ = lc $self->get ('Subject');
  study;

  my $id = 0;
  if (/[-_\.\s]{7,}([-a-z0-9]{4,})$/
	|| /\s{10,}(?:\S\s)?(\S+)$/
	|| /\s{3,}[-:\#\(\[]+([-a-z0-9]{4,})[\]\)]+$/
	|| /\s{3,}[:\#\(\[]*([a-f0-9]{4,})[\]\)]*$/
	|| /\s{3,}[-:\#]([a-z0-9]{5,})$/
	|| /[\s._]{3,}([^0\s._]\d{3,})$/
	|| /[\s._]{3,}\[(\S+)\]$/

        # (7217vPhZ0-478TLdy5829qicU9-0@26) and similar
        || /\(([-\w]{7,}\@\d+)\)$/

        # Seven or more digits at the end of a subject is almost certainly a id
        || /\b(\d{7,})\s*$/

        # stuff at end of line after "!" or "?" is usually an id
        || /[!\?]\s*(\d{4,}|\w+(-\w+)+)\s*$/

        # 9095IPZK7-095wsvp8715rJgY8-286-28 and similar
        || /\b(\w{7,}-\w{7,}(-\w+)*)\s*$/

        # #30D7 and similar
        || /\s#\s*([a-f0-9]{4,})\s*$/
     )
  {
    $id = $1;
    # exempt online purchases
    if ($id =~ /\d{5,}/
	&& /(?:item|invoice|order|number|confirmation).{1,6}\Q$id\E\s*$/)
    {
      $id = 0;
    }

    # for the "foo-bar-baz" case, otherwise it won't
    # be found in the dict:
    $id =~ s/-//;
  }

  return ($id && !$self->word_is_in_dictionary($id));
}

# word_is_in_dictionary()
#
# See if the word looks like an English word, by checking if each triplet
# of letters it contains is one that can be found in the English language.
# Does not include triplets only found in proper names, or in the Latin
# and Greek terms that might be found in a larger dictionary

my %triplets = ();
my $triplets_loaded = 0;

sub word_is_in_dictionary {
  my ($self, $word) = @_;
  local ($_);
  local $/ = "\n";		# Ensure $/ is set appropriately

  # $word =~ tr/A-Z/a-z/;	# already done by this stage
  $word =~ s/^\s+//;
  $word =~ s/\s+$//;

  # If it contains a digit, dash, etc, it's not a valid word.
  # Don't reject words like "can't" and "I'll"
  return 0 if ($word =~ /[^a-z\']/);

  # handle a few common "blah blah blah (comment)" styles
  return 1 if ($word eq "ot");	# off-topic
  return 1 if ($word =~ /(?:linux|nix|bsd)/); # not in most dicts
  return 1 if ($word =~ /(?:whew|phew|attn|tha?nx)/);  # not in most dicts

  my $word_len = length($word);

  # Unique IDs probably aren't going to be only one or two letters long
  return 1 if ($word_len < 3);

  if (!$triplets_loaded) {
    # take a copy to avoid modifying the real one
    my @default_triplets_path = @Mail::SpamAssassin::default_rules_path;
    @default_triplets_path = map { s,$,/triplets.txt,; $_; }
				    @default_triplets_path;
    my $filename = $self->{main}->first_existing_path (@default_triplets_path);

    if (!defined $filename) {
      dbg("failed to locate the triplets.txt file");
      return 1;
    }

    if (!open (TRIPLETS, "<$filename")) {
      dbg ("failed to open '$filename', cannot check dictionary");
      return 1;
    }

    while(<TRIPLETS>) {
      chomp;
      $triplets{$_} = 1;
    }
    close(TRIPLETS);

    $triplets_loaded = 1;
  } # if (!$triplets_loaded)


  my $i;

  for ($i = 0; $i < ($word_len - 2); $i++) {
    my $triplet = substr($word, $i, 3);
    if (!$triplets{$triplet}) {
      dbg ("Unique ID: Letter triplet '$triplet' from word '$word' not valid");
      return 0;
    }
  } # for ($i = 0; $i < ($word_len - 2); $i++)

  # All letter triplets in word were found to be valid
  return 1;
}

sub get_address_commonality_ratio {
  my ($self, $addr1, $addr2) = @_;


  # Ignore "@" and ".".  "@" will always be the same in both, and the
  # number of "." will almost always be the same
  $addr1 =~ s/[\@\.]//g;
  $addr2 =~ s/[\@\.]//g;

  my %counts1 = ();
  my %counts2 = ();

  foreach ( split(//, lc $addr1) ) {
    $counts1{$_}++;
  }
  foreach ( split(//, lc $addr2) ) {
    $counts2{$_}++;
  }

  my $different = 0;
  my $same      = 0;
  my $unique    = 0;
  my $char;
  my @chars     = keys %counts1;

  # Extract unique characters, and make the two hashes have the same
  # set of keys
  foreach $char (@chars) {
    if (!defined ($counts2{$char})) {
      $unique += $counts1{$char};
      delete ($counts1{$char});
    }
  }

  @chars = keys %counts2;

  foreach $char (@chars) {
    if (!defined ($counts1{$char})) {
      $unique += $counts2{$char};
      delete ($counts2{$char});
    }
  }

  # Hashes now have identical sets of keys; count the differences
  # between the values.
  @chars = keys %counts1;

  foreach $char (@chars) {
    my $count1 = $counts1{$char} || 0.0;
    my $count2 = $counts2{$char} || 0.0;

    if ($count1 == $count2) {
      $same += $count1;
    }
    else {
      $different += abs($count1 - $count2);
    }
  }

  $different += $unique / 2.0;

  $same ||= 1.0;
  my $ratio = $different / $same;

  #print STDERR "addrcommonality $addr1/$addr2($different<$unique>/$same)"
  # . " = $ratio\n";

  return $ratio;
}

###########################################################################

sub check_for_forged_gw05_received_headers {
  my ($self) = @_;
  local ($_);

  my $rcv = $self->get ('Received');

  # e.g.
  # Received: from mail3.icytundra.com by gw05 with ESMTP; Thu, 21 Jun 2001 02:28:32 -0400
  my ($h1, $h2) = ($rcv =~ 
  	m/\nfrom\s(\S+)\sby\s(\S+)\swith\sESMTP\;\s+\S\S\S,\s+\d+\s+\S\S\S\s+
			\d{4}\s+\d\d:\d\d:\d\d\s+[-+]*\d{4}\n$/xs);

  if (defined ($h1) && defined ($h2) && $h2 !~ /\./) {
    return 1;
  }

  0;
}

###########################################################################

sub check_for_faraway_charset {
  my ($self, $body) = @_;

  my $type = $self->get ('Content-Type');

  my @locales = $self->get_my_locales();

  return 0 if grep { $_ eq "all" } @locales;

  $type = get_charset_from_ct_line ($type);

  if (defined $type &&
    !Mail::SpamAssassin::Locales::is_charset_ok_for_locales
		    ($type, @locales))
  {
    # sanity check.  Some charsets (e.g. koi8-r) include the ASCII
    # 7-bit charset as well, so make sure we actually have a high
    # number of 8-bit chars in the body text first.

    $body = join ("\n", @$body);
    if ($self->are_more_high_bits_set ($body)) {
      return 1;
    }
  }

  0;
}

sub check_for_faraway_charset_in_headers {
  my ($self) = @_;
  my $hdr;

  my @locales = $self->get_my_locales();

  return 0 if grep { $_ eq "all" } @locales;

  for my $h (qw(From Subject)) {
    my @hdrs = $self->get ("$h:raw");
    if ($#hdrs >= 0) {
      $hdr = join (" ", @hdrs);
    } else {
      $hdr = '';
    }
    while ($hdr =~ /=\?(.+?)\?.\?.*?\?=/g) {
      Mail::SpamAssassin::Locales::is_charset_ok_for_locales($1, @locales)
	  or return 1;
    }
  }
  0;
}

sub get_charset_from_ct_line {
  my $type = shift;
  if ($type =~ /charset="([^"]+)"/i) { return $1; }
  if ($type =~ /charset='([^']+)'/i) { return $1; }
  if ($type =~ /charset=(\S+)/i) { return $1; }
  return undef;
}

sub get_my_locales {
  my ($self) = @_;

  my @locales = split (' ', $self->{conf}->{ok_locales});
  my $lang = $ENV{'LC_ALL'};
  $lang ||= $ENV{'LANGUAGE'};
  $lang ||= $ENV{'LC_MESSAGES'};
  $lang ||= $ENV{'LANG'};
  push (@locales, $lang) if defined($lang);
  return @locales;
}

###########################################################################

sub _check_for_round_the_world_received {
  my ($self) = @_;
  my ($relayer, $relayerip, $relay);

  $self->{round_the_world_revdns} = 0;
  $self->{round_the_world_helo} = 0;
  my $rcvd = $self->get ('Received');

  # TODO: use new Received header parser

  # trad sendmail/postfix fmt:
  # Received: from hitower.parkgroup.ru (unknown [212.107.207.26]) by
  #     mail.netnoteinc.com (Postfix) with ESMTP id B8CAC11410E for
  #     <me@netnoteinc.com>; Fri, 30 Nov 2001 02:42:05 +0000 (Eire)
  # Received: from fmx1.freemail.hu ([212.46.197.200]) by hitower.parkgroup.ru
  #     (Lotus Domino Release 5.0.8) with ESMTP id 2001113008574773:260 ;
  #     Fri, 30 Nov 2001 08:57:47 +1000
  if ($rcvd =~ /
  	\nfrom\b.{0,20}\s(\S+\.${CCTLDS_WITH_LOTS_OF_OPEN_RELAYS})\s\(.{0,200}
  	\nfrom\b.{0,20}\s([-_A-Za-z0-9.]+)\s.{0,30}\[(IPV4_ADDRESS)\]
  /osix) { $relay = $1; $relayer = $2; $relayerip = $3; goto gotone; }

  return 0;

gotone:
  my $revdns = $self->lookup_ptr ($relayerip);
  if (!defined $revdns) { $revdns = '(unknown)'; }

  dbg ("round-the-world: mail relayed through $relay by ".	
  	"$relayerip (HELO $relayer, rev DNS says $revdns)");

  if ($revdns =~ /\.${ROUND_THE_WORLD_RELAYERS}$/oi) {
    dbg ("round-the-world: yep, I think so (from rev dns)");
    $self->{round_the_world_revdns} = 1;
    return;
  }

  if ($relayer =~ /\.${ROUND_THE_WORLD_RELAYERS}$/oi) {
    dbg ("round-the-world: yep, I think so (from HELO)");
    $self->{round_the_world_helo} = 1;
    return;
  }

  dbg ("round-the-world: probably not");
  return;
}

sub check_for_round_the_world_received_helo {
  my ($self) = @_;
  if (!defined $self->{round_the_world_helo}) {
    $self->_check_for_round_the_world_received();
  }
  if ($self->{round_the_world_helo}) { return 1; }
  return 0;
}

sub check_for_round_the_world_received_revdns {
  my ($self) = @_;
  if (!defined $self->{round_the_world_revdns}) {
    $self->_check_for_round_the_world_received();
  }
  if ($self->{round_the_world_revdns}) { return 1; }
  return 0;
}

###########################################################################

sub check_for_shifted_date {
  my ($self, $min, $max) = @_;

  if (!exists $self->{date_diff}) {
    $self->_check_date_diff();
  }
  return (($min eq 'undef' || $self->{date_diff} >= (3600 * $min)) &&
	  ($max eq 'undef' || $self->{date_diff} < (3600 * $max)));
}

sub received_within_months {
  # filters out some false positives in old corpus mail - Allen
  my($self,$min,$max) = @_;

  if (!exists($self->{date_received})) {
    $self->_check_date_received();
  }
  my $diff = time() - $self->{date_received};

  # 365.2425 * 24 * 60 * 60 = 31556952 = seconds in year (including leap)

  if (((! defined($min)) || ($min eq 'undef') ||
       ($diff >= (31556952 * ($min/12)))) &&
      ((! defined($max)) || ($max eq 'undef') ||
       ($diff < (31556952 * ($max/12))))) {
    return 1;
  } else {
    return 0;
  }
}

sub _get_date_header_time {
  my $self = $_[0];

  my $time;
  # a Resent-Date: header takes precedence over any Date: header
  for my $header ('Resent-Date', 'Date') {
    my $date = $self->get($header);
    if (defined($date) && length($date)) {
      chomp($date);
      $time = Mail::SpamAssassin::Util::parse_rfc822_date($date);
    }
    last if defined($time);
  }
  if (defined($time)) {
    $self->{date_header_time} = $time;
  }
  else {
    $self->{date_header_time} = undef;
  }
}

sub _get_received_header_times {
  my $self = $_[0];

  $self->{received_header_times} = [ () ];
  $self->{received_fetchmail_time} = undef;

  my(@received);
  my $received = $self->get('Received');
  if (defined($received) && length($received)) {
    @received = grep {$_ =~ m/\S/} (split(/\n/,$received));
  }
  # if we have no Received: headers, chances are we're archived mail
  # with a limited set of headers
  if (!scalar(@received)) {
    return;
  }

  # handle fetchmail headers
  my(@local);
  if (($received[0] =~
      m/\bfrom (?:localhost\s|(?:\S+ ){1,2}\S*\b127\.0\.0\.1\b)/) ||
      ($received[0] =~ m/qmail \d+ invoked by uid \d+/)) {
    push @local, (shift @received);
  }
  if (scalar(@received) &&
      ($received[0] =~ m/\bby localhost with \w+ \(fetchmail-[\d.]+/)) {
    push @local, (shift @received);
  }
  elsif (scalar(@local)) {
    unshift @received, (shift @local);
  }

  my $rcvd;

  if (scalar(@local)) {
    my(@fetchmail_times);
    foreach $rcvd (@local) {
      if ($rcvd =~ m/(\s.?\d+ \S\S\S \d+ \d+:\d+:\d+ \S+)/) {
	my $date = $1;
	dbg ("trying Received fetchmail header date for real time: $date",
	     "datediff", -2);
	my $time = Mail::SpamAssassin::Util::parse_rfc822_date($date);
	if (defined($time) && (time() >= $time)) {
	  dbg ("time_t from date=$time, rcvd=$date", "datediff", -2);
	  push @fetchmail_times, $time;
	}
      }
    }
    if (scalar(@fetchmail_times) > 1) {
      $self->{received_fetchmail_time} =
       (sort {$b <=> $a} (@fetchmail_times))[0];
    } elsif (scalar(@fetchmail_times)) {
      $self->{received_fetchmail_time} = $fetchmail_times[0];
    }
  }

  my(@header_times);
  foreach $rcvd (@received) {
    if ($rcvd =~ m/(\s.?\d+ \S\S\S \d+ \d+:\d+:\d+ \S+)/) {
      my $date = $1;
      dbg ("trying Received header date for real time: $date", "datediff", -2);
      my $time = Mail::SpamAssassin::Util::parse_rfc822_date($date);
      if (defined($time)) {
	dbg ("time_t from date=$time, rcvd=$date", "datediff", -2);
	push @header_times, $time;
      }
    }
  }

  if (scalar(@header_times)) {
    $self->{received_header_times} = [ @header_times ];
  } else {
    dbg ("no dates found in Received headers", "datediff", -1);
  }
}

sub _check_date_received {
  my $self = $_[0];

  my(@dates_poss);

  $self->{date_received} = 0;

  if (!exists($self->{date_header_time})) {
    $self->_get_date_header_time();
  }

  if (defined($self->{date_header_time})) {
    push @dates_poss, $self->{date_header_time};
  }

  if (!exists($self->{received_header_times})) {
    $self->_get_received_header_times();
  }
  my(@received_header_times) = @{ $self->{received_header_times} };
  if (scalar(@received_header_times)) {
    push @dates_poss, $received_header_times[0];
  }
  if (defined($self->{received_fetchmail_time})) {
    push @dates_poss, $self->{received_fetchmail_time};
  }

  if (defined($self->{date_header_time}) && scalar(@received_header_times)) {
    if (!exists($self->{date_diff})) {
      $self->_check_date_diff();
    }
    push @dates_poss, $self->{date_header_time} - $self->{date_diff};
  }

  if (scalar(@dates_poss)) {	# use median
    $self->{date_received} = (sort {$b <=> $a}
			      (@dates_poss))[int($#dates_poss/2)];
    dbg("Date chosen from message: " .
	scalar(localtime($self->{date_received})), "datediff", -2);
  } else {
    dbg("no dates found in message", "datediff", -1);
  }
}

sub _check_date_diff {
  my $self = $_[0];

  $self->{date_diff} = 0;

  if (!exists($self->{date_header_time})) {
    $self->_get_date_header_time();
  }

  if (!defined($self->{date_header_time})) {
    return;			# already have tests for this
  }

  if (!exists($self->{received_header_times})) {
    $self->_get_received_header_times();
  }
  my(@header_times) = @{ $self->{received_header_times} };

  if (!scalar(@header_times)) {
    return;			# archived mail?
  }

  my(@diffs) = map {$self->{date_header_time} - $_} (@header_times);

  # if the last Received: header has no difference, then we choose to
  # exclude it
  if ($#diffs > 0 && $diffs[$#diffs] == 0) {
    pop(@diffs);
  }

  # use the date with the smallest absolute difference
  # (experimentally, this results in the fewest false positives)
  @diffs = sort { abs($a) <=> abs($b) } @diffs;
  $self->{date_diff} = $diffs[0];
}

###########################################################################

sub subject_is_all_caps {
   my ($self) = @_;
   my $subject = $self->get('Subject');

   $subject =~ s/^\s+//;
   $subject =~ s/\s+$//;
   return 0 if $subject !~ /\s/;	# don't match one word subjects
   return 0 if (length $subject < 10);  # don't match short subjects
   $subject =~ s/[^a-zA-Z]//g;		# only look at letters

   # now, check to see if the subject is encoded using a non-ASCII charset.
   # If so, punt on this test to avoid FPs.  We just list the known charsets
   # this test will FP on, here.
   my $subjraw = $self->get('Subject:raw');
   if ($subjraw =~ /^=\?${CHARSETS_LIKELY_TO_FP_AS_CAPS}\?/i) {
     return 0;
   }

   return length($subject) && ($subject eq uc($subject));
}

###########################################################################

sub message_from_bugzilla {
  my ($self) = @_;

  my $all    = $self->get('ALL');
  
  # Let's look for a Bugzilla Subject...
  if ($all   =~ /^Subject: [^\n]{0,10}\[Bug \d+\] /m && (
        # ... in combination with either a Bugzilla message header...
        $all =~ /^X-Bugzilla-[A-Z][a-z]+: /m ||
        # ... or sender.
        $all =~ /^From: bugzilla/mi
     )) {
    return 1;
  }

  return 0;
}

sub message_from_debian_bts {
  my ($self)  = @_;

  my  $all    = $self->get('ALL');

  # This is the main case; A X-<Project>-PR-Message header exists and the
  # Subject looks "buggy". Watch out: The DBTS is used not only by Debian
  # but by other <Project>s, eg. KDE, too.
  if ($all    =~ /^X-[A-Za-z0-9]+-PR-Message: [a-z-]+ \d+$/m &&
      $all    =~ /^Subject: Bug#\d+: /m) {
    return 1;
  }
  # Sometimes the DBTS sends out messages which don't include the X- header.
  # In this case we look if the message is From a DBTS account and Subject
  # and Message-Id look good.
  elsif ($all =~ /^From: owner\@/mi &&
         $all =~ /^Subject: Processed(?: \([^)]+\))?: /m &&
         $all =~ /^Message-ID: <handler\./m) {
    return 1;
  }

  return 0;
}

sub message_is_habeas_swe {
  my ($self) = @_;

  return $self->{habeas_swe} if defined $self->{habeas_swe};

  $self->{habeas_swe} = 0;

  my $text = '';
  for (my $i = 1; $i <= 9; $i++) {
    $text .= (lc($self->get("X-Habeas-SWE-$i")) || return 0);
  }
  if ($text) {
    $text =~ s/\s+/ /g;
    $text =~ s/^\s|\s$//g;
    $text =~ s@/?>@/>@;
    $self->{habeas_swe} = (sha1($text) eq '76c65d9eb65e572166a08b50fd197b29af09d43a');
  }

  return $self->{habeas_swe};
}

###########################################################################
# BODY TESTS:
###########################################################################
  
sub body_charset_is_likely_to_fp {
  my ($self) = @_;

  # check for charsets where this test will FP -- iso-2022-jp, gb2312,
  # koi8-r etc.
  #
  $self->_check_attachments unless exists $self->{mime_checked_attachments};
  my @charsets = ();
  my $type = $self->get ('Content-Type');
  $type = get_charset_from_ct_line ($type);
  if (defined $type) {
    push (@charsets, $type);
  }
  if (defined $self->{mime_html_charsets}) {
    push (@charsets, split (' ', $self->{mime_html_charsets}));
  }

  foreach my $charset (@charsets) {
    if ($charset =~ /^${CHARSETS_LIKELY_TO_FP_AS_CAPS}$/) {
      return 1;
    }
  }
  return 0;
}

sub check_for_uppercase {
  my ($self, $body, $min, $max) = @_;
  local ($_);

  if (exists $self->{uppercase}) {
    return ($self->{uppercase} > $min && $self->{uppercase} <= $max);
  }

  if ($self->body_charset_is_likely_to_fp()) {
    $self->{uppercase} = 0; return 0;
  }

  # Dec 20 2002 jm: trade off some speed for low memory footprint, by
  # iterating over the array computing sums, instead of joining the
  # array into a giant string and working from that.

  my $len = 0;
  my $lower = 0;
  my $upper = 0;
  foreach (@{$body}) {
    # examine lines in the body that have an intermediate space
    next unless /\S\s+\S/;
    # strip out lingering base64 (currently possible for forwarded messages)
    next if /^(?:[A-Za-z0-9+\/=]{60,76} ){2}/;

    my $line = $_;	# copy so we don't muck up the original

    # remove shift-JIS charset codes
    $line =~ s/\x1b\$B.*\x1b\(B//gs;

    $len += length($line);

    # count numerals as lower case, otherwise 'date|mail' is spam
    $lower += ($line =~ tr/a-z0-9//d);
    $upper += ($line =~ tr/A-Z//);
  }

  # report only on mails above a minimum size; otherwise one
  # or two acronyms can throw it off
  if ($len < 200) {
    $self->{uppercase} = 0;
    return 0;
  }
  if (($upper + $lower) == 0) {
    $self->{uppercase} = 0;
  } else {
    $self->{uppercase} = ($upper / ($upper + $lower)) * 100;
  }

  return ($self->{uppercase} > $min && $self->{uppercase} <= $max);
}

sub check_for_yelling {
  my ($self, $body) = @_;
    
  if (exists $self->{num_yelling_lines}) {
    return $self->{num_yelling_lines} > 0;
  }
  if ($self->body_charset_is_likely_to_fp()) {
    $self->{num_yelling_lines} = 0; return 0;
  }

  # Dec 20 2002 jm: trade off some speed for low memory footprint, by
  # iterating over the array computing sums, instead of joining the
  # array into a giant string and working from that.

  my $num_lines = 0;
  foreach my $line (@{$body}) {
    # lines in the body that have some non-letters
    next unless ($line =~ /[^A-Za-z]/);

    # Try to eliminate lines which might be newsletter section headers,
    # which are often in all caps; we do this by removing most lines
    # that start with whitespace.  However, some spam will match
    # this as well, so keep lines which have "!" or "$$" (spam often
    # has a yelling line indent with spaces, but surround by dollar
    # signs), or a "." which appears to end a sentence.
    next unless ($line =~ /^\S|!|\$\$|\.(?:\s|$)/);

    $_ = $line;		 # copy to preserve originals

    # Get rid of everything but upper AND lower case letters
    tr/A-Za-z \t//cd;

    # Remove leading and trailing whitespace
    s/^\s+//; s/\s+$//;

    # Now that we have a mixture of upper and lower case, see if it's
    # 1) All upper case
    # 2) 20 or more characters in length
    # 3) Has at least one whitespace in it; we don't want to catch things
    #    like lines of genetic data ("...AGTAGC...")
    if (/^[A-Z\s]{20,}$/ && /\s/) {
      $num_lines++;
    }
  }

  $self->{num_yelling_lines} = $num_lines;

  return ($num_lines > 0);
}

sub check_for_num_yelling_lines {
  my ($self, $body, $threshold) = @_;
    
  $self->check_for_yelling($body);
    
  return ($self->{num_yelling_lines} >= $threshold);
}

# UNWANTED_LANGUAGE_BODY
sub check_language {
  my ($self, $body) = @_;
  $self->_check_language();
  return $self->{undesired_language_body};
}

# UNWANTED_LANGUAGE_BODY
sub _check_language {
  my ($self, $body) = @_;

  if (defined $self->{undesired_language_body}) {
    return $self->{undesired_language_body};
  }

  $self->{undesired_language_body} = 0;
  my @languages = split (' ', $self->{conf}->{ok_languages});

  if (grep { $_ eq "all" } @languages) {
    return $self->{undesired_language_body};
  }

  my @matches = @{$self->{msg}->{metadata}->{textcat_matches}};

  # not able to get a match, assume it's okay
  if (! @matches) {
    $self->{undesired_language_body} = 0;
    return $self->{undesired_language_body};
  }

  # map of languages that are very often mistaken for another, perhaps with
  # more than 0.02% false positives.  This is used when we're less certain
  # about the result.
  my $len = $self->{msg}->{metadata}->{languages_body_len};
  my %mistakable;
  if ($len < 1024 * (scalar @matches)) {
    $mistakable{sco} = 'en';
  }

  # see if any matches are okay
  foreach my $match (@matches) {
    $match =~ s/\..*//;
    $match = $mistakable{$match} if exists $mistakable{$match};
    foreach my $language (@languages) {
      $language = $mistakable{$language} if exists $mistakable{$language};
      if ($match eq $language) {
	$self->{undesired_language_body} = 0;
	return $self->{undesired_language_body};
      }
    }
  }
  $self->{undesired_language_body} = 1;
  return $self->{undesired_language_body};
}

sub check_for_body_8bits {
  my ($self, $body) = @_;

  my @languages = split (' ', $self->{conf}->{ok_languages});

  for (@languages) {
    return 0 if $_ eq "all";
    # this list is initially conservative, it includes any language with
    # a common n-gram sequence of 2+ consecutive bytes matching [\x80-\xff]
    # here are the one more likely to be removed: cs=czech, et=estonian,
    # fi=finnish, hi=hindi, is=icelandic, pt=portuguese, tr=turkish,
    # uk=ukrainian, vi=vietnamese
    return 0 if /^(?:am|ar|be|bg|cs|el|et|fa|fi|he|hi|hy|is|ja|ka|ko|mr|pt|ru|ta|th|tr|uk|vi|yi|zh)$/;
  }

  foreach my $line (@$body) {
    return 1 if $line =~ /[\x80-\xff]{8,}/;
  }
  return 0;
}

###########################################################################
# MIME/uuencode attachment tests
###########################################################################

# generic test version
sub check_for_mime {
  my ($self, undef, $test) = @_;

  $self->_check_attachments unless exists $self->{$test};
  return $self->{$test};
}

# any text/html MIME part
sub check_for_mime_html {
  my ($self) = @_;

  my $ctype = $self->get('Content-Type');
  return 1 if (defined($ctype) && $ctype =~ m@text/html@i);

  $self->_check_attachments unless exists $self->{mime_body_html_count};
  return ($self->{mime_body_html_count} > 0);
}

# Plain text without some other type of MIME text part
sub check_for_mime_text_only {
  my ($self) = @_;

  my $ctype = $self->get('Content-Type');
  return 1 if (defined($ctype) && $ctype =~ m@text/plain@i);

  $self->_check_attachments unless exists $self->{mime_body_html_count};
  return ($self->{mime_body_html_count} == 0 &&
	  $self->{mime_body_text_count} > 0);
}

# HTML without some other type of MIME text part
sub check_for_mime_html_only {
  my ($self) = @_;

  my $ctype = $self->get('Content-Type');
  return 1 if (defined($ctype) && $ctype =~ m@text/html@i);

  $self->_check_attachments unless exists $self->{mime_body_html_count};
  return ($self->{mime_body_html_count} > 0 &&
	  $self->{mime_body_text_count} == 0);
}

sub check_for_mime_excessive_qp {
  my ($self, undef, $min) = @_;

  $self->_check_attachments unless exists $self->{mime_qp_ratio};

  return $self->{mime_qp_ratio} >= $min;
}

sub check_mime_multipart_ratio {
  my ($self, undef, $min, $max) = @_;

  $self->_check_attachments unless exists $self->{mime_multipart_alternative};

  return ($self->{mime_multipart_ratio} >= $min &&
	  $self->{mime_multipart_ratio} < $max);
}

sub _check_mime_header {
  my ($self, $ctype, $cte, $cd, $charset, $name) = @_;

  $charset ||= '';

  if ($ctype eq 'text/html') {
    $self->{mime_body_html_count}++;
  }
  elsif ($ctype =~ m@^text@i) {
    $self->{mime_body_text_count}++;
  }

  if ($cte =~ /base64/) {
    $self->{mime_base64_count}++;
  }
  elsif ($cte =~ /quoted-printable/) {
    $self->{mime_qp_count}++;
  }

  if ($ctype =~ /^text/ &&
      $cte =~ /base64/ &&
      $charset !~ /utf-8/ &&
      !($cd && $cd =~ /^(?:attachment|inline)/))
  {
    $self->{mime_base64_encoded_text} = 1;
  }

  if ($cte =~ /base64/ && !$name) {
    $self->{mime_base64_no_name} = 1;
  }

  if (!$name &&
      $cte =~ /base64/ &&
      $charset =~ /\b(?:us-ascii|iso-8859-(?:[12349]|1[0345])|windows-(?:125[0247]))\b/)
  {
    $self->{mime_base64_latin} = 1;
  }

  if ($cte =~ /quoted-printable/ && $cd =~ /inline/ && !$charset) {
    $self->{mime_qp_inline_no_charset} = 1;
  }

  if ($ctype eq 'text/html' &&
      !(defined($charset) && $charset) &&
      !($cd && $cd =~ /^(?:attachment|inline)/))
  {
    $self->{mime_html_no_charset} = 1;
  }

  if ($charset =~ /[a-z]/i) {
    if (defined $self->{mime_html_charsets}) {
      $self->{mime_html_charsets} .= " ".$charset;
    } else {
      $self->{mime_html_charsets} = $charset;
    }

    if (! $self->{mime_faraway_charset}) {
      my @l = $self->get_my_locales();

      if (!(grep { $_ eq "all" } @l) &&
	  !Mail::SpamAssassin::Locales::is_charset_ok_for_locales($charset, @l))
      {
	$self->{mime_faraway_charset} = 1;
      }
    }
  }

  if ($name && $ctype ne "application/octet-stream") {
    # MIME_SUSPECT_NAME triggered here
    $name =~ s/.*\.//;
    $ctype =~ s@/(x-|vnd\.)@/@;

    if (((($name eq "txt") || ($name =~ /^[px]?html?$/) ||
	  ($name eq "xml")) &&
	 ($ctype !~
	  m@^text/(?:plain|[px]?html?|english|sgml|xml|enriched|richtext)@) &&
	 ($ctype !~ m@^message/external-body@)) # RFC-Editor emails...
	|| ((($name =~ /^(?:jpe?g|tiff?)$/) || ($name eq "gif") ||
	     ($name eq "png"))
	    && ($ctype !~ m@^image/@)
	    && ($ctype !~ m@^application/mac-binhex@))
	|| ($name eq "vcf" && $ctype ne "text/vcard")
	|| ($name =~ /^(?:bat|com|exe|pif|scr|swf|vbs)$/
	    && $ctype !~ m@^application/@)
	|| ($name eq "doc" && $ctype !~ m@^application/.*word$@)
	|| ($name eq "ppt" && $ctype !~ m@^application/.*(?:powerpoint|ppt)$@)
	|| ($name eq "xls" && $ctype !~ m@^application/.*excel$@)
       )
    {
       $self->{mime_suspect_name} = 1;
    }
  }
}

sub _check_attachments {
  my ($self) = @_;

  # MIME status
  my $where = -1;		# -1 = start, 0 = nowhere, 1 = header, 2 = body
  my %state;			# state of each MIME part
  my $qp_bytes = 0;		# total bytes in QP regions
  my $qp_count = 0;		# QP-encoded bytes in QP regions
  my @part_bytes;		# MIME part total bytes
  my @part_type;		# MIME part types

  # MIME header information
  my $part = -1;		# MIME part index

  # regular expressions
  my $re_cte = qr/^Content-Transfer-Encoding:\s*(.+)/i;
  my $re_cd = qr/^Content-Disposition:\s*(.+)/i;

  # indicate the scan has taken place
  $self->{mime_checked_attachments} = 1;

  # results
  $self->{mime_base64_blanks} = 0;
  $self->{mime_base64_count} = 0;
  $self->{mime_base64_encoded_text} = 0;
  $self->{mime_base64_illegal} = 0;
  $self->{mime_base64_latin} = 0;
  $self->{mime_base64_no_name} = 0;
  $self->{mime_body_html_count} = 0;
  $self->{mime_body_text_count} = 0;
  $self->{mime_faraway_charset} = 0;
  $self->{mime_html_no_charset} = 0;
  $self->{mime_missing_boundary} = 0;
  $self->{mime_multipart_alternative} = 0;
  $self->{mime_multipart_ratio} = 1.0;
  $self->{mime_qp_count} = 0;
  $self->{mime_qp_illegal} = 0;
  $self->{mime_qp_inline_no_charset} = 0;
  $self->{mime_qp_long_line} = 0;
  $self->{mime_qp_ratio} = 0;
  $self->{mime_suspect_name} = 0;

  # Get all parts ...
  foreach my $p ( $self->{msg}->find_parts(qr/./) ) {
    # message headers
    my($ctype, $boundary, $charset, $name) = Mail::SpamAssassin::Util::parse_content_type($p->get_header("content-type"));

    if ($ctype eq 'multipart/alternative') {
      $self->{mime_multipart_alternative} = 1;
    }

    my $cte = $self->get('Content-Transfer-Encoding');
    if ($cte =~ /$re_cte/) { $cte = lc($1); }
    chomp($cte = defined($cte) ? $cte : "");

    my $cd = $self->get('Content-Disposition');
    if ($cd =~ /$re_cd/) { $cd = lc($1); }
    chomp($cd = defined($cd) ? $cd : "");

    $self->_check_mime_header($ctype, $cte, $cd, $charset, $name);

    # If we're not in a leaf node in the tree, there will be no raw
    # section, so skip it.
    if ( ! $p->is_leaf() ) {
      next;
    }

    $part++;
    $part_type[$part] = $ctype;
    $part_bytes[$part] = 0 if $cd !~ /attachment/;

    my $previous = '';
    foreach ( @{$p->raw()} ) {
      if ( $cte =~ /base64/i ) {
        if ($previous =~ /^\s*$/ && /^\s*$/) {
	  $self->{mime_base64_blanks} = 1;
        }
        if (m@[^A-Za-z0-9+/=\n]@ || /=[^=\s]/) {
	  $self->{mime_base64_illegal} = 1;
        }
      }

      if ($self->{mime_html_no_charset} && $ctype eq 'text/html' && defined $charset) {
	$self->{mime_html_no_charset} = 0;
      }
      if ($self->{mime_multipart_alternative} && $cd !~ /attachment/ &&
          ( $ctype eq 'text/plain' || $ctype eq 'text/html' ) ) {
	$part_bytes[$part] += length;
      }

      if ($where != 1 && $cte eq "quoted-printable" && ! /^SPAM: /) {
        if (length > 77) {
	  $self->{mime_qp_long_line} = 1;
        }
        $qp_bytes += length;
        # check for illegal substrings (RFC 2045), hexadecimal values 7F-FF and
        # control characters other than TAB, or CR and LF as parts of CRLF pairs
        if (!$self->{mime_qp_illegal} && /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\xff]/)
        {
	  $self->{mime_qp_illegal} = 1;
        }
        # count excessive QP bytes
        if (index($_, '=') != -1) {
	  # whoever wrote this next line is an evil hacker -- jm
	  my $qp = () = m/=(?:09|3[0-9ABCEF]|[2456][0-9A-F]|7[0-9A-E])/g;
	  if ($qp) {
	    $qp_count += $qp;
	    # tabs and spaces at end of encoded line are okay.  Also, multiple
	    # whitespace at the end of a line are OK, like ">=20=20=20=20=20=20".
	    my ($trailing) = m/((?:=09|=20)+)\s*$/g;
	    if ($trailing) {
	      $qp_count -= (length($trailing) / 3);
	    }
	  }
        }
      }
      $previous = $_;
    }
  }

  if ($qp_bytes) {
    $self->{mime_qp_ratio} = $qp_count / $qp_bytes;
  }
  if ($self->{mime_multipart_alternative}) {
    my $text;
    my $html;
    for (my $i = 0; $i <= $part; $i++) {
      next if !defined $part_bytes[$i];
      if (!defined($html) && $part_type[$i] eq 'text/html') {
	$html = $part_bytes[$i];
      }
      if (!defined($text) && $part_type[$i] eq 'text/plain') {
	$text = $part_bytes[$i];
      }
    }
    if (defined($text) && defined($html) && $html > 0) {
      $self->{mime_multipart_ratio} = ($text / $html);
    }
  }
  foreach my $str (keys %state) {
    if ($state{$str} != 0) {
      $self->{mime_missing_boundary} = 1;
      last;
    }
  }
}

###########################################################################
# FULL-MESSAGE TESTS:
###########################################################################

sub check_razor2 {
  my ($self) = @_;

  return 0 unless ($self->is_razor2_available());
  return $self->{razor2_result} if ( defined $self->{razor2_result} );

  # note: we don't use $fulltext. instead we get the raw message,
  # unfiltered, for razor2 to check.  ($fulltext removes MIME
  # parts etc.)
  my $full = $self->{msg}->get_pristine();
  return $self->razor2_lookup (\$full);
}

sub check_pyzor {
  my ($self, $fulltext) = @_;

  return 0 unless ($self->is_pyzor_available());
  return 0 if ($self->{already_checked_pyzor});

  $self->{already_checked_pyzor} = 1;

  # note: we don't use $fulltext. instead we get the raw message,
  # unfiltered, for pyzor to check.  ($fulltext removes MIME
  # parts etc.)
  my $full = $self->{msg}->get_pristine();
  return $self->pyzor_lookup (\$full);
}

sub check_dcc {
  my ($self, $fulltext) = @_;
  my $have_dccifd = $self->is_dccifd_available();

  return 0 unless ($have_dccifd || $self->is_dcc_available() );
  return 0 if ($self->{already_checked_dcc});

  $self->{already_checked_dcc} = 1;

  # First check if there's already a X-DCC header with value of "bulk"
  # and short-circuit if there is -- someone upstream might already have
  # checked DCC for us.
  $_ = $self->get('X-DCC-(?:[^:]+-)?Metrics');
  return 1 if /bulk/;
  
  # note: we don't use $fulltext. instead we get the raw message,
  # unfiltered, for DCC to check.  ($fulltext removes MIME
  # parts etc.)
  my $full = $self->{msg}->get_pristine();
  if ( $have_dccifd ) {
    return $self->dccifd_lookup (\$full);
  } else {
    return $self->dcc_lookup (\$full);
  }
}

###########################################################################

sub check_for_fake_aol_relay_in_rcvd {
  my ($self) = @_;
  local ($_);

  $_ = $self->get ('Received'); s/\s/ /gs;

  # this is the hostname format used by AOL for their relays. Spammers love 
  # forging it.  Don't make it more specific to match aol.com only, though --
  # there's another set of spammers who generate fake hostnames to go with
  # it!
  if (/ rly-[a-z][a-z]\d\d\./i) {
    return 0 if /\/AOL-\d+\.\d+\.\d+\)/;    # via AOL mail relay
    return 0 if /ESMTP id (?:RELAY|MAILRELAY|MAILIN)/; # AOLish
    return 1;
  }

# spam: Received: from unknown (HELO mta05bw.bigpond.com) (80.71.176.130) by
#    rly-xw01.mx.aol.com with QMQP; Sat, 15 Jun 2002 23:37:16 -0000

# non: Received: from  rly-xj02.mx.aol.com (rly-xj02.mail.aol.com [172.20.116.39]) by
#    omr-r05.mx.aol.com (v83.35) with ESMTP id RELAYIN7-0501132011; Wed, 01
#    May 2002 13:20:11 -0400

# non: Received: from logs-tr.proxy.aol.com (logs-tr.proxy.aol.com [152.163.201.132])
#    by rly-ip01.mx.aol.com (8.8.8/8.8.8/AOL-5.0.0)
#    with ESMTP id NAA08955 for <sapient-alumni@yahoogroups.com>;
#    Thu, 4 Apr 2002 13:11:20 -0500 (EST)

  return 0;
}

###########################################################################

sub check_for_to_in_subject {
  my ($self, $test) = @_;

  my $full_to = $self->get('To:addr');
  return 0 unless $full_to;

  my $subject = $self->get('Subject');

  if ($test eq "address") {
    return $subject =~ /\b\Q$full_to\E\b/i;	# "user@domain.com"
  }
  elsif ($test eq "user") {
    my $to = $full_to;
    $to =~ s/\@.*//;
    return $subject =~ /^\s*\Q$to\E,\S/i;	# "user,\S" case insensitive
  }
  return 0;
}

###########################################################################

sub check_bayes {
  my ($self, $fulltext, $min, $max) = @_;

  if (!exists ($self->{bayes_score})) {
    $self->{bayes_score} = $self->{main}->{bayes_scanner}->scan
					  ($self, $self->{msg}, $fulltext);
  }

  if (defined $self->{bayes_score} &&
      ($min == 0 || $self->{bayes_score} > $min) &&
      ($max eq "undef" || $self->{bayes_score} <= $max))
  {
      if ($self->{conf}->{detailed_bayes_score}) {
        $self->test_log(sprintf ("score: %3.4f, hits: %s",
                                 $self->{bayes_score},
                                 $self->{bayes_hits}));
      }
      else {
        $self->test_log(sprintf ("score: %3.4f", $self->{bayes_score}));
      }
      return 1;
  }
  return 0;

}

###########################################################################

sub check_outlook_message_id {
  my ($self) = @_;
  local ($_);

  my $id = $self->get('MESSAGEID');
  return 0 if $id !~ /^<[0-9a-f]{4}([0-9a-f]{8})\$[0-9a-f]{8}\$[0-9a-f]{8}\@/;

  my $timetoken = hex($1);
  my $x = 0.0023283064365387;
  my $y = 27111902.8329849;

  my $fudge = 250;

  $_ = $self->get('Date');
  $_ = Mail::SpamAssassin::Util::parse_rfc822_date($_) || 0;
  my $expected = int (($_ * $x) + $y);
  my $diff = $timetoken - $expected;
  return 0 if (abs($diff) < $fudge);

  $_ = $self->get('Received');
  /(\s.?\d+ \S\S\S \d+ \d+:\d+:\d+ \S+).*?$/;
  $_ = Mail::SpamAssassin::Util::parse_rfc822_date($_) || 0;
  $expected = int(($_ * $x) + $y);
  $diff = $timetoken - $expected;

  return (abs($diff) >= $fudge);
}

# Check the cf value of a given message and return if it's within the
# given range
sub check_razor2_range {
  my ($self,$fulltext,$min,$max) = @_;

  # If the Razor2 general test is disabled, don't continue.
  return 0 unless $self->{conf}{scores}{'RAZOR2_CHECK'};

  # If Razor2 hasn't been checked yet, go ahead and run it.
  if (!defined $self->{razor2_result}) {
    # note: we don't use $fulltext. instead we get the raw message,
    # unfiltered, for razor2 to check.  ($fulltext removes MIME
    # parts etc.)
    my $full = $self->{msg}->get_pristine();
    $self->razor2_lookup (\$full);
  }

  if ($self->{razor2_cf_score} >= $min && $self->{razor2_cf_score} <= $max) {
    $self->test_log(sprintf ("cf: %3d", $self->{razor2_cf_score}));
    return 1;
  }
  return 0;
}

sub check_messageid_not_usable {
  my ($self) = @_;
  local ($_);

  # Lyris eats message-ids.  also some ezmlm, I think :(
  $_ = $self->get ("List-Unsubscribe");
  return 1 if (/<mailto:(?:leave-\S+|\S+-unsubscribe)\@\S+>$/);

  # ezmlm again
  if($self->gated_through_received_hdr_remover()) { return 1; }

  # Allen notes this as 'Wacky sendmail version?'
  $_ = $self->get ("Received");
  return 1 if /\/CWT\/DCE\)/;

  # Apr  2 2003 jm: iPlanet rewrites lots of stuff, including Message-IDs
  return 1 if /iPlanet Messaging Server/;

  # too old; older versions of clients used different formats
  return 1 if ($self->received_within_months('6','undef'));

  return 0;
}

# Return true if the count of $hdr headers are within the given range
sub check_header_count_range {
  my ($self, $hdr, $min, $max) = @_;
  my %uniq = ();
  my @hdrs = grep(!$uniq{$_}++, $self->{msg}->get_header ($hdr));
  return ( scalar @hdrs >= $min && scalar @hdrs <= $max );
}

sub check_blank_line_ratio {
  my ($self, $fulltext, $min, $max, $minlines) = @_;

  if ( !defined $minlines || $minlines < 1 ) {
    $minlines = 1;
  }

  $fulltext = $self->get_decoded_body_text_array();
  if ( ! exists $self->{blank_line_ratio}->{$minlines} ) {
    my($blank) = 0;
    if ( scalar @{$fulltext} >= $minlines ) {
      foreach my $line ( @{$fulltext} ) {
        next if ( $line =~ /\S/ );
        $blank++;
      }
      $self->{blank_line_ratio}->{$minlines} = 100 * $blank / scalar @{$fulltext};
    }
    else {
      $self->{blank_line_ratio}->{$minlines} = -1; # don't report if it's a blank message ...
    }
  }

  return ( ($min == 0 && $self->{blank_line_ratio}->{$minlines} <= $max) || ($self->{blank_line_ratio}->{$minlines} > $min && $self->{blank_line_ratio}->{$minlines} <= $max) );
}

sub check_access_database {
  my($self, $path) = @_;

  if (!HAS_DB_FILE) {
    return 0;
  }

  my %access;
  my %ok = map { $_ => 1 } qw/ OK SKIP /;
  my %bad = map { $_ => 1 } qw/ REJECT ERROR DISCARD /;

  $path = $self->{main}->sed_path ($path);
  dbg("Tie-ing to DB file R/O in $path");
  if ( tie %access,"DB_File",$path, O_RDONLY ) {
    my @lookfor = ();

    # Look for "From:" versions as well!
    foreach my $from ( $self->all_from_addrs() ) {
      # $user."\@"
      # rotate through $domain and check
      my($user,$domain) = split(/\@/, $from,2);
      push(@lookfor, "From:$from",$from);
      if ( $user ) {
        push(@lookfor, "From:$user\@", "$user\@");
      }
      if ( $domain ) {
        while( $domain =~ /\./ ) {
          push(@lookfor, "From:$domain", $domain);
          $domain =~ s/^[^.]*\.//;
        }
        push(@lookfor, "From:$domain", $domain);
      }
    }

    # we can only match this if we have at least 1 untrusted header
    if ( $self->{num_relays_untrusted} > 0 ) {
      my $lastunt = $self->{relays_untrusted}->[0];

      # If there was a reverse lookup, use it in a lookup
      if ( ! $lastunt->{no_reverse_dns} ) {
        my $rdns = $lastunt->{lc_rdns};
        while( $rdns =~ /\./ ) {
          push(@lookfor, "From:$rdns", $rdns);
          $rdns =~ s/^[^.]*\.//;
        }
        push(@lookfor, "From:$rdns", $rdns);
      }

      # do both IP and net (rotate over IP)
      my($ip) = $lastunt->{ip};
      $ip =~ tr/0-9.//cd;
      while( $ip =~ /\./ ) {
        push(@lookfor, "From:$ip", $ip);
	$ip =~ s/\.[^.]*$//;
      }
      push(@lookfor, "From:$ip", $ip);
    }

    my $retval = 0;
    my %cache = ();
    foreach ( @lookfor ) {
      next if ( $cache{$_}++ );
      dbg("accessdb: Looking for $_");

      # Some systems put a null at the end of the key, most don't...
      my $result = $access{$_} || $access{"$_\000"} || next;

      my($type) = split(/\W/,$result);
      if ( exists $ok{$type} ) {
	dbg("accessdb: hit OK: $type, $_");
        $retval = 0;
	last;
      }
      if (exists $bad{$type} || $type =~ /^\d+$/) {
        $retval = 1;
	dbg("accessdb: hit not-OK: $type, $_");
      }
    }

    dbg("Untie-ing DB file $path");
    untie %access;

    return $retval;
  }
  else {
    dbg("Cannot open accessdb $path R/O: $!");
  }
  0;
}

sub sent_by_applemail {
  my ($self) = @_;

  return 0 unless ($self->get ("MIME-Version") =~ /Apple Message framework/);
  return 0 unless ($self->get ("X-Mailer") =~ /^Apple Mail \(\d+\.\d+\)/);
  return 0 unless ($self->get ("Message-Id") =~
				/^<[A-F0-9]+(?:-[A-F0-9]+){4}\@\S+.\S+>$/);
  return 1;
}

sub check_for_rdns_helo_mismatch {	# T_FAKE_HELO_*
  my ($self, $rdns, $helo) = @_;

  # oh for ghod's sake.  Apple's Mail.app HELO's as the right-hand
  # side of the From address.  So "HELO jmason.org" in my case.
  # This is (obviously) considered forgery, since it's exactly
  # what ratware does too.
  return 0 if $self->sent_by_applemail();

  # the IETF's list-management system mangles Received headers,
  # "faking" a HELO, resulting in FPs.  So if we received the
  # mail from the IETF's outgoing SMTP server, skip it.
  if ($self->{relays_untrusted_str} =~ /^\[ [^\]]*
		  ip=132\.151\.1\.\S+\s+ rdns=\S*ietf\.org /x)
  {
    return 0;
  }

  my $firstuntrusted = 1;
  foreach my $relay (@{$self->{relays_untrusted}}) {
    my $wasfirst = $firstuntrusted;
    $firstuntrusted = 0;

    # did the machine HELO as a \S*something\.com machine?
    if ($relay->{helo} !~ /(?:\.|^)${helo}$/) { next; }

    my $claimed = $relay->{rdns};
    my $claimedmatches = ($claimed =~ /(?:\.|^)${rdns}$/);
    if ($claimedmatches && $wasfirst) {
      # the first untrusted Received: hdr is inserted by a trusted MTA.
      # so if the rDNS pattern matches, we're good, skip it
      next;
    }

    if ($claimedmatches && !$wasfirst) {
      # it's a possibly-forged rDNS lookup.  Do a verification lookup
      # to ensure the host really does match what the rDNS lookup
      # claims it is.
      if ($self->is_dns_available()) {
	my $vrdns = $self->lookup_ptr ($relay->{ip});
	if (defined $vrdns && $vrdns ne $claimed) {
	  dbg ("rdns/helo mismatch: helo=$relay->{helo} ".	
		"claimed-rdns=$claimed true-rdns=$vrdns");
	  return 1;
	  # TODO: instead, we should set a flag and check it later for
	  # another test; but that relies on complicated test ordering
	}
      }
    }

    if (!$claimedmatches) {
      if (!$self->is_dns_available()) { 
	if ($relay->{rdns_not_in_headers}) {
	  # that's OK then; it's just the MTA which picked it up,
	  # is not configured to perform lookups, and we're offline
	  # so we couldn't either.
	  return 0;
	}
      }

      # otherwise there *is* a mismatch
      dbg ("rdns/helo mismatch: helo=$relay->{helo} rdns=$claimed");
      return 1;
    }
  }

  0;
}

###########################################################################

sub check_all_trusted {
  my ($self) = @_;
  if ($self->{num_relays_untrusted} > 0) {
    return 0;
  } else {
    return 1;
  }
}

###########################################################################

# SPF support
sub check_for_spf_pass {
  my ($self) = @_;
  $self->_check_spf(0) unless $self->{spf_checked};
  $self->{spf_pass};
}

sub check_for_spf_fail {
  my ($self) = @_;
  $self->_check_spf(0) unless $self->{spf_checked};
  if ($self->{spf_failure_comment}) {
    $self->test_log ($self->{spf_failure_comment});
  }
  $self->{spf_fail};
}

sub check_for_spf_softfail {
  my ($self) = @_;
  $self->_check_spf(0) unless $self->{spf_checked};
  if ($self->{spf_failure_comment}) {
    $self->test_log ($self->{spf_failure_comment});
  }
  $self->{spf_softfail};
}

sub check_for_spf_helo_pass {
  my ($self) = @_;
  $self->_check_spf(1) unless $self->{spf_helo_checked};
  $self->{spf_helo_pass};
}

sub check_for_spf_helo_fail {
  my ($self) = @_;
  $self->_check_spf(1) unless $self->{spf_helo_checked};
  if ($self->{spf_helo_failure_comment}) {
    $self->test_log ($self->{spf_helo_failure_comment});
  }
  $self->{spf_helo_fail};
}

sub check_for_spf_helo_softfail {
  my ($self) = @_;
  $self->_check_spf(1) unless $self->{spf_helo_checked};
  if ($self->{spf_helo_failure_comment}) {
    $self->test_log ($self->{spf_helo_failure_comment});
  }
  $self->{spf_helo_softfail};
}

sub _check_spf {
  my ($self, $ishelo) = @_;

  return unless $self->is_dns_available();

  # skip SPF checks if the A/MX records are nonexistent for the From
  # domain, anyway, to avoid crappy messages from slowing us down
  # (bug 3016)
  return if $self->check_for_from_dns();

  if ($ishelo) {
    # SPF HELO-checking variant.  This isn't really SPF at all ;)
    $self->{spf_helo_checked} = 1;
    $self->{spf_helo_pass} = 0;
    $self->{spf_helo_fail} = 0;
    $self->{spf_helo_softfail} = 0;
    $self->{spf_helo_failure_comment} = undef;
  } else {
    # "real" SPF; checking the envelope-from (where we can)
    $self->{spf_checked} = 1;
    $self->{spf_pass} = 0;
    $self->{spf_fail} = 0;
    $self->{spf_softfail} = 0;
    $self->{spf_failure_comment} = undef;
  }

  my $lasthop = $self->{relays_untrusted}->[0];
  if (!defined $lasthop) {
    dbg ("SPF: message was delivered entirely via trusted relays, not required");
    return;
  }

  my $ip = $lasthop->{ip};
  my $helo = $lasthop->{helo};
  my $sender = '';

  if ($ishelo) {
    dbg ("SPF: checking HELO (helo=$helo, ip=$ip)");
    $helo = Mail::SpamAssassin::Util::trim_domain_to_registrar_boundary ($helo);
    dbg ("SPF: trimmed HELO down to '$helo'");

  } else {
    $sender = $lasthop->{envfrom};

    if ($sender) {
      dbg ("SPF: found Envelope-From in last untrusted Received header");
    }
    else {
      # We cannot use the env-from data, since it went through 1 or
      # more relays since the untrusted sender and they may have
      # rewritten it.
      #
      if ($self->{num_relays_trusted} > 0) {
	dbg ("SPF: relayed through one or more trusted relays, cannot use header-based Envelope-From, skipping");
	return;
      }

      # we can (apparently) use whatever the current Envelope-From was,
      # from the Return-Path, X-Envelope-From, or whatever header.
      # it's better to get it from Received though, as that is updated
      # hop-by-hop.
      #
      $sender = $self->get ("EnvelopeFrom");
    }

    if (!$sender) {
      dbg ("SPF: cannot get Envelope-From, cannot use SPF");
      return;
    }
    dbg ("SPF: checking EnvelopeFrom (helo=$helo, ip=$ip, envfrom=$sender)");
  }

  if (!$ip || !$helo) {
    dbg ("SPF: cannot get IP or HELO, cannot use SPF");
    return;
  }

  if ($self->server_failed_to_respond_for_domain($helo)) {
    dbg ("SPF: we had a previous timeout on '$helo', skipping");
    return;
  }

  my $query;
  eval {
    require Mail::SPF::Query;
    $query = Mail::SPF::Query->new (ip => $ip, sender => $sender, helo => $helo,
		debug => $Mail::SpamAssassin::DEBUG->{rbl},
		trusted => 1
	      );
  };

  if ($@) {
    dbg ("SPF: cannot load or create Mail::SPF::Query module");
    return;
  }

  my ($result, $comment);
  my $timeout = 5;

  eval {
    local $SIG{ALRM} = sub { die "__alarm__\n" };
    alarm($timeout);
    ($result, $comment) = $query->result();
    alarm(0);
  };

  alarm 0;

  if ($@) {
    if ($@ =~ /^__alarm__$/) {
      dbg ("SPF: lookup timed out after $timeout secs.");
    } else {
      warn ("SPF: lookup failed: $@\n");
    }
    return 0;
  }

  $result ||= 'softfail';
  $comment ||= '';
  $comment =~ s/\s+/ /gs;	# no newlines please

  if ($ishelo) {
    if ($result eq 'pass') { $self->{spf_helo_pass} = 1; }
    elsif ($result eq 'fail') { $self->{spf_helo_fail} = 1; }
    elsif ($result eq 'softfail') { $self->{spf_helo_softfail} = 1; }

    if ($result eq 'fail' || $result eq 'softfail') {
      $self->{spf_helo_failure_comment} = "SPF failed: $comment";
    }
  } else {
    if ($result eq 'pass') { $self->{spf_pass} = 1; }
    elsif ($result eq 'fail') { $self->{spf_fail} = 1; }
    elsif ($result eq 'softfail') { $self->{spf_softfail} = 1; }

    if ($result eq 'fail' || $result eq 'softfail') {
      $self->{spf_failure_comment} = "SPF failed: $comment";
    }
  }

  dbg ("SPF: query for $sender/$ip/$helo: result: $result, comment: $comment");
}

###########################################################################
# HTML parser tests
###########################################################################

sub html_tag_balance {
  my ($self, undef, $rawtag, $rawexpr) = @_;
  $rawtag =~ /^([a-zA-Z0-9]+)$/; my $tag = $1;
  $rawexpr =~ /^([\<\>\=\!\-\+ 0-9]+)$/; my $expr = $1;

  return 0 unless exists $self->{html}{"inside_$tag"};

  $self->{html}{"inside_$tag"} =~ /^([\<\>\=\!\-\+ 0-9]+)$/;
  my $val = $1;
  return eval "$val $expr";
}

sub html_image_only {
  my ($self, undef, $min, $max) = @_;

  return (exists $self->{html}{"inside_img"} &&
	  exists $self->{html}{non_space_len} &&
	  $self->{html}{non_space_len} > $min &&
	  $self->{html}{non_space_len} <= $max &&
	  $self->get('X-eGroups-Return') !~ /^sentto-.*\@returns\.groups\.yahoo\.com$/);
}

sub html_image_ratio {
  my ($self, undef, $min, $max) = @_;

  return 0 unless (exists $self->{html}{non_space_len} &&
		   exists $self->{html}{image_area} &&
		   $self->{html}{image_area} > 0);
  my $ratio = $self->{html}{non_space_len} / $self->{html}{image_area};
  return ($ratio > $min && $ratio <= $max);
}

sub html_charset_faraway {
  my ($self) = @_;

  return 0 unless exists $self->{html}{charsets};

  my @locales = $self->get_my_locales();
  return 0 if grep { $_ eq "all" } @locales;

  my $okay = 0;
  my $bad = 0;
  for my $c (split(' ', $self->{html}{charsets})) {
    if (Mail::SpamAssassin::Locales::is_charset_ok_for_locales($c, @locales)) {
      $okay++;
    }
    else {
      $bad++;
    }
  }
  return ($bad && ($bad >= $okay));
}

sub html_tag_exists {
  my ($self, undef, $tag) = @_;
  return exists $self->{html}{"inside_$tag"};
}

sub html_test {
  my ($self, undef, $test) = @_;
  return $self->{html}{$test};
}

sub html_eval {
  my ($self, undef, $test, $expr) = @_;
  return exists $self->{html}{$test} && eval "qq{\Q$self->{html}{$test}\E} $expr";
}

sub html_text {
  my ($self, undef, $text, $expr) = @_;
  for my $string (@{ $self->{html}{$text} }) {
    if (defined $string && eval "qq{\Q$string\E} $expr") {
      return 1;
    }
  }
  return 0;
}

sub html_range {
  my ($self, undef, $test, $min, $max) = @_;

  return 0 unless exists $self->{html}{$test};

  $test = $self->{html}{$test};

  # not all perls understand what "inf" means, so we need to do
  # non-numeric tests!  urg!
  if ( !defined $max || $max eq "inf" ) {
    return ( $test eq "inf" ) ? 1 : ($test > $min);
  }
  elsif ( $test eq "inf" ) {
    # $max < inf, so $test == inf means $test > $max
    return 0;
  }
  else {
    # if we get here everything should be a number
    return ($test > $min && $test <= $max);
  }
}

###########################################################################

sub multipart_alternative_difference {
  my($self, $fulltext, $min, $max) = @_;

  $self->_multipart_alternative_difference() unless ( exists $self->{madiff} );

  if (($min == 0 || $self->{madiff} > $min) &&
      ($max eq "undef" || $self->{madiff} <= $max)) {
      return 1;
  }
  return 0;
}

sub _multipart_alternative_difference {
  my($self) = @_;

  my @ma = $self->{msg}->find_parts(qr@^multipart/alternative\b@i);
  my @content = $self->{msg}->content_summary();

  $self->{madiff} = 0;

  # Exchange meeting requests come in as m/a text/html text/calendar ...
  # Ignore any messages without a multipart/alternative section as well ...
  if ( !@ma || (@content == 3 && $content[2] eq 'text/calendar' &&
  		$content[1] eq 'text/html' &&
  		$content[0] eq 'multipart/alternative') ) {
    return;
  }

  # Only deal with text/plain and text/html ...
  foreach my $part ( @ma ) {
    my %html = ();
    my %text = ();

    my @txt = $part->find_parts(qr@^text\b@i);
    foreach my $text ( @txt ) {
      my($type, $rnd) = $text->rendered();

      if ( $type eq 'text/html' ) {
        foreach my $w ( grep(/\w/,split(/\s+/,$rnd)) ) {
	  #dbg("HTML: $w");
          $html{$w}++;
        }
      }
      else {
        foreach my $w ( grep(/\w/,split(/\s+/,$rnd)) ) {
	  #dbg("TEXT: $w");
          $text{$w}++;
        }
      }
    }

    my $orig = keys %html;
    next if ( $orig == 0 );

    while( my($k,$v) = each %text ) {
      delete $html{$k} if ( exists $html{$k} && $html{$k}-$text{$k} < 1 );
    }

    #map { dbg("LEFT: $_") } keys %html;

    my $diff = scalar(keys %html)/$orig*100;
    $self->{madiff} = $diff if ( $diff > $self->{madiff} );

    dbg(sprintf "madiff: left: %d, orig: %d, max-difference: %0.2f%%", scalar(keys %html), $orig, $self->{madiff});
  }

  return;
}

###########################################################################

sub domain_ratio {
  my($self, $body, $ratio) = @_;
  my $length = (length(join('', @{$body})) || 1);
  if (!defined $self->{domains}) {
    $self->get_uri_list();
  }
  return 0 if !defined $self->{domains};
  return (($self->{domains} / $length) > $ratio);
}

###########################################################################

1;
