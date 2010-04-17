#!/usr/bin/perl
use strict;
use warnings;
use POE qw(Component::IRC);
use Algorithm::NGram;
use Storable;

my $nickname = 'wkrAk4r';
my $ircname = 'w1nd0wz kr4k4r';
my $username = 'rockedcok';
my $save_file = 'impersonate.ngrams';

my $DEBUG = 1;
my $owner = 'jenk';

my $settings = { 
    'irc.servercentral.net' => { channels => ['#anxious', '#alcohol', '#depression', '#anti-obese', '#northkorea', '#aviation', '#bush_ran_911', '##politics', '#chats'] },
    'irc.hardchats.com' => { port => 6697, usessl => 1, channels => [ '#unicornmob', '##anxiety' ] },    
};

my @impersonator_events = qw /
    _start _default irc_registered irc_001 irc_join say irc_public randsay
/;


foreach my $server ( keys %{ $settings } ) {
    POE::Component::IRC->spawn( 
                                alias   => $server, 
                                nick    => $nickname,
                                ircname => $ircname,
                                username => $username,
                                );
  }

POE::Session->create(
                     package_states => [
                                        'main' => [ qw/
                                                    _stop _default _start irc_registered
                                                    irc_001 irc_public log_message save load
                                                    generate_msg list_nicks impersonate
                                                    set_ngram_width
                                                    /],
                                        ],
                     heap => { config => $settings },
                     );

$poe_kernel->run();
exit 0;

sub splitstr {
    my $str = shift;
}

sub _start {
    my ($kernel,$session,$sender,$opts) = @_[KERNEL,SESSION,SENDER,ARG0];

    # Send a POCOIRC_REGISTER signal to all poco-ircs
    $kernel->signal( $kernel, 'POCOIRC_REGISTER', $session->ID(), 'all' );

    # catch interrupts
    $kernel->sig( INT => 'event_sigint' );

    $sender->yield('load');

    undef;
}

sub event_sigint {
    my ($kernel, $session) = @_[KERNEL,SESSION];
    exit;
}

sub load {
    my ($kernel, $session, $heap) = @_[KERNEL,SESSION,HEAP];

    # load ngrams
    my $ngrams = {};
    my $saved;

    if (! -e $save_file) {
        print "Creating new n-gram file $save_file\n";
        $ngrams = {};
    } else {
        $saved = Storable::retrieve($save_file);
        print "Loading n-gram file $save_file...\n";

        while (my ($who, $ngram) = each %{$saved->{ngrams}}) {
            $ngrams->{$who} = Algorithm::NGram->deserialize($ngram);
            print " - Loaded n-gram for $who\n";
        }
    }

    $heap->{ngram_width} = $saved ? $saved->{ngram_width} : 3; # default: trigram
    $heap->{ngrams} = $ngrams;
    print "Started\n";

    undef;
}

sub _stop {
    my ($kernel, $session, $heap) = @_[KERNEL,SESSION,HEAP];
    save($heap);
}

sub save {
    my ($heap) = @_;

    my $save = {};

    while (my ($who, $ngram) = each %{$heap->{ngrams}}) {
        $save->{ngrams}->{$who} = $ngram->serialize;
    }

    $save->{ngram_width} = $heap->{ngram_width};

    Storable::nstore($save, $save_file);
    print "Saved n-grams to $save_file\n";
}

# We'll get one of these from each PoCo-IRC that we spawned above.
sub irc_registered {
    my ($kernel,$heap,$sender,$irc_object) = @_[KERNEL,HEAP,SENDER,ARG0];

    my $alias = $irc_object->session_alias();

    my %conn_hash = (
                     Server => $alias,
                     Port   => $heap->{config}->{ $alias }->{port},
                     UseSSL => ($heap->{config}->{ $alias }->{usessl} ? 1 : 0),
                     );

    # In any irc_* events SENDER will be the PoCo-IRC session
    $kernel->post( $sender, 'connect', \%conn_hash ); 

    undef;
}

sub irc_001 {
    my ($kernel,$heap,$sender) = @_[KERNEL,HEAP,SENDER];

    my $poco_object = $sender->get_heap();
    print "Connected to ", $poco_object->server_name(), "\n";

    my $alias = $poco_object->session_alias();
    my @channels = @{ $heap->{config}->{ $alias }->{channels} };

    $kernel->post( $sender, 'join', $_ ) for @channels;

    undef;
}

