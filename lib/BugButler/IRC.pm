use 5.24.0;
use experimental 'signatures';

package BugButler::IRC {
    use Moo;
    no warnings 'experimental';

    has 'irc_host'    => ( is => 'ro', required => 1 );
    has 'irc_port'    => ( is => 'ro', required => 1 );
    has 'irc_nick'    => ( is => 'ro', required => 1 );
    has 'irc_channel' => ( is => 'ro', required => 1 );
    has '_irc'        => ( is => 'lazy', handles => [qw[configure]] );

    sub login($self) {
        $self->_irc->login(
            host       => $self->irc_host,
            service    => $self->irc_port,
            realname   => "BugButler $BugButler::VERSION",
            nick       => $self->irc_nick,
            extensions => ['SSL'],
        )->then(sub {
            $_[0]->send_message('JOIN', undef, $self->irc_channel);
        });
    }

    sub say($self, $target, $text) {
        warn "say $text\n";
        $self->_irc->do_PRIVMSG(
            target => $target // $self->irc_channel,
            text => $text,
        );
    }

    sub _build__irc($self) {
        my $loop = IO::Async::Loop->new;
        my $irc  = Net::Async::IRC->new();
        $loop->add($irc);

        return $irc;

    }
}
1;
