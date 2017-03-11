use 5.24.0;
use experimental 'signatures', 'postderef', 'lexical_subs';

my sub is_patch($at) {
    return !$at->{is_obsolete} && ( $at->{is_patch} || $at->{content_type} eq 'text/x-github-pull-request' );
}

package BugButler::Bugzilla {
    use Moo;
    no warnings 'experimental';

    use JSON::MaybeXS;
    use Net::Async::HTTP;
    use Type::Utils qw(class_type);
    use Data::Printer;
    use List::Util qw(any);

    use constant BUG_FIELDS        => 'summary,priority,status,resolution,product,component,id,flags,assigned_to';
    use constant ATTACHMENT_FIELDS => 'flags,file_name,summary,description,content_type,is_patch,is_obsolete,attacher';

    has 'api_key'  => ( is => 'ro',   required => 1 );
    has 'rest_uri' => ( is => 'ro',   required => 1, isa => class_type('URI') );
    has 'http'     => ( is => 'lazy', handles  => [qw[ do_request GET ]] );

    sub get_bug($self, $bug_id, $fields = BUG_FIELDS) {
        my $uri = $self->rest_uri->clone;
        $uri->path("/rest/bug/$bug_id");
        $uri->query_form(include_fields => $fields);
        my $f = IO::Async::Loop->new->new_future;
        $self->GET( $uri, on_response => _handle_response($f, 'bugs'));
        return $f;
    }

    sub generate_reports($self) {
        my $bugs = $self->bugs_with_patches->get;
        my %report;

        foreach my $bug (@$bugs) {
            foreach my $patch ($bug->{attachments}->@*) {
                if (any { $_->{name} eq 'review' && $_->{status} eq '+' } $patch->{flags}->@*) {
                    $report{reviewed_patches}{$bug->{id}} = $bug;
                }
            }
            if (lc($bug->{assigned_to}) eq 'nobody@mozilla.org' || $bug->{assigned_to} =~ /\.bugs$/i) {
                $report{unassigned_with_patches}{$bug->{id}} = $bug;
            }
        }
    }

    sub bugs_with_patches($self) {
        my $query = {
            f1         => 'attachments.isobsolete',
            o1         => 'equals',
            v1         => 0,
            f2         => 'product',
            v2         => 'bugzilla.mozilla.org',
            o2         => 'equals',
            resolution => '---',
        };

        $self->search($query, 1)->then(
            sub($bugs) {
                my @filtered_bugs;
                foreach my $bug (@$bugs) {
                    $bug->{attachments} = [ grep { is_patch($_) } $bug->{attachments}->@* ];
                    push @filtered_bugs, $bug if $bug->{attachments}->@*;
                }
                IO::Async::Loop->new->new_future->done(\@filtered_bugs);
            }
        );
    }

    sub search($self, $params, $include_attachments) {
        my $uri = $self->rest_uri->clone;
        $uri->path("/rest/bug");
        $uri->query_form(%$params, include_fields => BUG_FIELDS);
        my $f = IO::Async::Loop->new->new_future;
        $self->GET( $uri, on_response => _handle_response($f, 'bugs'));
        if ($include_attachments) {
            return $f->then(
                sub ($bugs) {
                    my $attachments = $self->get_attachments($bugs)->get;
                    foreach my $bug (@$bugs) {
                        $bug->{attachments} = $attachments->{$bug->{id}};
                    }
                    my $f2 = IO::Async::Loop->new->new_future;
                    $f2->done($bugs);
                    return $f2;
                },
            );
        }
        else {
            return $f;
        }
    }

    sub get_attachments($self, $bugs, $fields = ATTACHMENT_FIELDS) {
        my $uri = $self->rest_uri->clone;
        my @bug_id = map { $_->{id} } @$bugs;
        $uri->path("/rest/bug/$bug_id[0]/attachment");
        $uri->query_form(include_fields => $fields, ids => \@bug_id);
        my $attachments_f = IO::Async::Loop->new->new_future;
        $self->GET($uri, on_response => _handle_response($attachments_f, 'bugs'));
        return $attachments_f;
    }

    sub _handle_response($f, $pick = undef) {
        return sub($response) {
            if ($response->code == 200) {
                eval {
                    my $data = decode_json($response->content);
                    if (defined $pick) {
                        $data = $data->{$pick};
                    }
                    $f->done($data);
                };
                $f->fail($@) if $@;
            }
            else {
                $f->fail("Bad HTTP Response: " . $response->code);
            }
        }
    }


    sub _build_http($self) {
        my $loop = IO::Async::Loop->new();
        my $http = Net::Async::HTTP->new(
            user_agent => "BugButler $BugButler::VERSION",
        );

        $loop->add($http);

        return $http;
    }
}
1;