sub irc_public {
    my ($kernel,$session,$sender,$who,$where,$what) = @_[KERNEL,SESSION,SENDER,ARG0,ARG1,ARG2];

    my $irc = $sender->get_heap;
    return unless $irc->nick_name eq $nickname;
    
    my $nick = lc $who;
    $nick = (split('!', $nick))[0];
    my $channel = $where->[0];

    $nick = normalize_nick($nick);

    print "<$nick> $what\n";

    my ($t, $test) = $what =~ /^\s*(test)\s*(\w+)?\s*$/i;
    $test ||= $owner if $t;

    if ($nick =~ /^${owner}_?$/i) {
        my $msg;

        if ($test) {
            $msg = $kernel->call($session, 'generate_msg', $test);
        } elsif ($what =~ /^set\s+(\d)-?gram/i) {
            $msg = $kernel->call($session, 'set_ngram_width', $1);
        } elsif ($what =~ /^list$/i) {
            $msg = $kernel->call($session, 'list_nicks');
        } elsif ($what =~ /^impersonate\s+([\w\-\[\]\|]+)\s+(\S+)/i) {
            my ($i_nick, $i_chan) = ($1, $2);
            if ($i_nick && $i_chan) {
                $kernel->post($session, 'impersonate', $sender, $channel, $i_nick, $i_chan);
            } else {
                $msg = "You must specify a channel";
            }
        }

        $kernel->post($sender, 'privmsg', $channel, "$msg") if $msg;
    } else {
        $kernel->yield('log_message', $nick, $channel, $what);
    }

    undef;
}

sub set_ngram_width {
    my ($kernel, $heap, $width) = @_[KERNEL,HEAP,ARG0];

    foreach my $ngram (values %{$heap->{ngrams}}) {
        $ngram->ngram_width($width);
        $heap->{ngram_width} = $width;
    }

    return "Set $width-gram";
}

sub impersonate {
    my ($kernel, $heap, $poco, $where, $nick, $chan) = @_[KERNEL, HEAP, ARG0 .. $#_];

    my $fake_nick = generate_fake_nick($nick);
    my $server = find_channel($chan);

    my $ngram = $heap->{ngrams}->{normalize_nick($nick)};

    unless ($ngram) {
        $kernel->post($poco, 'privmsg', $where, "There is no n-gram for $nick");
        return;
    }

    unless ($server) {
        $kernel->post($poco, 'privmsg', $where, "Could not find server information for channel $chan");
        return;
    }

    $kernel->post($poco, 'privmsg', $where, "Impersonating with $fake_nick info=$server");

    POE::Session->create(
                         package_states => [
                                            'Impersonator' => \@impersonator_events,
                                            ],
                         heap => {
                             nick => $fake_nick,
                             server => $server,
                             chan => $chan,
                             ngram => $ngram,
                         },
                         );
}

sub list_nicks {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $ngrams = $heap->{ngrams};
    my @nicks = keys %$ngrams;
    @nicks = sort { @{$ngrams->{$b}->tokens} <=> @{$ngrams->{$a}->tokens} } @nicks;
    return join(', ', @nicks);
}

sub normalize_nick {
    my $nick = shift;
    $nick =~ s/[_`]//g;    # `]//;
    return $nick;
}

sub generate_msg {
    my ($kernel, $heap, $who) = @_[KERNEL, HEAP, ARG0];
    return "No nick specified" unless $who;
    my $ng = $heap->{ngrams}->{$who} or return "No n-gram for $who";
    return $ng->generate_text || 'Could not generate text';
}

sub find_channel {
    my $chan = shift;
    $chan = "#$chan" unless $chan =~ /^#/; #/;

    foreach my $server (keys %$settings) {
        return $server if grep { $_ eq $chan } @{$settings->{$server}->{channels}};
    }

    return undef;
}

sub generate_fake_nick {
    my $nick = shift;
    my $charmap = {
        'a' => '4',
        'i' => '1',
        'l' => '1',
        'v' => 'y',
        'y' => 'v',
        'm' => 'n',
        'j' => 'i',
        'g' => '9',
        'o' => '0',
        's' => '5',
    };

    my $newnick = rand() > 0.8 ? '_' : '';

    for (my $i = 0; $i < length $nick; $i++) {
        my $chr = substr $nick, $i, 1;
        my $newchr = $chr;

        if (rand() > 0.4 && ($i != 0 || ! int($chr))) {
            $newchr = $chr;
        } else {
            $newchr = $charmap->{$chr} || $chr;
        }

        $newnick .= $newchr;
    }

    if ($newnick eq $nick) {
        $newnick = "$nick`";
    }

    return $newnick;
}

sub log_message {
    my ($kernel,$sender,$heap,$who,$where,$what) = @_[KERNEL,SENDER,HEAP,ARG0,ARG1,ARG2];

    $heap->{ngrams}->{$who} ||= new Algorithm::NGram(ngram_width => $heap->{ngram_width});
    $heap->{ngrams}->{$who}->add_text($what);
}

# We registered for all events, this will produce some debug info.
sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    return if $event eq 'irc_372';

    foreach my $arg ( @$args ) {
        if ( ref($arg) eq 'ARRAY' ) {
            push( @output, "[" . join(" ,", @$arg ) . "]" );
        } else {
            push ( @output, "'$arg'" );
        }
    }

    print STDOUT join ' ', @output, "\n" if $DEBUG;

    return 0;
}

