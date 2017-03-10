use 5.24.0;
use experimental 'signatures';

package BugButler 1.0 {
    use Moo;
    no warnings 'experimental';

    use Config::GitLike;
    use Pithub;
    use BugButler::Bugzilla;
    use BugButler::IRC;
    use BugButler::Dispatcher;
    use Plack::App::GitHub::WebHook;
    use Net::Async::IRC;

    has '_git_config' => ( is => 'lazy' );
    has 'bugzilla'    => ( is => 'lazy' );
    has 'pithub'      => ( is => 'lazy' );
    has 'dispatcher'  => ( is => 'lazy' );
    has 'webhook_app' => ( is => 'lazy' );
    has 'irc'         => ( is => 'lazy' );
    has 'http_listen' => ( is => 'lazy' );

    sub _build_bugzilla($self) {
        return BugButler::Bugzilla->new(
            api_key => $self->_git_config->get(key => 'bugzilla.api_key'),
            rest_uri => URI->new($self->_git_config->get(key => 'bugzilla.rest_uri')),
        );
    }

    sub _build_pithub($self) {
        return Pithub->new(token => scalar $self->_git_config->get(key => 'github.token'));
    }

    sub _build_dispatcher($self) {
        return BugButler::Dispatcher->new(
            pithub   => $self->pithub,
            bugzilla => $self->bugzilla,
            irc      => $self->irc,
        );
    }

    sub _build_webhook_app($self) {
        Scalar::Util::weaken($self);
        return Plack::App::GitHub::WebHook->new(
            hook => sub { $self->dispatcher->do_github(@_) },
            #secret => $self->_git_config->get(key => 'github.webhook_secret'),
            access => [allow => '127.0.0.1'],
        )->to_app;
    }

    sub _build_irc($self) {
        my $c = $self->_git_config;
        my $irc = BugButler::IRC->new(
            irc_host => $c->get(key => "irc.host"),
            irc_port => $c->get(key => "irc.port"),
            irc_nick => $c->get(key => "irc.nick"),
            irc_channel => $c->get(key => "irc.channel"),
        );
        $irc->configure(
            on_message_text => sub($irc, $msg, $hints) {
                $self->dispatcher->do_irc($hints);
            }
        );
        return $irc;
    }

    sub _build_http_listen($self) {
        return $self->_git_config->get(key => 'http.listen');
    }

    sub _build__git_config {
        return Config::GitLike->new(confname => "bug-butler");
    }
}
1;
