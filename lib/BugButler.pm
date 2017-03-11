use 5.24.0;
use experimental 'signatures', 'postderef';

package BugButler 1.0 {
    use Moo;
    no warnings 'experimental';

    use BugButler::Bugzilla;
    use BugButler::IRC;
    use BugButler::Config;

    use Data::Printer;
    use IO::Async::Loop;
    use IO::Async::SSL;
    use IO::Async::Timer::Countdown;
    use IO::Async::Timer::Periodic;
    use Net::Async::IRC;
    use JSON::MaybeXS;
    use Pithub;
    use Plack::App::GitHub::WebHook;
    use Plack::Runner;

    has 'config'      => ( is => 'lazy' );
    has 'bugzilla'    => ( is => 'lazy' );
    has 'pithub'      => ( is => 'lazy' );
    has 'webhook_app' => ( is => 'lazy' );

    has 'runner' => (
        is      => 'lazy',
        handles => ['run'],
    );

    has 'reports' => ( is => 'ro', default => sub { [] } );

    has 'irc' => (
        is      => 'lazy',
        handles => ['say'],
    );

    sub do_startup($self) { }

    sub do_tick($self) {
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

    sub do_irc($self, $hints, $reply) {
        local $_ = $hints->{text};
        my $nick = $hints->{prefix_nick};
        return unless $hints->{mentioned};
        if (/^search (.+)$/) {
            $reply->("Yep");
            my $bugs = $self->bugzilla->search({quicksearch => $1}, 0)->get;
            $reply->( (@$bugs + 0) . " bugs found");
        }
        elsif (/^reviews/) {
            my $bugs = $self->bugzilla->search({quicksearch => "review? product=bugzilla.mozilla.org"}, 1)->get;
            $reply->("Found " . (@$bugs+0) . " bugs");
        }
        else {
            $reply->("What?");
        }
    }

    sub on_github_ping($self, $payload) {
        warn "github ping\n";
    }

    sub on_github_push($self, $payload) {

    }

    sub on_github_pull_request_review($self, $payload) {
        my $r  = $payload->{review};
        my $pr = $payload->{pull_request};
    }

    sub on_github_pull_request($self, $payload) {
        my $pr = $payload->{pull_request};

        $self->say("new pull request from $pr->{user}{login}: $pr->{html_url}");
    }

    sub _build_bugzilla($self) {
        return BugButler::Bugzilla->new(
            api_key => $self->config->get(key => 'bugzilla.api_key'),
            rest_uri => URI->new($self->config->get(key => 'bugzilla.rest_uri')),
        );
    }

    sub _build_pithub($self) {
        return Pithub->new(token => scalar $self->config->get(key => 'github.token'));
    }

    sub _build_webhook_app($self) {
        Scalar::Util::weaken($self);
        return Plack::App::GitHub::WebHook->new(
            hook => sub { $self->do_github(@_) },
            #secret => $self->config->get(key => 'github.webhook_secret'),
            access => [allow => '127.0.0.1'],
        )->to_app;
    }

    sub _build_irc($self) {
        Scalar::Util::weaken($self);
        my $c = $self->config;
        my $irc = BugButler::IRC->new(
            irc_host => $c->get(key => "irc.host"),
            irc_port => $c->get(key => "irc.port"),
            irc_nick => $c->get(key => "irc.nick"),
            irc_channel => $c->get(key => "irc.channel"),
        );
        $irc->configure(
            on_message_text => sub($irc, $msg, $hints) {
                my ($reply_to, $reply_prefix) = (0, '');
                my $target = $hints->{target_name};
                if ($target =~ /^#/) {
                    my $nick = $self->irc->irc_nick;
                    $reply_to = $target;
                    $reply_prefix = "$hints->{prefix_nick}: ";
                    if ($hints->{text} =~ s/^\s*\Q$nick\E[,:]\s*//) {
                        $hints->{mentioned} = 1;
                    }
                }
                else {
                    $reply_to = $hints->{prefix_nick};
                    $hints->{mentioned} = 1;
                }

                $self->do_irc($hints,
                    sub($msg) { $self->say($reply_to, $msg) });
            }
        );
        return $irc;
    }

    sub _build_config {
        return BugButler::Config->new(confname => "bug-butler");
    }

    before 'run' => sub($self) {
        Scalar::Util::weaken($self);
        my $loop = IO::Async::Loop->new;
        my $periodic = IO::Async::Timer::Periodic->new(
            first_interval => 0,
            interval       => 60 * 60,

            on_tick => sub {
                $self->do_tick();
            },
        );
        $loop->add($periodic);

        my $countdown = IO::Async::Timer::Countdown->new(
            delay     => 1,
            on_expire => sub {
                $self->irc->login->get();
                $self->do_startup();
                $periodic->start;
            },
        );
        $countdown->start;
        $loop->add($countdown);
    };

    sub _build_runner($self) {
        my $irc = $self->irc;

        my $runner = Plack::Runner->new(
            app => $self->webhook_app,
        );
        $runner->parse_options(
            '-s' => 'Net::Async::HTTP::Server',
            '--listen' => $self->config->get(key => 'http.listen'),
        );

        return $runner;
    }
}
1;
