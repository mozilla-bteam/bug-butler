use 5.24.0;
use experimental 'signatures';

package BugButler::Bugzilla {
    use Moo;
    no warnings 'experimental';

    use JSON::MaybeXS;
    use Net::Async::HTTP;
    use Type::Utils qw(class_type);
    use Data::Printer;

    has 'api_key'  => ( is => 'ro', required => 1 );
    has 'rest_uri' => ( is => 'ro', required => 1, isa => class_type('URI') );
    has 'http' => ( is => 'lazy', handles => [qw[ do_request GET ]] );

    sub bug_title($self, $bug_id) {
        my $uri = $self->rest_uri->clone;
        $uri->path($uri->path . "/bug/$bug_id");
        $uri->query_form(include_fields => 'summary');
        my $bugs = decode_json($self->GET($uri)->get->content)->{bugs};
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
