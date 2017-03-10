use 5.24.0;
use experimental 'signatures';

package BugButler::Dispatcher {
    use Moo;
    no warnings 'experimental';
    use autodie;
    use Data::Printer;

    has 'pithub'   => ( is => 'ro', required => 1, weak_ref => 1 );
    has 'bugzilla' => ( is => 'ro', required => 1, weak_ref => 1 );
    has 'irc' => (
        is       => 'ro',
        required => 1,
        weak_ref => 1,
        handles  => [qw[ say ]],
    );

    sub do_startup($self) { }

    sub do_check_bugs($self) {

    }

    sub do_github($self, $payload, $event, $delivery, $logger) {
        my $method = "on_github_$event";
        if ($self->can($method)) {
            $self->$method($payload);
        }
        else {
            warn "unhandled github event: $event";
        }
    }

    sub do_irc($self, $hints) {
        if ($hints->{text} =~ /bug\s+#?(\d+)/a) {
            $self->bugzilla->bug_title($1);
        }
    }

    sub on_github_ping($self, $payload) {
        warn "github ping\n";
    }

    sub on_github_pull_request_review($self, $payload) {
        my $r  = $payload->{review};
        my $pr = $payload->{pull_request};
    }

    sub on_github_pull_request($self, $payload) {
        my $pr = $payload->{pull_request};

        $self->say("new pull request from $pr->{user}{login}: $pr->{html_url}");
    }
}

1;
