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
    use JSON::MaybeXS;
    use Net::Async::IRC;
    use Pithub;
    use Plack::App::Directory::Xslate;
    use Plack::App::GitHub::WebHook;
    use Plack::Middleware::ReverseProxy;
    use Plack::Runner;
    use MIME::Base64 qw(encode_base64 decode_base64);
    use List::Util qw(any);

    has 'config'      => ( is => 'lazy' );
    has 'bugzilla'    => ( is => 'lazy' );
    has 'pithub'      => ( is => 'lazy' );
    has 'app'         => ( is => 'lazy' );
    has 'xslate_app'  => ( is => 'lazy' );
    has 'webhook_app' => ( is => 'lazy' );
    has 'report'      => ( is => 'rw'   );

    has 'runner' => (
        is      => 'lazy',
        handles => ['run'],
    );

    has 'reports' => ( is => 'ro', default => sub { [] } );

    has 'irc' => (
        is      => 'lazy',
        handles => ['say'],
    );

    sub do_startup($self) {
    }

    my %english = (
        unassigned_with_patches => "open unassigned bugs with patches",
        reviewed_patches => "open bugs with reviewed patches",
    );

    sub _rebuild_bugzilla_report($self) {
        my $bugs_with_patches = $self->bugzilla->bugs_with_patches->get;
        my %report;
        my %bug_cache;
        foreach my $bug (@$bugs_with_patches) {
            $bug_cache{$bug->{id}} = $bug;
            foreach my $patch ($bug->{attachments}->@*) {
                if (any { $_->{name} eq 'review' && $_->{status} eq '+' } $patch->{flags}->@*) {
                    $report{reviewed_patches}{$bug->{id}} = $bug;
                }
            }
            if (lc($bug->{assigned_to}) eq 'nobody@mozilla.org' || $bug->{assigned_to} =~ /\.bugs$/i) {
                $report{unassigned_with_patches}{$bug->{id}} = $bug;
            }
        }

        my $prs = $self->pithub->pull_requests(user => 'mozilla-bteam', repo => 'bmo')->list;
        while (my $pr = $prs->next) {
            if ($pr->{title} =~ /bug\s+#?(\d+)/ai) {
                my $bug_id = $1;
                if (not $bug_cache{$bug_id}) {
                    # probably no patch
                    warn "going to attach $pr->{number} to bug $bug_id";
                    eval {
                        my $result = $self->_attach_pull_request($bug_id, $pr)->get;
                        warn "yay!";
                        p $result;
                    };
                    if ($@) {
                        warn "$@\n";
                    }

                }
            }
        }

        $self->report(\%report);
    }

    sub _attach_pull_request($self, $bug_id, $pr) {
        my $url  = $pr->{html_url};
        my $file = "$pr->{number}.patch";
        return $self->bugzilla->get_bug($bug_id, 'product,component')->then(sub ($bugs) {
            my $bug = $bugs->[0];
            if ($bug->{product} ne 'bugzilla.mozilla.org') {
                return IO::Async::Loop->new->new_future->fail("not a bmo bug");
            }
            return $self->bugzilla->get_attachments($bug_id, 'data')->then(sub ($bugs) {
                my $attachments = $bugs->{$bug_id};
                foreach my $attachment ($attachments->@*) {
                    if (decode_base64($attachment->{data}) eq $url) {
                        return IO::Async::Loop->new->new_future->fail("already attached");
                    }
                }
                return $self->bugzilla->add_attachment(
                    $bug_id,
                    {
                        summary      => "github pull request",
                        file_name    => $file,
                        content_type => 'text/plain',
                        data         => encode_base64( $url, "" ),
                    },
                );
            });
        });
    }

    sub do_tick($self) {
        $self->_rebuild_bugzilla_report();
        my $report = $self->report;

        my @info;
        foreach my $key (sort keys %$report) {
            my $count = keys $report->{$key}->%*;
            my $text = $english{$key} // $key;
            push @info, "$count $text";
        }
        $self->say(undef, join(", ", @info));
        my $url = "https://bug-butler.hardison.net";
        $self->say(undef, "Details: $url/xslate/report.tt");
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
    }

    sub on_github_ping($self, $payload) {
        warn "github ping\n";
    }

    sub on_github_push($self, $payload) {
        my $commits = $payload->{commits}->@*;
        my $compare = $payload->{compare};
        my $sender  = $payload->{sender}{login};
        my $repo    = $payload->{repository}{full_name};
        $self->say(undef, "$sender pushed $commits to $repo. Compare: $compare");
    }

    sub on_github_pull_request_review($self, $payload) {
        my $r  = $payload->{review};
        my $pr = $payload->{pull_request};
        if ($payload->{action} eq 'submitted') {
            $self->say(undef, "$r->{user}{login} reviewed pull request $pr->{number}: $r->{html_url}");
        }
    }

    sub on_github_pull_request($self, $payload) {
        my $pr = $payload->{pull_request};
        my $state;

        if ($payload->{action} eq 'opened') {
            $self->say(undef, "$pr->{user}{login} opened new pull request: $pr->{html_url}");
        }
        elsif ($payload->{action} eq 'closed') {
            $self->say(undef, "$pr->{user}{login} closed pull request: $pr->{html_url}");
        }
        elsif ($payload->{action} eq 'edited') {
            $self->say(undef, "$pr->{user}{login} edited pull request: $pr->{html_url}");
        }
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

    sub _build_app($self) {
        Scalar::Util::weaken($self);
        package main {
            use Plack::Builder;
            return builder {
                enable_if { $_[0]->{REMOTE_ADDR} eq '127.0.0.1' } "Plack::Middleware::ReverseProxy";
                mount "/webhook" => $self->webhook_app;
                mount "/xslate"  => $self->xslate_app;
            };
        };
    }

    sub _build_xslate_app($self) {
        Scalar::Util::weaken($self);
        my $json = JSON->new->canonical(1)->pretty(1)->utf8(1);
        return Plack::App::Directory::Xslate->new(
            root       => main::DIR . "/www",
            xslate_opt => {
                syntax => 'TTerse',
                module => ['Text::Xslate::Bridge::Star'],
            },
            xslate_param => {
                report => sub { $self->report // {} },
            },
            xslate_path  => qr{\.tt$},
        )->to_app;
    }

    sub _build_webhook_app($self) {
        Scalar::Util::weaken($self);
        Plack::App::GitHub::WebHook->new(
            hook => sub { $self->do_github(@_) },
            secret => $self->config->get(key => 'github.webhook_secret'),
            access => 'github',
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
            interval       => 60 * 60 * 12,

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

        my $runner = Plack::Runner->new( app => $self->app );
        $runner->parse_options(
            '-s' => 'Net::Async::HTTP::Server',
            '--listen' => $self->config->get(key => 'http.listen'),
        );

        return $runner;
    }
}
1;