##########################


# impersonator
package Impersonator;
use strict;
use warnings;
use POE qw(Component::IRC);

sub _start {
    my ($kernel,$session,$sender,$heap) = @_[KERNEL,SESSION,SENDER,HEAP];

    my $nick = $heap->{nick} or die;
    my $server = $heap->{server} or die;
    my $chan = $heap->{chan} or die;

    my $alias = "$nick$server" . time();

    # spawn irc
    POE::Component::IRC->spawn( 
                                alias   => $alias,
                                nick    => $nick,
                                ircname => $nick,
                                username => $nick,
                                );

    

    $kernel->signal( $kernel, 'POCOIRC_REGISTER', $alias, 'all' );
}

sub irc_registered {
    my ($kernel,$heap,$sender,$irc_object) = @_[KERNEL,HEAP,SENDER,ARG0];

    my $server = $heap->{server};
    my $config = $settings->{$server};

    my $conn = {
        Server => $server,
        Port => $config->{port},
        UseSSL => $config->{usessl},
    };

    $kernel->post( $sender, 'connect', $conn ); 
}

sub irc_001 {
    my ($kernel,$heap,$sender) = @_[KERNEL,HEAP,SENDER];

    my $irc = $sender->get_heap;
    print "Connected to ", $irc->server_name(), "\n";

    my $chan = $heap->{chan} or die "No chan defined in heap";

    $kernel->post( $sender, 'join', $chan );
}

sub irc_join {
    my ($kernel,$heap,$sender) = @_[KERNEL,HEAP,SENDER];

    my $alarm_id = $kernel->delay_set('say', 200, $sender, $heap->{chan}, 1);
}

sub say {
    my ($kernel, $heap, $sender, $irc, $chan, $start_word) = @_[KERNEL,HEAP,SENDER,ARG0,ARG1];
    my $ng = $heap->{ngram};

    my $txt = $ng->generate_text;
    $kernel->post($irc, 'privmsg', $chan, $txt) if $txt;

    # chat randomly
    $kernel->delay_set('randsay', int(rand(200_000)), $irc, $chan);
}

sub randsay {
    my ($kernel, $heap, $sender, $irc, $chan, $first) = @_[KERNEL,HEAP,SENDER,ARG0,ARG1];
    $kernel->yield('say', $irc, $chan);
}

sub irc_public {
    my ($kernel,$session,$heap,$sender,$who,$where,$what) = @_[KERNEL,SESSION,HEAP,SENDER,ARG0,ARG1,ARG2];

    my $irc = $sender->get_heap;

    my $nick = lc $who;
    $nick = (split('!', $nick))[0];
    my $channel = $where->[0];

    # get first word
    $what ||= '';
    my ($start_word) = $what =~ /\s*(\w+)\b/;

    # increase likelihood of response every time someone chats
    $heap->{msg_count}->{$channel}++;
    if ($heap->{msg_count}->{$channel} + int(rand(10)) > 17) {
        $kernel->delay_set('say', int(rand(15)), $sender, $channel, $start_word);
        $heap->{msg_count}->{$channel} = 0;
    }
}

sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    return if $event eq 'irc_372';

    foreach my $arg ( @$args ) {
        if ( ref($arg) eq 'ARRAY' ) {
            push( @output, "[" . (join(", ", @$arg ) || '') . "]" );
        } else {
            $arg ||= '';
            push ( @output, "'$arg'" );
        }
    }

    print STDOUT join ' ', @output, "\n";

    return 0;
}
